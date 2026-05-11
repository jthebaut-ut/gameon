-- Recompute venue_event_comments.moderation_report_count from comment_reports on INSERT and DELETE
-- (supports unflag). Sticky auto-hide MVP: is_moderation_hidden never clears via this trigger; it becomes true when active count >= 3.

CREATE OR REPLACE FUNCTION public.trg_comment_reports_sync_moderation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cid uuid;
  agg_count integer;
  agg_last timestamptz;
BEGIN
  cid := COALESCE(NEW.comment_id, OLD.comment_id);

  SELECT COUNT(*)::integer, MAX(r.created_at)
  INTO agg_count, agg_last
  FROM public.comment_reports r
  WHERE r.comment_id = cid;

  IF agg_count IS NULL THEN
    agg_count := 0;
  END IF;

  UPDATE public.venue_event_comments v
  SET
    moderation_report_count = agg_count,
    moderation_last_reported_at = agg_last,
    is_moderation_hidden = v.is_moderation_hidden OR (agg_count >= 3)
  WHERE v.id = cid;

  RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS comment_reports_bump_moderation ON public.comment_reports;
DROP FUNCTION IF EXISTS public.trg_comment_reports_bump_moderation();

CREATE TRIGGER comment_reports_sync_moderation
  AFTER INSERT OR DELETE ON public.comment_reports
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_comment_reports_sync_moderation();
