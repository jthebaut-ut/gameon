-- Community venue provenance metadata.
--
-- Schema-only migration:
-- - no data updates
-- - no seed cleanup
-- - no ownership/release/delete logic changes
--
-- Community seed venues must not use fake owner emails, fake owner_user_id
-- values, or helper business rows to represent provenance. Ownership fields
-- (`business_id`, `owner_user_id`, `owner_email`) are reserved for real
-- business authority established through normal claim/approval flows.
--
-- Seeded community venues should remain identity-only until claimed:
-- name/address/location plus real public contact fields and provenance.
-- Photos, menus, feature text, screen counts, amenity booleans, supporter
-- country, and business-authored details are unknown until a real business
-- claims and updates the venue.

ALTER TABLE public.venues
  ADD COLUMN IF NOT EXISTS community_source text,
  ADD COLUMN IF NOT EXISTS community_source_id text,
  ADD COLUMN IF NOT EXISTS community_seed_batch text,
  ADD COLUMN IF NOT EXISTS community_seeded_at timestamptz,
  ADD COLUMN IF NOT EXISTS community_curated_by text,
  ADD COLUMN IF NOT EXISTS community_provenance jsonb NOT NULL DEFAULT '{}'::jsonb;

COMMENT ON COLUMN public.venues.community_source IS
  'Community venue provenance source namespace only (for example: utah_seed, national_seed_v1, osm, manual_admin, partner_import). Not an ownership field.';

COMMENT ON COLUMN public.venues.community_source_id IS
  'Source-specific stable identifier for a community venue import. Must not be a fake owner email or fake business account reference.';

COMMENT ON COLUMN public.venues.community_seed_batch IS
  'Import or migration batch identifier for community venue provenance. Tracks source/batch only and grants no management authority.';

COMMENT ON COLUMN public.venues.community_seeded_at IS
  'Timestamp when the community venue was imported or migrated into FanGeo provenance tracking. Does not imply business verification.';

COMMENT ON COLUMN public.venues.community_curated_by IS
  'Optional admin, process, or importer marker for community venue curation. Not an owner, business, or claim authority field.';

COMMENT ON COLUMN public.venues.community_provenance IS
  'JSON metadata for community venue source/import provenance only. Community seed venues must not use fake owner/business accounts; photos, features, amenities, screens, menus, supporter country, and business details remain unknown until claimed.';
