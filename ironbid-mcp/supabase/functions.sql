-- supabase/functions.sql
-- Run this entire file in the Supabase SQL Editor:
-- https://supabase.com/dashboard/project/obfqhbiglcxcwlljzqbr/sql
--
-- Contains:
--   1. place_bid()      — serialized bid processing
--   2. close_auction()  — atomic auction close + transaction creation
--   3. award_haul_job() — haul job award to carrier
--   4. RLS policies     — row level security

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. place_bid — called by lib/auction/bid-processor.ts
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION place_bid(
  p_auction_id  UUID,
  p_bidder_id   UUID,
  p_amount      NUMERIC,
  p_max_bid     NUMERIC DEFAULT NULL,
  p_ip_address  TEXT    DEFAULT NULL
) RETURNS JSON
LANGUAGE plpgsql
AS $$
DECLARE
  v_auction         auctions%ROWTYPE;
  v_prev_winner_id  UUID;
  v_bid_id          UUID;
  v_was_extended    BOOLEAN := FALSE;
  v_new_end_time    TIMESTAMPTZ;
  v_reserve_met     BOOLEAN;
BEGIN
  -- Lock the auction row to prevent concurrent bids
  SELECT * INTO v_auction
    FROM auctions
   WHERE id = p_auction_id
     FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'auction_not_found';
  END IF;

  IF v_auction.status NOT IN ('active', 'extended') THEN
    RAISE EXCEPTION 'auction_not_active — status: %', v_auction.status;
  END IF;

  IF NOW() > v_auction.end_time THEN
    RAISE EXCEPTION 'auction_expired';
  END IF;

  IF p_amount < COALESCE(v_auction.current_bid, v_auction.starting_bid) + v_auction.min_increment THEN
    RAISE EXCEPTION 'bid_too_low — minimum is %',
      COALESCE(v_auction.current_bid, v_auction.starting_bid) + v_auction.min_increment;
  END IF;

  -- Save previous winner for outbid notification
  v_prev_winner_id := v_auction.current_winner_id;

  -- Unset all previous winning bids for this auction
  UPDATE bids
     SET is_winning = FALSE
   WHERE auction_id = p_auction_id
     AND is_winning = TRUE;

  -- Insert the new bid
  INSERT INTO bids (
    id, auction_id, bidder_id, amount, max_bid,
    bid_type, is_winning, ip_address, placed_at
  )
  VALUES (
    gen_random_uuid(), p_auction_id, p_bidder_id, p_amount, p_max_bid,
    'manual', TRUE, p_ip_address, NOW()
  )
  RETURNING id INTO v_bid_id;

  -- Auto-extend if bid placed in final 3 minutes
  v_new_end_time := v_auction.end_time;
  IF v_auction.end_time - NOW() < INTERVAL '3 minutes' THEN
    v_new_end_time := NOW() + INTERVAL '3 minutes';
    v_was_extended := TRUE;
  END IF;

  -- Calculate reserve met
  v_reserve_met := (
    v_auction.reserve_price IS NULL
    OR p_amount >= v_auction.reserve_price
  );

  -- Update auction with new state
  UPDATE auctions
     SET current_bid        = p_amount,
         current_winner_id  = p_bidder_id,
         bid_count          = bid_count + 1,
         reserve_met        = v_reserve_met,
         end_time           = v_new_end_time,
         status             = CASE
                                WHEN v_was_extended THEN 'extended'
                                ELSE status
                              END
   WHERE id = p_auction_id;

  RETURN json_build_object(
    'bid_id',             v_bid_id,
    'new_current_bid',    p_amount,
    'new_bid_count',      v_auction.bid_count + 1,
    'reserve_met',        v_reserve_met,
    'new_end_time',       v_new_end_time,
    'was_extended',       v_was_extended,
    'previous_winner_id', v_prev_winner_id
  );
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. close_auction — called by lib/auction/bid-processor.ts closeAuction()
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION close_auction(
  p_auction_id      UUID,
  p_winner_id       UUID,
  p_final_price     NUMERIC,
  p_buyers_premium  NUMERIC,
  p_total_due       NUMERIC,
  p_platform_fee    NUMERIC,
  p_seller_proceeds NUMERIC,
  p_due_date        TIMESTAMPTZ
) RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
  v_listing_id UUID;
  v_seller_id  UUID;
