-- Moderation: auto-hide venue-event comments after repeated reports; venue report intake.

ALTER TABLE public.venue_event_comments
  ADD COLUMN IF NOT EXISTS is_moderation_hidden boolean NOT NULL DEFAULT false;

CREATE INDEX IF NOT EXISTS idx_venue_event_comments_not_hidden
  ON public.venue_event_comments (venue_event_id, created_at DESC)
  WHERE is_moderation_hidden = false;

-- ---------------------------------------------------------------------------
-- venue_reports (fan / owner reports about a venue listing)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.venue_reports (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  reporter_user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  venue_id uuid NOT NULL REFERENCES public.venues (id) ON DELETE CASCADE,
  category text NOT NULL,
  details text,
  status text NOT NULL DEFAULT 'open',
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT venue_reports_status_check CHECK (status IN ('open', 'closed', 'actioned'))
);

CREATE INDEX IF NOT EXISTS idx_venue_reports_reporter ON public.venue_reports (reporter_user_id);
CREATE INDEX IF NOT EXISTS idx_venue_reports_venue ON public.venue_reports (venue_id);
CREATE INDEX IF NOT EXISTS idx_venue_reports_status ON public.venue_reports (status);

ALTER TABLE public.venue_reports ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can insert own venue reports"
  ON public.venue_reports FOR INSERT
  WITH CHECK (auth.uid() = reporter_user_id);

CREATE POLICY "Users can read own venue reports"
  ON public.venue_reports FOR SELECT
  USING (auth.uid() = reporter_user_id);
