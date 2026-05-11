-- Admin report resolution fields (additive only; no changes to existing report submission behavior).

ALTER TABLE public.comment_reports
  ADD COLUMN IF NOT EXISTS admin_resolution_status text NOT NULL DEFAULT 'open',
  ADD COLUMN IF NOT EXISTS admin_resolved_at timestamptz,
  ADD COLUMN IF NOT EXISTS admin_resolved_by text,
  ADD COLUMN IF NOT EXISTS admin_resolution_note text,
  ADD COLUMN IF NOT EXISTS admin_escalated_at timestamptz,
  ADD COLUMN IF NOT EXISTS admin_escalated_by text;

ALTER TABLE public.user_reports
  ADD COLUMN IF NOT EXISTS admin_resolution_status text NOT NULL DEFAULT 'open',
  ADD COLUMN IF NOT EXISTS admin_resolved_at timestamptz,
  ADD COLUMN IF NOT EXISTS admin_resolved_by text,
  ADD COLUMN IF NOT EXISTS admin_resolution_note text,
  ADD COLUMN IF NOT EXISTS admin_escalated_at timestamptz,
  ADD COLUMN IF NOT EXISTS admin_escalated_by text;

ALTER TABLE public.message_reports
  ADD COLUMN IF NOT EXISTS admin_resolution_status text NOT NULL DEFAULT 'open',
  ADD COLUMN IF NOT EXISTS admin_resolved_at timestamptz,
  ADD COLUMN IF NOT EXISTS admin_resolved_by text,
  ADD COLUMN IF NOT EXISTS admin_resolution_note text,
  ADD COLUMN IF NOT EXISTS admin_escalated_at timestamptz,
  ADD COLUMN IF NOT EXISTS admin_escalated_by text;

ALTER TABLE public.conversation_reports
  ADD COLUMN IF NOT EXISTS admin_resolution_status text NOT NULL DEFAULT 'open',
  ADD COLUMN IF NOT EXISTS admin_resolved_at timestamptz,
  ADD COLUMN IF NOT EXISTS admin_resolved_by text,
  ADD COLUMN IF NOT EXISTS admin_resolution_note text,
  ADD COLUMN IF NOT EXISTS admin_escalated_at timestamptz,
  ADD COLUMN IF NOT EXISTS admin_escalated_by text;

ALTER TABLE public.venue_reports
  ADD COLUMN IF NOT EXISTS admin_resolution_status text NOT NULL DEFAULT 'open',
  ADD COLUMN IF NOT EXISTS admin_resolved_at timestamptz,
  ADD COLUMN IF NOT EXISTS admin_resolved_by text,
  ADD COLUMN IF NOT EXISTS admin_resolution_note text,
  ADD COLUMN IF NOT EXISTS admin_escalated_at timestamptz,
  ADD COLUMN IF NOT EXISTS admin_escalated_by text;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'comment_reports_admin_resolution_status_check'
  ) THEN
    ALTER TABLE public.comment_reports
      ADD CONSTRAINT comment_reports_admin_resolution_status_check
      CHECK (admin_resolution_status IN ('open', 'resolved', 'dismissed', 'escalated'));
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'user_reports_admin_resolution_status_check'
  ) THEN
    ALTER TABLE public.user_reports
      ADD CONSTRAINT user_reports_admin_resolution_status_check
      CHECK (admin_resolution_status IN ('open', 'resolved', 'dismissed', 'escalated'));
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'message_reports_admin_resolution_status_check'
  ) THEN
    ALTER TABLE public.message_reports
      ADD CONSTRAINT message_reports_admin_resolution_status_check
      CHECK (admin_resolution_status IN ('open', 'resolved', 'dismissed', 'escalated'));
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'conversation_reports_admin_resolution_status_check'
  ) THEN
    ALTER TABLE public.conversation_reports
      ADD CONSTRAINT conversation_reports_admin_resolution_status_check
      CHECK (admin_resolution_status IN ('open', 'resolved', 'dismissed', 'escalated'));
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'venue_reports_admin_resolution_status_check'
  ) THEN
    ALTER TABLE public.venue_reports
      ADD CONSTRAINT venue_reports_admin_resolution_status_check
      CHECK (admin_resolution_status IN ('open', 'resolved', 'dismissed', 'escalated'));
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_comment_reports_admin_resolution_status
  ON public.comment_reports (admin_resolution_status);

CREATE INDEX IF NOT EXISTS idx_comment_reports_admin_resolved_at
  ON public.comment_reports (admin_resolved_at DESC)
  WHERE admin_resolved_at IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_comment_reports_comment_id
  ON public.comment_reports (comment_id);

CREATE INDEX IF NOT EXISTS idx_comment_reports_venue_event_id
  ON public.comment_reports (venue_event_id);

CREATE INDEX IF NOT EXISTS idx_user_reports_admin_resolution_status
  ON public.user_reports (admin_resolution_status);

CREATE INDEX IF NOT EXISTS idx_user_reports_admin_resolved_at
  ON public.user_reports (admin_resolved_at DESC)
  WHERE admin_resolved_at IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_user_reports_reporter_user_id
  ON public.user_reports (reporter_user_id);

CREATE INDEX IF NOT EXISTS idx_user_reports_reported_user_id
  ON public.user_reports (reported_user_id);

CREATE INDEX IF NOT EXISTS idx_message_reports_admin_resolution_status
  ON public.message_reports (admin_resolution_status);

CREATE INDEX IF NOT EXISTS idx_message_reports_admin_resolved_at
  ON public.message_reports (admin_resolved_at DESC)
  WHERE admin_resolved_at IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_message_reports_reported_user_id
  ON public.message_reports (reported_user_id);

CREATE INDEX IF NOT EXISTS idx_conversation_reports_admin_resolution_status
  ON public.conversation_reports (admin_resolution_status);

CREATE INDEX IF NOT EXISTS idx_conversation_reports_admin_resolved_at
  ON public.conversation_reports (admin_resolved_at DESC)
  WHERE admin_resolved_at IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_conversation_reports_reported_user_id
  ON public.conversation_reports (reported_user_id);

CREATE INDEX IF NOT EXISTS idx_venue_reports_admin_resolution_status
  ON public.venue_reports (admin_resolution_status);

CREATE INDEX IF NOT EXISTS idx_venue_reports_admin_resolved_at
  ON public.venue_reports (admin_resolved_at DESC)
  WHERE admin_resolved_at IS NOT NULL;
