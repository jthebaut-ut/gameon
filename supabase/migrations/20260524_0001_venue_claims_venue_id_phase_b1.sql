-- Phase B1 (Venue Claim): optional real venue link on public.venue_claims.
-- Nullable for legacy text-only claims. No RLS changes, no data approval/rejection, no app changes in this migration.

-- ---------------------------------------------------------------------------
-- 1. Nullable venue_id (not required; legacy rows remain valid without it).
-- ---------------------------------------------------------------------------

ALTER TABLE public.venue_claims
  ADD COLUMN IF NOT EXISTS venue_id uuid;

COMMENT ON COLUMN public.venue_claims.venue_id IS
  'Phase B1: canonical link to public.venues.id when the claim targets an existing public venue row (e.g. Discover “Claim this business”). '
  'NULL for legacy or free-form claims that were filed before venue_id existed or without a resolved venue row. '
  'Ownership is still governed by admin approval workflow and application logic; this column stores the intended venue target.';

-- ---------------------------------------------------------------------------
-- 2. FK to venues(id), ON DELETE SET NULL (dropping a venue clears the pointer).
-- ---------------------------------------------------------------------------

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint c
    JOIN pg_class t ON c.conrelid = t.oid
    JOIN pg_namespace n ON t.relnamespace = n.oid
    WHERE n.nspname = 'public'
      AND t.relname = 'venue_claims'
      AND c.conname = 'venue_claims_venue_id_fkey'
  ) THEN
    ALTER TABLE public.venue_claims
      ADD CONSTRAINT venue_claims_venue_id_fkey
      FOREIGN KEY (venue_id)
      REFERENCES public.venues (id)
      ON DELETE SET NULL;
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 3. Indexes: lookup by venue, admin queue by venue + status, single approved owner per venue.
-- ---------------------------------------------------------------------------

CREATE INDEX IF NOT EXISTS idx_venue_claims_venue_id
  ON public.venue_claims (venue_id);

CREATE INDEX IF NOT EXISTS idx_venue_claims_venue_id_approval_status
  ON public.venue_claims (venue_id, approval_status);

-- At most one approved claim per non-null venue_id (prevents multiple “approved” owners targeting the same venue row).
CREATE UNIQUE INDEX IF NOT EXISTS idx_venue_claims_unique_approved_venue_id
  ON public.venue_claims (venue_id)
  WHERE approval_status = 'approved'
    AND venue_id IS NOT NULL;
