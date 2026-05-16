-- Explicit `withdrawn` status for joiners backing out after approval (distinct from `cancelled` while pending).
-- `pickup_games_refresh_approved_join_count` already counts only `approved`.

ALTER TABLE public.pickup_game_requests DROP CONSTRAINT IF EXISTS pickup_game_requests_status_check;
ALTER TABLE public.pickup_game_requests
  ADD CONSTRAINT pickup_game_requests_status_check
  CHECK (status IN ('pending', 'approved', 'rejected', 'cancelled', 'withdrawn'));

CREATE OR REPLACE FUNCTION public.pickup_game_requests_before_update_status()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  is_creator boolean;
  need int;
  cur int;
BEGIN
  IF OLD.status = NEW.status THEN
    RETURN NEW;
  END IF;

  SELECT (g.creator_user_id = (SELECT auth.uid())) INTO is_creator
  FROM public.pickup_games g
  WHERE g.id = NEW.pickup_game_id;

  -- Requester: cancel (pending / approved / rejected) or withdraw after approval only.
  IF NEW.status = 'cancelled' THEN
    IF NEW.requester_user_id IS DISTINCT FROM (SELECT auth.uid()) THEN
      RAISE EXCEPTION 'pickup_request_cancel_forbidden' USING ERRCODE = 'check_violation';
    END IF;
    IF OLD.status NOT IN ('pending', 'approved', 'rejected') THEN
      RAISE EXCEPTION 'pickup_request_cancel_forbidden' USING ERRCODE = 'check_violation';
    END IF;
  ELSIF NEW.status = 'withdrawn' THEN
    IF NEW.requester_user_id IS DISTINCT FROM (SELECT auth.uid()) THEN
      RAISE EXCEPTION 'pickup_request_cancel_forbidden' USING ERRCODE = 'check_violation';
    END IF;
    IF OLD.status <> 'approved' THEN
      RAISE EXCEPTION 'pickup_request_cancel_forbidden' USING ERRCODE = 'check_violation';
    END IF;
  ELSIF NEW.status IN ('approved', 'rejected') THEN
    IF NOT is_creator OR OLD.status <> 'pending' THEN
      RAISE EXCEPTION 'pickup_request_decision_forbidden' USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.status = 'approved' THEN
      PERFORM 1 FROM public.pickup_games WHERE id = NEW.pickup_game_id FOR UPDATE;
      SELECT players_needed INTO need FROM public.pickup_games WHERE id = NEW.pickup_game_id;
      SELECT count(*)::int INTO cur
      FROM public.pickup_game_requests r
      WHERE r.pickup_game_id = NEW.pickup_game_id
        AND r.status = 'approved'
        AND r.id IS DISTINCT FROM NEW.id;
      IF cur >= need THEN
        RAISE EXCEPTION 'pickup_game_full' USING ERRCODE = 'check_violation';
      END IF;
    END IF;
  ELSE
    RAISE EXCEPTION 'pickup_request_status_forbidden' USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;
