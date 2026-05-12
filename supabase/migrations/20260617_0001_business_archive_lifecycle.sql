-- Business archive lifecycle support (additive metadata + widened status constraint).

ALTER TABLE public.businesses
  ADD COLUMN IF NOT EXISTS admin_archived_at timestamptz,
  ADD COLUMN IF NOT EXISTS admin_archived_by text,
  ADD COLUMN IF NOT EXISTS admin_archived_reason text;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'businesses_admin_status_check'
  ) THEN
    ALTER TABLE public.businesses
      DROP CONSTRAINT businesses_admin_status_check;
  END IF;

  ALTER TABLE public.businesses
    ADD CONSTRAINT businesses_admin_status_check
    CHECK (admin_status IN ('active', 'archived', 'disabled'));
END $$;

COMMENT ON COLUMN public.businesses.admin_archived_at IS
  'When set, the business has been soft-archived by an admin.';

COMMENT ON COLUMN public.businesses.admin_archived_by IS
  'Admin email that most recently archived this business.';

COMMENT ON COLUMN public.businesses.admin_archived_reason IS
  'Optional admin reason/note for the most recent business archive action.';

CREATE INDEX IF NOT EXISTS idx_businesses_admin_status
  ON public.businesses (admin_status);

CREATE INDEX IF NOT EXISTS idx_businesses_admin_archived_at
  ON public.businesses (admin_archived_at DESC)
  WHERE admin_archived_at IS NOT NULL;
