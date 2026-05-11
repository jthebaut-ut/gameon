-- Venue-event comment moderation: persisted report counts, last-report time, one-shot admin email flag.
-- Auto-hide at 3+ reports via trigger on comment_reports INSERT (distinct reporters = one row per reporter).

ALTER TABLE public.venue_event_comments
  ADD COLUMN IF NOT EXISTS moderation_report_count integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS moderation_last_reported_at timestamptz,
  ADD COLUMN IF NOT EXISTS moderation_alert_sent_at timestamptz;

-- Backfill from existing comment_reports (one row per distinct reporter per comment).
WITH agg AS (
  SELECT
    comment_id,
    COUNT(*)::integer AS cnt,
    MAX(created_at) AS last_at
  FROM public.comment_reports
  GROUP BY comment_id
)
UPDATE public.venue_event_comments v
SET
  moderation_report_count = GREATEST(v.moderation_report_count, agg.cnt),
  moderation_last_reported_at = COALESCE(agg.last_at, v.moderation_last_reported_at),
  is_moderation_hidden = (GREATEST(v.moderation_report_count, agg.cnt) >= 3) OR v.is_moderation_hidden
FROM agg
WHERE v.id = agg.comment_id;

-- Bump counts and hide at threshold on each new report row.
CREATE OR REPLACE FUNCTION public.trg_comment_reports_bump_moderation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.venue_event_comments v
  SET
    moderation_report_count = v.moderation_report_count + 1,
    moderation_last_reported_at = now(),
    is_moderation_hidden = (v.moderation_report_count + 1 >= 3) OR v.is_moderation_hidden
  WHERE v.id = NEW.comment_id;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS comment_reports_bump_moderation ON public.comment_reports;

CREATE TRIGGER comment_reports_bump_moderation
  AFTER INSERT ON public.comment_reports
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_comment_reports_bump_moderation();
