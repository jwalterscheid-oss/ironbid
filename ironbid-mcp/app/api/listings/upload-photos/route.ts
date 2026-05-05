// app/api/listings/upload-photos/route.ts — Upload listing photos to Supabase Storage
import { NextRequest, NextResponse } from 'next/server'
import { auth } from '@clerk/nextjs/server'
import { db, getUserByClerkId, getListingById } from '@/lib/db'
import { uploadListingPhotos } from '@/lib/supabase'
import { eq } from 'drizzle-orm'
import * as schema from '@/lib/schema'

export async function POST(req: NextRequest) {
  const { userId: clerkId } = auth()
  if (!clerkId) return NextResponse.json({ error: 'Unauthorized' }, { status: 401 })

  const user = await getUserByClerkId(clerkId)
  if (!user) return NextResponse.json({ error: 'User not found' }, { status: 404 })

  const formData  = await req.formData()
  const listingId = formData.get('listingId') as string
  const files     = formData.getAll('photos') as File[]

  if (!listingId) return NextResponse.json({ error: 'listingId required' }, { status: 422 })
  if (files.length === 0) return NextResponse.json({ error: 'No files provided' }, { status: 422 })
  if (files.length > 20) return NextResponse.json({ error: 'Maximum 20 photos' }, { status: 422 })

  // Verify ownership
  const listing = await getListingById(listingId)
  if (!listing || listing.sellerId !== user.id) {
    return NextResponse.json({ error: 'Listing not found or access denied' }, { status: 403 })
  }

  // Upload to Supabase Storage
  const photos = await uploadListingPhotos(listingId, files)

  // Merge with existing photos
  const existing = (listing.photos as any[]) ?? []
  const merged   = [
    ...existing,
    ...photos.map((p, i) => ({
      ...p,
      order: existing.length + i,
    })),
  ]

  // Update listing
  await db.update(schema.listings)
    .set({ photos: merged })
    .where(eq(schema.listings.id, listingId))

  return NextResponse.json({ photos: merged }, { status: 200 })
}
