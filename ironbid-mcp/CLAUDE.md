# IRONBID — Claude Code Project Context

## Project Overview
IRONBID is a heavy equipment auction platform with a post-auction haul/logistics marketplace.
Built with Next.js 14 (App Router), Drizzle ORM, Supabase PostgreSQL, Stripe, Clerk auth, Ably WebSockets, and Slack notifications.

## Supabase Project
- **Project Ref:** `obfqhbiglcxcwlljzqbr`
- **URL:** `https://obfqhbiglcxcwlljzqbr.supabase.co`
- **MCP Server:** Connected via `.claude/mcp.json`

## Database
- **ORM:** Drizzle — schema in `lib/schema.ts`
- **Push schema:** `npm run db:push`
- **Browse data:** `npm run db:studio`
- **Migrations:** `npm run db:generate` then `npm run db:migrate`

### Tables (12 total)
| Table | Description |
|---|---|
| `users` | All platform users (buyers, sellers, carriers, admins) |
| `listings` | Equipment listings with photos, specs, inspection data |
| `auctions` | Auction events — timed, live, buy-now |
| `bids` | Immutable bid ledger — append only |
| `transactions` | Post-auction payment records |
| `carrier_profiles` | Carrier company info, FMCSA, insurance, fleet |
| `haul_jobs` | Post-purchase transport requests |
| `haul_bids` | Carrier bids on haul jobs |
| `haul_tracking` | GPS and status events for active hauls |
| `watchlist` | User auction watchlists |
| `carrier_reviews` | Buyer reviews of carriers |
| `notifications` | Email/SMS notification log |

## Key Files
```
lib/
  schema.ts          ← Drizzle ORM schema (all tables)
  db.ts              ← Typed query helpers
  supabase.ts        ← Supabase client (browser/server/admin)
  stripe.ts          ← Stripe helpers (auction pay, haul escrow, Connect)
  slack.ts           ← Slack notification functions
  redis.ts           ← Redis/Upstash client + auction state helpers
  ably.ts            ← Ably WebSocket token + channel helpers
  auction/
    bid-processor.ts ← Core bid engine, autobid, auction close

app/api/
  bids/route.ts                         ← POST: place bid (via BullMQ queue)
  auctions/route.ts                     ← GET: list auctions with filters
  auctions/[id]/route.ts                ← GET: auction detail + Redis merge
  auctions/create/route.ts              ← POST: create auction
  listings/route.ts                     ← GET/POST: seller listings
  haul-jobs/route.ts                    ← GET/POST: haul jobs
  haul-jobs/[id]/award/route.ts         ← PATCH: buyer accepts carrier bid
  haul-jobs/[id]/confirm-delivery/route.ts ← POST: release escrow
  haul-bids/route.ts                    ← POST: carrier submits haul bid
  haul-bids/[id]/withdraw/route.ts      ← PATCH: withdraw bid
  haul-tracking/route.ts                ← POST: carrier GPS/status update
  carriers/register/route.ts            ← POST: carrier onboarding + FMCSA + Stripe
  carriers/stripe-onboard/route.ts      ← GET: Stripe Connect redirect
  webhooks/stripe/route.ts              ← Stripe payment events
  webhooks/clerk/route.ts               ← Clerk user sync → Supabase
  ably-token/route.ts                   ← GET: Ably auth token
  cron/close-auctions/route.ts          ← Vercel cron: close expired auctions

workers/
  bid-processor.ts   ← BullMQ workers (bid queue + auction close queue)
```

## Auth Flow
- **Provider:** Clerk
- **Sign in:** `/sign-in` (Clerk hosted)
- **Sign up:** `/sign-up` → `/onboarding` (role selection)
- **Protected routes:** All `/dashboard/*` and `/carrier/*` require auth
- **User sync:** Clerk webhook → `app/api/webhooks/clerk` → Supabase `users` table
- **Carrier role:** Requires `carrier_profiles` record after registration

## Real-Time Architecture
- **WebSocket provider:** Ably
- **Token auth endpoint:** `GET /api/ably-token`
- **Auction channels:** `auction:{id}` — bid updates, extensions, close
- **Haul channels:** `haul:{jobId}` — bid received, GPS updates, delivery
- **Carrier feed:** `haul-jobs:available` — new job notifications
- **Private alerts:** `private:{userId}` — outbid, won, payment

