-- Phase A1 (multi-venue owner): database foundation for one business owner managing multiple venue locations.
-- Additive only: new table + nullable FK columns + indexes + check constraint. No RLS changes, no backfill,
-- no changes to venues.owner_email behavior or existing client logic.

-- ---------------------------------------------------------------------------
-- 1. public.businesses — brand / operator (organization), not a map pin.
-- ---------------------------------------------------------------------------
-- businesses represent the brand or operator (e.g. "Garage Grill"). venues remain physical map locations
-- (each with its own address, coordinates, photos, and games). one business may manage many venues.
-- this migration is additive transition support: nullable business_id on venues and venue_claims until
-- apps and admin workflows populate and enforce ownership through businesses.

CREATE TABLE IF NOT EXISTS public.businesses (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  display_name text NOT NULL,
  owner_user_id uuid NULL,
  owner_email text NULL,
  admin_status text NOT NULL DEFAULT 'active',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT businesses_admin_status_check
    CHECK (admin_status IN ('active', 'disabled'))
);

COMMENT ON TABLE public.businesses IS
  'Brand or operator account (organization). Distinct from public.venues: each venue is a physical map location; '
  'one business may own or manage many venues. Phase A1 adds this table only—clients and backfill link rows later.';

COMMENT ON COLUMN public.businesses.display_name IS
  'Public-facing business / organization name (e.g. trade name), separate from per-location venue_name on venues.';

COMMENT ON COLUMN public.businesses.owner_user_id IS
  'Optional link to auth.users.id for the primary Supabase-authenticated owner; nullable during transition.';

COMMENT ON COLUMN public.businesses.owner_email IS
  'Optional denormalized email for notifications and legacy parity; nullable. Does not replace venues.owner_email yet.';

COMMENT ON COLUMN public.businesses.admin_status IS
  'Lifecycle: active (default) or disabled. Checked constraint enforces known values only.';

-- ---------------------------------------------------------------------------
-- 2. Nullable business_id on public.venues — links a map location to a business.
-- ---------------------------------------------------------------------------

ALTER TABLE public.venues
  ADD COLUMN IF NOT EXISTS business_id uuid;

COMMENT ON COLUMN public.venues.business_id IS
  'Phase A1: optional FK to public.businesses.id. When set, this venue row is grouped under that business/brand; '
  'NULL means not linked yet (legacy or pre-backfill). venues remain one row per physical location.';

-- ---------------------------------------------------------------------------
-- 3. Nullable business_id on public.venue_claims — which business a claim should attach to after approval.
-- ---------------------------------------------------------------------------

ALTER TABLE public.venue_claims
  ADD COLUMN IF NOT EXISTS business_id uuid;

COMMENT ON COLUMN public.venue_claims.business_id IS
  'Phase A1: optional FK to public.businesses.id for admin approval flows that attach the claimed venue to an organization; '
  'NULL for legacy rows or claims filed before business linkage exists.';

-- ---------------------------------------------------------------------------
-- 4. Foreign keys: ON DELETE SET NULL (dropping a business clears the pointer, keeps venue/claim rows).
-- ---------------------------------------------------------------------------

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint c
    JOIN pg_class t ON c.conrelid = t.oid
    JOIN pg_namespace n ON t.relnamespace = n.oid
    WHERE n.nspname = 'public'
      AND t.relname = 'venues'
      AND c.conname = 'venues_business_id_fkey'
  ) THEN
    ALTER TABLE public.venues
      ADD CONSTRAINT venues_business_id_fkey
      FOREIGN KEY (business_id)
      REFERENCES public.businesses (id)
      ON DELETE SET NULL;
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint c
    JOIN pg_class t ON c.conrelid = t.oid
    JOIN pg_namespace n ON t.relnamespace = n.oid
    WHERE n.nspname = 'public'
      AND t.relname = 'venue_claims'
      AND c.conname = 'venue_claims_business_id_fkey'
  ) THEN
    ALTER TABLE public.venue_claims
      ADD CONSTRAINT venue_claims_business_id_fkey
      FOREIGN KEY (business_id)
      REFERENCES public.businesses (id)
      ON DELETE SET NULL;
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 5. Indexes for lookups by owner and by business linkage.
-- ---------------------------------------------------------------------------

CREATE INDEX IF NOT EXISTS idx_businesses_owner_email
  ON public.businesses (owner_email);

CREATE INDEX IF NOT EXISTS idx_businesses_owner_user_id
  ON public.businesses (owner_user_id);

CREATE INDEX IF NOT EXISTS idx_venues_business_id
  ON public.venues (business_id);

CREATE INDEX IF NOT EXISTS idx_venue_claims_business_id
  ON public.venue_claims (business_id);
