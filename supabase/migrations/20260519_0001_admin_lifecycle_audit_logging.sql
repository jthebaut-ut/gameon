-- Admin lifecycle + audit logging (additive only; no hard deletes).

ALTER TABLE public.user_profiles
  ADD COLUMN IF NOT EXISTS admin_status text NOT NULL DEFAULT 'active',
  ADD COLUMN IF NOT EXISTS admin_disabled_at timestamptz,
  ADD COLUMN IF NOT EXISTS admin_disabled_by text,
  ADD COLUMN IF NOT EXISTS admin_disabled_reason text;

ALTER TABLE public.venues
  ADD COLUMN IF NOT EXISTS admin_status text NOT NULL DEFAULT 'active',
  ADD COLUMN IF NOT EXISTS admin_archived_at timestamptz,
  ADD COLUMN IF NOT EXISTS admin_archived_by text,
  ADD COLUMN IF NOT EXISTS admin_archived_reason text;

ALTER TABLE public.venue_events
  ADD COLUMN IF NOT EXISTS admin_status text NOT NULL DEFAULT 'active',
  ADD COLUMN IF NOT EXISTS admin_archived_at timestamptz,
  ADD COLUMN IF NOT EXISTS admin_archived_by text,
  ADD COLUMN IF NOT EXISTS admin_archived_reason text;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'user_profiles_admin_status_check'
  ) THEN
    ALTER TABLE public.user_profiles
      ADD CONSTRAINT user_profiles_admin_status_check
      CHECK (admin_status IN ('active', 'disabled'));
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'venues_admin_status_check'
  ) THEN
    ALTER TABLE public.venues
      ADD CONSTRAINT venues_admin_status_check
      CHECK (admin_status IN ('active', 'archived'));
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'venue_events_admin_status_check'
  ) THEN
    ALTER TABLE public.venue_events
      ADD CONSTRAINT venue_events_admin_status_check
      CHECK (admin_status IN ('active', 'archived'));
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.admin_audit_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  admin_email text NOT NULL,
  action text NOT NULL,
  target_type text NOT NULL,
  target_id text NOT NULL,
  before_data jsonb,
  after_data jsonb,
  reason text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_user_profiles_admin_status
  ON public.user_profiles (admin_status);

CREATE INDEX IF NOT EXISTS idx_user_profiles_admin_disabled_at
  ON public.user_profiles (admin_disabled_at DESC)
  WHERE admin_disabled_at IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_venues_admin_status
  ON public.venues (admin_status);

CREATE INDEX IF NOT EXISTS idx_venues_admin_archived_at
  ON public.venues (admin_archived_at DESC)
  WHERE admin_archived_at IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_venue_events_admin_status
  ON public.venue_events (admin_status);

CREATE INDEX IF NOT EXISTS idx_venue_events_admin_archived_at
  ON public.venue_events (admin_archived_at DESC)
  WHERE admin_archived_at IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_admin_audit_logs_admin_email_created_at
  ON public.admin_audit_logs (admin_email, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_admin_audit_logs_target
  ON public.admin_audit_logs (target_type, target_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_admin_audit_logs_action_created_at
  ON public.admin_audit_logs (action, created_at DESC);

ALTER TABLE public.admin_audit_logs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Service role can manage admin audit logs"
  ON public.admin_audit_logs;

CREATE POLICY "Service role can manage admin audit logs"
  ON public.admin_audit_logs
  FOR ALL
  USING (auth.role() = 'service_role')
  WITH CHECK (auth.role() = 'service_role');
