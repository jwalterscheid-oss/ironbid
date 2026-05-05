-- supabase/storage.sql
-- Run in Supabase SQL Editor OR use the Dashboard UI
-- Creates the 4 storage buckets IRONBID needs

-- ── 1. Listing Photos (PUBLIC) ──────────────────────────────────────────────
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'listing-photos',
  'listing-photos',
  TRUE,                          -- public: anyone can read
  10485760,                      -- 10MB per file
  ARRAY['image/jpeg','image/png','image/webp','image/gif']
)
ON CONFLICT (id) DO NOTHING;

-- ── 2. Documents (PRIVATE) ──────────────────────────────────────────────────
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'documents',
  'documents',
  FALSE,
  20971520,                      -- 20MB
  ARRAY['application/pdf','image/jpeg','image/png']
)
ON CONFLICT (id) DO NOTHING;

-- ── 3. Inspection Reports (PRIVATE) ─────────────────────────────────────────
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'inspection-reports',
  'inspection-reports',
  FALSE,
  20971520,
  ARRAY['application/pdf']
)
ON CONFLICT (id) DO NOTHING;

-- ── 4. BOL Documents (PRIVATE) ──────────────────────────────────────────────
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'bol-documents',
  'bol-documents',
  FALSE,
  20971520,
  ARRAY['application/pdf','image/jpeg','image/png']
)
ON CONFLICT (id) DO NOTHING;

-- ── Storage Policies ────────────────────────────────────────────────────────

-- listing-photos: anyone can read, authenticated sellers can upload
CREATE POLICY "listing_photos_public_read" ON storage.objects
  FOR SELECT USING (bucket_id = 'listing-photos');

CREATE POLICY "listing_photos_seller_upload" ON storage.objects
  FOR INSERT WITH CHECK (
    bucket_id = 'listing-photos'
    AND auth.role() = 'authenticated'
  );

-- documents: only owner can read/write
CREATE POLICY "documents_owner_only" ON storage.objects
  FOR ALL USING (
    bucket_id = 'documents'
    AND (storage.foldername(name))[1] = auth.uid()::text
  );

-- inspection-reports: owner + buyer of auction can read
CREATE POLICY "inspection_reports_read" ON storage.objects
  FOR SELECT USING (
    bucket_id = 'inspection-reports'
    AND auth.role() = 'authenticated'
  );

CREATE POLICY "inspection_reports_write" ON storage.objects
  FOR INSERT WITH CHECK (
    bucket_id = 'inspection-reports'
    AND auth.role() = 'authenticated'
  );

-- bol-documents: carrier (owner) and buyer can read
CREATE POLICY "bol_read" ON storage.objects
  FOR SELECT USING (
    bucket_id = 'bol-documents'
    AND auth.role() = 'authenticated'
  );

CREATE POLICY "bol_write" ON storage.objects
  FOR INSERT WITH CHECK (
    bucket_id = 'bol-documents'
    AND auth.role() = 'authenticated'
  );