## Payment Flow
1. Buyer wins auction → POST `/api/auctions/create` creates Stripe PaymentIntent
2. Payment confirmed → Stripe webhook updates `transactions.payment_status = 'paid'`
3. Buyer posts haul job → POST `/api/haul-jobs`
4. Buyer accepts carrier bid → PATCH `/api/haul-jobs/[id]/award` creates escrow hold
5. Delivery confirmed → POST `/api/haul-jobs/[id]/confirm-delivery` captures + transfers to carrier (minus 8%)

## Environment Variables
All defined in `env.example`. Key ones:
```
DATABASE_URL                    ← Supabase PostgreSQL connection string
NEXT_PUBLIC_SUPABASE_URL        ← https://obfqhbiglcxcwlljzqbr.supabase.co
NEXT_PUBLIC_SUPABASE_ANON_KEY   ← from Supabase project settings
SUPABASE_SERVICE_ROLE_KEY       ← server-only, bypasses RLS
STRIPE_SECRET_KEY               ← Stripe secret
CLERK_SECRET_KEY                ← Clerk secret
ABLY_API_KEY                    ← Ably root key (server only)
SLACK_BOT_TOKEN                 ← Slack bot token
REDIS_URL                       ← Upstash Redis URL
```

## Common Commands
```bash
npm run dev          # Start dev server
npm run build        # Production build
npm run db:push      # Push schema to Supabase
npm run db:studio    # Open Drizzle Studio
npm run db:generate  # Generate migration files
npm run db:migrate   # Run pending migrations
npm run worker:bids  # Start BullMQ bid worker
npm run worker:haul  # Start BullMQ haul worker
```

## Supabase SQL Functions Required
These Postgres functions must be created in Supabase SQL Editor:

### `place_bid` — serialized bid processing
```sql
CREATE OR REPLACE FUNCTION place_bid(
  p_auction_id  UUID,
  p_bidder_id   UUID,
  p_amount      NUMERIC,
  p_max_bid     NUMERIC DEFAULT NULL,
  p_ip_address  TEXT    DEFAULT NULL
) RETURNS JSON AS $$
DECLARE
  v_auction         auctions%ROWTYPE;
  v_prev_winner_id  UUID;
  v_bid_id          UUID;
  v_was_extended    BOOLEAN := FALSE;
  v_new_end_time    TIMESTAMPTZ;
BEGIN
  -- Lock auction row
  SELECT * INTO v_auction FROM auctions
    WHERE id = p_auction_id FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'auction_not_found';
  END IF;
  IF v_auction.status NOT IN ('active','extended') THEN
    RAISE EXCEPTION 'auction_not_active';
  END IF;
  IF p_amount < COALESCE(v_auction.current_bid, v_auction.starting_bid) + v_auction.min_increment THEN
    RAISE EXCEPTION 'bid_too_low';
  END IF;

  -- Save previous winner for outbid notification
  v_prev_winner_id := v_auction.current_winner_id;

  -- Unset previous winning bid
  UPDATE bids SET is_winning = FALSE
    WHERE auction_id = p_auction_id AND is_winning = TRUE;

  -- Insert new bid
  INSERT INTO bids (id, auction_id, bidder_id, amount, max_bid, bid_type, is_winning, ip_address, placed_at)
    VALUES (gen_random_uuid(), p_auction_id, p_bidder_id, p_amount, p_max_bid, 'manual', TRUE, p_ip_address, NOW())
    RETURNING id INTO v_bid_id;

  -- Check if auction needs extending (bid in final 3 min)
  v_new_end_time := v_auction.end_time;
  IF v_auction.end_time - NOW() < INTERVAL '3 minutes' THEN
    v_new_end_time := NOW() + INTERVAL '3 minutes';
    v_was_extended := TRUE;
  END IF;

  -- Update auction state
  UPDATE auctions SET
    current_bid       = p_amount,
    current_winner_id = p_bidder_id,
    bid_count         = bid_count + 1,
    reserve_met       = (reserve_price IS NULL OR p_amount >= reserve_price),
    end_time          = v_new_end_time,
    status            = CASE WHEN v_was_extended THEN 'extended' ELSE status END
  WHERE id = p_auction_id;

  RETURN json_build_object(
    'bid_id',            v_bid_id,
    'new_current_bid',   p_amount,
    'new_bid_count',     v_auction.bid_count + 1,
    'reserve_met',       (v_auction.reserve_price IS NULL OR p_amount >= v_auction.reserve_price),
    'new_end_time',      v_new_end_time,
    'was_extended',      v_was_extended,
    'previous_winner_id', v_prev_winner_id
  );
END;
$$ LANGUAGE plpgsql;
```