BEGIN
  -- Get listing_id and seller_id
  SELECT l.id, l.seller_id
    INTO v_listing_id, v_seller_id
    FROM auctions a
    JOIN listings l ON a.listing_id = l.id
   WHERE a.id = p_auction_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'auction_not_found: %', p_auction_id;
  END IF;

  -- Mark auction closed
  UPDATE auctions
     SET status            = 'closed',
         final_price       = p_final_price,
         winning_bidder_id = p_winner_id
   WHERE id = p_auction_id;

  -- Mark listing sold
  UPDATE listings
     SET status = 'sold'
   WHERE id = v_listing_id;

  -- Create transaction record (idempotent — skip if already exists)
  INSERT INTO transactions (
    id,
    auction_id,
    buyer_id,
    seller_id,
    hammer_price,
    buyers_premium,
    total_due,
    platform_fee,
    seller_proceeds,
    payment_status,
    title_status,
    due_date,
    created_at
  )
  VALUES (
    gen_random_uuid(),
    p_auction_id,
    p_winner_id,
    v_seller_id,
    p_final_price,
    p_buyers_premium,
    p_total_due,
    p_platform_fee,
    p_seller_proceeds,
    'pending',
    'pending',
    p_due_date,
    NOW()
  )
  ON CONFLICT (auction_id) DO NOTHING;
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. award_haul_job — called by app/api/haul-jobs/[id]/award/route.ts
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION award_haul_job(
  p_job_id             UUID,
  p_bid_id             UUID,
  p_carrier_id         UUID,
  p_payment_intent_id  TEXT
) RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
  -- Mark winning bid as accepted
  UPDATE haul_bids
     SET status = 'accepted'
   WHERE id = p_bid_id;

  -- Expire all other active bids for this job
  UPDATE haul_bids
     SET status = 'expired'
   WHERE haul_job_id = p_job_id
     AND id != p_bid_id
     AND status = 'active';

  -- Award the job
  UPDATE haul_jobs
     SET status                = 'awarded',
         awarded_bid_id        = p_bid_id,
         awarded_carrier_id    = p_carrier_id,
         stripe_payment_intent = p_payment_intent_id
   WHERE id = p_job_id;
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. ROW LEVEL SECURITY POLICIES
-- ─────────────────────────────────────────────────────────────────────────────

-- Enable RLS
ALTER TABLE users          ENABLE ROW LEVEL SECURITY;
ALTER TABLE bids           ENABLE ROW LEVEL SECURITY;
ALTER TABLE transactions   ENABLE ROW LEVEL SECURITY;
ALTER TABLE haul_jobs      ENABLE ROW LEVEL SECURITY;
ALTER TABLE haul_bids      ENABLE ROW LEVEL SECURITY;
ALTER TABLE carrier_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE notifications  ENABLE ROW LEVEL SECURITY;

-- Helper: get current user's internal UUID from Clerk JWT
CREATE OR REPLACE FUNCTION current_user_id() RETURNS UUID
LANGUAGE sql STABLE
AS $$
  SELECT id FROM users WHERE clerk_id = auth.jwt() ->> 'sub' LIMIT 1;
$$;

-- USERS: read own record
CREATE POLICY "users_read_own" ON users
  FOR SELECT USING (clerk_id = auth.jwt() ->> 'sub');

CREATE POLICY "users_update_own" ON users
  FOR UPDATE USING (clerk_id = auth.jwt() ->> 'sub');

-- BIDS: read all bids (buyers see bid history), write own bids
CREATE POLICY "bids_read_all" ON bids
  FOR SELECT USING (TRUE); -- public bid history (amounts shown, bidder masked in app)

CREATE POLICY "bids_insert_own" ON bids
  FOR INSERT WITH CHECK (bidder_id = current_user_id());

-- TRANSACTIONS: buyer and seller can read their own
CREATE POLICY "tx_buyer_read" ON transactions
  FOR SELECT USING (buyer_id = current_user_id() OR seller_id = current_user_id());

-- HAUL JOBS: buyer can read/write their own
CREATE POLICY "haul_jobs_buyer_read" ON haul_jobs
  FOR SELECT USING (
    buyer_id = current_user_id()
    OR awarded_carrier_id = current_user_id()
  );

CREATE POLICY "haul_jobs_buyer_insert" ON haul_jobs
  FOR INSERT WITH CHECK (buyer_id = current_user_id());

CREATE POLICY "haul_jobs_buyer_update" ON haul_jobs
  FOR UPDATE USING (
    buyer_id = current_user_id()
    OR awarded_carrier_id = current_user_id()
  );

-- HAUL BIDS: carrier reads/writes own, buyer reads bids on their jobs
CREATE POLICY "haul_bids_carrier_read" ON haul_bids
  FOR SELECT USING (
    carrier_id = current_user_id()
    OR haul_job_id IN (
      SELECT id FROM haul_jobs WHERE buyer_id = current_user_id()
    )
  );

CREATE POLICY "haul_bids_carrier_insert" ON haul_bids
  FOR INSERT WITH CHECK (carrier_id = current_user_id());

CREATE POLICY "haul_bids_carrier_update" ON haul_bids
  FOR UPDATE USING (carrier_id = current_user_id());

-- CARRIER PROFILES: public read (for job matching), own write
CREATE POLICY "carrier_profiles_public_read" ON carrier_profiles
  FOR SELECT USING (TRUE);

CREATE POLICY "carrier_profiles_own_write" ON carrier_profiles
  FOR ALL USING (user_id = current_user_id());

-- NOTIFICATIONS: own only
CREATE POLICY "notifications_own" ON notifications
  FOR SELECT USING (user_id = current_user_id());
