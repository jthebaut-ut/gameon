-- Private Messaging Safety Phase 1: conversation + message reports, DM moderation metadata.
-- TODO: Harden RLS for admin/moderator read paths and add server-side rate limiting (RPC).
-- TODO: Wire Terms of Service / Community Guidelines links in-app.

-- ---------------------------------------------------------------------------
-- direct_messages: moderation metadata (non-breaking additions)
-- ---------------------------------------------------------------------------
ALTER TABLE public.direct_messages
  ADD COLUMN IF NOT EXISTS report_count integer NOT NULL DEFAULT 0;

ALTER TABLE public.direct_messages
  ADD COLUMN IF NOT EXISTS is_deleted boolean NOT NULL DEFAULT false;

-- deleted_at may already exist from prior schema; keep both for compatibility.
-- Soft-delete path: set is_deleted = true AND deleted_at = now() when implementing server-side moderation.

-- ---------------------------------------------------------------------------
-- conversation_reports
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.conversation_reports (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  reporter_user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  reported_user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  conversation_id uuid NOT NULL,
  category text NOT NULL,
  details text,
  status text NOT NULL DEFAULT 'open',
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT conversation_reports_status_check CHECK (status IN ('open', 'closed', 'actioned'))
);

CREATE INDEX IF NOT EXISTS idx_conversation_reports_reporter ON public.conversation_reports (reporter_user_id);
CREATE INDEX IF NOT EXISTS idx_conversation_reports_conversation ON public.conversation_reports (conversation_id);
CREATE INDEX IF NOT EXISTS idx_conversation_reports_status ON public.conversation_reports (status);

ALTER TABLE public.conversation_reports ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can insert own conversation reports"
  ON public.conversation_reports FOR INSERT
  WITH CHECK (auth.uid() = reporter_user_id);

CREATE POLICY "Users can read own conversation reports"
  ON public.conversation_reports FOR SELECT
  USING (auth.uid() = reporter_user_id);

-- TODO: Admin dashboard policy (service role or role claim) to SELECT all conversation_reports.

-- ---------------------------------------------------------------------------
-- message_reports
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.message_reports (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  reporter_user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  reported_user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  message_id uuid NOT NULL REFERENCES public.direct_messages (id) ON DELETE CASCADE,
  message_text_snapshot text NOT NULL,
  category text NOT NULL,
  details text,
  status text NOT NULL DEFAULT 'open',
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT message_reports_status_check CHECK (status IN ('open', 'closed', 'actioned'))
);

CREATE INDEX IF NOT EXISTS idx_message_reports_reporter ON public.message_reports (reporter_user_id);
CREATE INDEX IF NOT EXISTS idx_message_reports_message ON public.message_reports (message_id);
CREATE INDEX IF NOT EXISTS idx_message_reports_status ON public.message_reports (status);

ALTER TABLE public.message_reports ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can insert own message reports"
  ON public.message_reports FOR INSERT
  WITH CHECK (auth.uid() = reporter_user_id);

CREATE POLICY "Users can read own message reports"
  ON public.message_reports FOR SELECT
  USING (auth.uid() = reporter_user_id);

-- TODO: Admin dashboard policy for full message_reports access.