### `close_auction` — atomic auction close + transaction creation
```sql
CREATE OR REPLACE FUNCTION close_auction(
  p_auction_id      UUID,
  p_winner_id       UUID,
  p_final_price     NUMERIC,
  p_buyers_premium  NUMERIC,
  p_total_due       NUMERIC,
  p_platform_fee    NUMERIC,
  p_seller_proceeds NUMERIC,
  p_due_date        TIMESTAMPTZ
) RETURNS VOID AS $$
DECLARE
  v_listing_id UUID;
  v_seller_id  UUID;
BEGIN
  -- Get listing and seller
  SELECT l.id, l.seller_id INTO v_listing_id, v_seller_id
    FROM auctions a JOIN listings l ON a.listing_id = l.id
    WHERE a.id = p_auction_id;

  -- Close auction
  UPDATE auctions SET
    status            = 'closed',
    final_price       = p_final_price,
    winning_bidder_id = p_winner_id
  WHERE id = p_auction_id;

  -- Update listing status
  UPDATE listings SET status = 'sold' WHERE id = v_listing_id;

  -- Create transaction record
  INSERT INTO transactions (
    id, auction_id, buyer_id, seller_id,
    hammer_price, buyers_premium, total_due,
    platform_fee, seller_proceeds,
    payment_status, title_status, due_date
  ) VALUES (
    gen_random_uuid(), p_auction_id, p_winner_id, v_seller_id,
    p_final_price, p_buyers_premium, p_total_due,
    p_platform_fee, p_seller_proceeds,
    'pending', 'pending', p_due_date
  )
  ON CONFLICT (auction_id) DO NOTHING;
END;
$$ LANGUAGE plpgsql;
```

### `award_haul_job` — award haul job to carrier
```sql
CREATE OR REPLACE FUNCTION award_haul_job(
  p_job_id            UUID,
  p_bid_id            UUID,
  p_carrier_id        UUID,
  p_payment_intent_id TEXT
) RETURNS VOID AS $$
BEGIN
  -- Mark winning bid
  UPDATE haul_bids SET status = 'accepted' WHERE id = p_bid_id;

  -- Expire all other bids
  UPDATE haul_bids SET status = 'expired'
    WHERE haul_job_id = p_job_id AND id != p_bid_id AND status = 'active';

  -- Award job
  UPDATE haul_jobs SET
    status               = 'awarded',
    awarded_bid_id       = p_bid_id,
    awarded_carrier_id   = p_carrier_id,
    stripe_payment_intent = p_payment_intent_id
  WHERE id = p_job_id;
END;
$$ LANGUAGE plpgsql;
```

## Supabase RLS Policies
Run these in the SQL Editor after creating tables:

```sql
-- Enable RLS on sensitive tables
ALTER TABLE users         ENABLE ROW LEVEL SECURITY;
ALTER TABLE bids          ENABLE ROW LEVEL SECURITY;
ALTER TABLE transactions  ENABLE ROW LEVEL SECURITY;
ALTER TABLE haul_jobs     ENABLE ROW LEVEL SECURITY;
ALTER TABLE haul_bids     ENABLE ROW LEVEL SECURITY;

-- Users can read their own record
CREATE POLICY "users_read_own" ON users FOR SELECT
  USING (clerk_id = auth.jwt() ->> 'sub');

-- Buyers can read their own transactions
CREATE POLICY "tx_buyer_read" ON transactions FOR SELECT
  USING (buyer_id IN (SELECT id FROM users WHERE clerk_id = auth.jwt() ->> 'sub'));

-- Carriers can read haul bids they placed
CREATE POLICY "haul_bids_carrier_read" ON haul_bids FOR SELECT
  USING (carrier_id IN (SELECT id FROM users WHERE clerk_id = auth.jwt() ->> 'sub'));
```
