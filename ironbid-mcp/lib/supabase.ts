// lib/supabase.ts — Supabase client factory + storage helpers (MCP-aware)
import { createClient } from '@supabase/supabase-js'
import { createServerClient, createBrowserClient } from '@supabase/ssr'
import { cookies } from 'next/headers'

const supabaseUrl     = process.env.NEXT_PUBLIC_SUPABASE_URL!
const supabaseAnonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!

// ─── BROWSER CLIENT (use in 'use client' components) ─────────────────────────
export function createSupabaseBrowserClient() {
  return createBrowserClient(supabaseUrl, supabaseAnonKey)
}

// ─── SERVER CLIENT (use in Server Components + Route Handlers) ───────────────
export function createSupabaseServerClient() {
  const cookieStore = cookies()
  return createServerClient(supabaseUrl, supabaseAnonKey, {
    cookies: {
      get(name)              { return cookieStore.get(name)?.value },
      set(name, value, opts) { try { cookieStore.set({ name, value, ...opts }) } catch {} },
      remove(name, opts)     { try { cookieStore.set({ name, value: '', ...opts }) } catch {} },
    },
  })
}

// ─── ADMIN CLIENT (server-only — bypasses RLS) ───────────────────────────────
export const supabaseAdmin = createClient(
  supabaseUrl,
  process.env.SUPABASE_SERVICE_ROLE_KEY!,
  { auth: { autoRefreshToken: false, persistSession: false } }
)

// ─── STORAGE BUCKETS ─────────────────────────────────────────────────────────
export const BUCKETS = {
  listingPhotos:      'listing-photos',     // public
  documents:          'documents',          // private
  inspectionReports:  'inspection-reports', // private
  bolDocuments:       'bol-documents',      // private
} as const

// ─── UPLOAD LISTING PHOTOS ───────────────────────────────────────────────────
export async function uploadListingPhotos(
  listingId: string,
  files: File[]
): Promise<Array<{ url: string; order: number }>> {
  const results: Array<{ url: string; order: number }> = []

  for (let i = 0; i < files.length; i++) {
    const file = files[i]
    const ext  = file.name.split('.').pop() ?? 'jpg'
    const path = `${listingId}/${i + 1}-${Date.now()}.${ext}`

    const { data, error } = await supabaseAdmin.storage
      .from(BUCKETS.listingPhotos)
      .upload(path, file, { upsert: true, contentType: file.type })

    if (error) throw new Error(`Photo upload failed: ${error.message}`)

    const { data: { publicUrl } } = supabaseAdmin.storage
      .from(BUCKETS.listingPhotos)
      .getPublicUrl(data.path)

    results.push({ url: publicUrl, order: i })
  }

  return results
}

// ─── UPLOAD DOCUMENT ─────────────────────────────────────────────────────────
export async function uploadDocument(
  bucket: keyof typeof BUCKETS,
  folder: string,
  file: File,
  fileName: string
): Promise<string> {
  const path = `${folder}/${fileName}`
  const { data, error } = await supabaseAdmin.storage
    .from(BUCKETS[bucket])
    .upload(path, file, { upsert: true, contentType: file.type })

  if (error) throw new Error(`Document upload failed: ${error.message}`)

  // For private buckets, return a signed URL (1 hour)
  const { data: signedData, error: signError } = await supabaseAdmin.storage
    .from(BUCKETS[bucket])
    .createSignedUrl(data.path, 3600)

  if (signError) throw new Error(`Signed URL failed: ${signError.message}`)
  return signedData.signedUrl
}

// ─── GET SIGNED URL (for private files) ──────────────────────────────────────
export async function getSignedUrl(
  bucket: keyof typeof BUCKETS,
  path: string,
  expiresInSeconds = 3600
): Promise<string> {
  const { data, error } = await supabaseAdmin.storage
    .from(BUCKETS[bucket])
    .createSignedUrl(path, expiresInSeconds)

  if (error) throw new Error(error.message)
  return data.signedUrl
}

// ─── MCP PROJECT REF (used by Claude Code MCP integration) ───────────────────
export const SUPABASE_PROJECT_REF = 'obfqhbiglcxcwlljzqbr'
export const SUPABASE_PROJECT_URL = `https://${SUPABASE_PROJECT_REF}.supabase.co`
