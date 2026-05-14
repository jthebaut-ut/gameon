-- Phase 2: pickup game join requests (organizer approve/reject). Venue/business flows unchanged.

-- ---------------------------------------------------------------------------
-- Denormalized count on pickup_games (maintained by trigger; used by RLS + app)
-- ---------------------------------------------------------------------------
ALTER TABLE public.pickup_games
  ADD COLUMN IF NOT EXISTS approved_join_count integer NOT NULL DEFAULT 0;

ALTER TABLE public.pickup_games DROP CONSTRAINT IF EXISTS pickup_games_approved_join_count_nonneg_ck;
ALTER TABLE public.pickup_games
  ADD CONSTRAINT pickup_games_approved_join_count_nonneg_ck
  CHECK (approved_join_count >= 0);

-- ---------------------------------------------------------------------------
-- pickup_game_requests
-- ---------------------------------------------------------------------------
CREATE TABLE public.pickup_game_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pickup_game_id uuid NOT NULL REFERENCES public.pickup_games (id) ON DELETE CASCADE,
  requester_user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  requester_email text,
  requester_display_name text,
  requester_skill_level text NOT NULL
    CHECK (requester_skill_level IN ('casual', 'beginner_friendly', 'intermediate', 'competitive')),
  message text,
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'approved', 'rejected', 'cancelled')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  responded_at timestamptz
);

CREATE INDEX pickup_game_requests_game_id_idx ON public.pickup_game_requests (pickup_game_id);
CREATE INDEX pickup_game_requests_requester_id_idx ON public.pickup_game_requests (requester_user_id);

-- One active pending request per requester per game
CREATE UNIQUE INDEX pickup_game_requests_one_pending_per_user_game_idx
  ON public.pickup_game_requests (pickup_game_id, requester_user_id)
  WHERE status = 'pending';

COMMENT ON TABLE public.pickup_game_requests IS 'Fan join requests for pickup games; organizer approves/rejects.';

-- ---------------------------------------------------------------------------
-- Touch updated_at / responded_at
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.pickup_game_requests_touch_audit()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at := now();
  IF TG_OP = 'UPDATE' THEN
    IF NEW.status IN ('approved', 'rejected')
       AND OLD.status = 'pending'
       AND NEW.responded_at IS NULL THEN
      NEW.responded_at := now();
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS pickup_game_requests_touch_audit ON public.pickup_game_requests;
CREATE TRIGGER pickup_game_requests_touch_audit
  BEFORE INSERT OR UPDATE ON public.pickup_game_requests
  FOR EACH ROW
  EXECUTE FUNCTION public.pickup_game_requests_touch_audit();

-- Serialize approvals per game + block when full (runs after transition rules)
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

  IF NEW.status = 'cancelled' THEN
    IF NEW.requester_user_id IS DISTINCT FROM (SELECT auth.uid()) OR OLD.status <> 'pending' THEN
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

DROP TRIGGER IF EXISTS pickup_game_requests_enforce_capacity_bu ON public.pickup_game_requests;
DROP TRIGGER IF EXISTS pickup_game_requests_status_transitions_bu ON public.pickup_game_requests;
DROP TRIGGER IF EXISTS pickup_game_requests_before_update_status_bu ON public.pickup_game_requests;
CREATE TRIGGER pickup_game_requests_before_update_status_bu
  BEFORE UPDATE OF status ON public.pickup_game_requests
  FOR EACH ROW
  EXECUTE FUNCTION public.pickup_game_requests_before_update_status();

DROP FUNCTION IF EXISTS public.pickup_game_requests_enforce_capacity_on_approve();
DROP FUNCTION IF EXISTS public.pickup_game_requests_enforce_status_transitions();
CREATE OR REPLACE FUNCTION public.pickup_games_refresh_approved_join_count()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  gid uuid;
BEGIN
  gid := COALESCE(NEW.pickup_game_id, OLD.pickup_game_id);
  UPDATE public.pickup_games pg
  SET approved_join_count = (
      SELECT count(*)::int
      FROM public.pickup_game_requests r
      WHERE r.pickup_game_id = gid AND r.status = 'approved'
    ),
    updated_at = now()
  WHERE pg.id = gid;
  RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS pickup_game_requests_refresh_counts_aiud ON public.pickup_game_requests;
CREATE TRIGGER pickup_game_requests_refresh_counts_aiud
  AFTER INSERT OR UPDATE OR DELETE ON public.pickup_game_requests
  FOR EACH ROW
  EXECUTE FUNCTION public.pickup_games_refresh_approved_join_count();

-- Backfill approved_join_count from requests (table is new; counts are 0)
UPDATE public.pickup_games g
SET approved_join_count = (
  SELECT count(*)::int
  FROM public.pickup_game_requests r
  WHERE r.pickup_game_id = g.id AND r.status = 'approved'
);

-- ---------------------------------------------------------------------------
-- RLS: pickup_game_requests
-- ---------------------------------------------------------------------------
ALTER TABLE public.pickup_game_requests ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS pickup_game_requests_select_own_or_game_creator ON public.pickup_game_requests;
CREATE POLICY pickup_game_requests_select_own_or_game_creator
  ON public.pickup_game_requests
  FOR SELECT
  TO authenticated
  USING (
    requester_user_id = (SELECT auth.uid())
    OR EXISTS (
      SELECT 1 FROM public.pickup_games g
      WHERE g.id = pickup_game_id
        AND g.creator_user_id = (SELECT auth.uid())
    )
  );

DROP POLICY IF EXISTS pickup_game_requests_insert_own_not_creator ON public.pickup_game_requests;
CREATE POLICY pickup_game_requests_insert_own_not_creator
  ON public.pickup_game_requests
  FOR INSERT
  TO authenticated
  WITH CHECK (
    requester_user_id = (SELECT auth.uid())
    AND status = 'pending'
    AND EXISTS (
      SELECT 1 FROM public.pickup_games g
      WHERE g.id = pickup_game_id
        AND g.creator_user_id IS DISTINCT FROM (SELECT auth.uid())
        AND g.status = 'active'
    )
  );

DROP POLICY IF EXISTS pickup_game_requests_update_creator_decide ON public.pickup_game_requests;
CREATE POLICY pickup_game_requests_update_creator_decide
  ON public.pickup_game_requests
  FOR UPDATE
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.pickup_games g
      WHERE g.id = pickup_game_id
        AND g.creator_user_id = (SELECT auth.uid())
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.pickup_games g
      WHERE g.id = pickup_game_id
        AND g.creator_user_id = (SELECT auth.uid())
    )
  );

DROP POLICY IF EXISTS pickup_game_requests_update_requester_cancel ON public.pickup_game_requests;
CREATE POLICY pickup_game_requests_update_requester_cancel
  ON public.pickup_game_requests
  FOR UPDATE
  TO authenticated
  USING (requester_user_id = (SELECT auth.uid()))
  WITH CHECK (requester_user_id = (SELECT auth.uid()));

GRANT SELECT, INSERT, UPDATE ON public.pickup_game_requests TO authenticated;

-- ---------------------------------------------------------------------------
-- RLS: pickup_games — hide full games from non-creators (Discover map/calendar)
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS pickup_games_select_authenticated ON public.pickup_games;
CREATE POLICY pickup_games_select_authenticated
  ON public.pickup_games
  FOR SELECT
  TO authenticated
  USING (
    creator_user_id = (SELECT auth.uid())
    OR (
      status = 'active'
      AND is_visible
      AND remove_after_at IS NOT NULL
      AND remove_after_at > now()
      AND approved_join_count < players_needed
    )
  );
