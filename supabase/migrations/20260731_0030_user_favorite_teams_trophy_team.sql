-- Primary "Trophy Team" for fan favorite teams.
-- Keeps multiple favorites while enforcing at most one primary row per user.

ALTER TABLE public.user_favorite_teams
  ADD COLUMN IF NOT EXISTS is_primary boolean NOT NULL DEFAULT false;

WITH ranked AS (
  SELECT
    user_id,
    team_id,
    row_number() OVER (
      PARTITION BY user_id
      ORDER BY created_at ASC, team_id ASC
    ) AS rn,
    bool_or(is_primary) OVER (PARTITION BY user_id) AS has_primary
  FROM public.user_favorite_teams
)
UPDATE public.user_favorite_teams uft
SET is_primary = true
FROM ranked r
WHERE uft.user_id = r.user_id
  AND uft.team_id = r.team_id
  AND r.rn = 1
  AND r.has_primary = false;

CREATE OR REPLACE FUNCTION public.user_favorite_teams_clear_previous_primary()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.is_primary IS TRUE THEN
    UPDATE public.user_favorite_teams
    SET is_primary = false
    WHERE user_id = NEW.user_id
      AND team_id <> NEW.team_id
      AND is_primary IS TRUE;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_user_favorite_teams_single_primary
  ON public.user_favorite_teams;

CREATE TRIGGER trg_user_favorite_teams_single_primary
BEFORE INSERT OR UPDATE OF user_id, is_primary
ON public.user_favorite_teams
FOR EACH ROW
WHEN (NEW.is_primary IS TRUE)
EXECUTE FUNCTION public.user_favorite_teams_clear_previous_primary();

CREATE UNIQUE INDEX IF NOT EXISTS idx_user_favorite_teams_one_primary
  ON public.user_favorite_teams (user_id)
  WHERE is_primary IS TRUE;

COMMENT ON COLUMN public.user_favorite_teams.is_primary IS
  'True for the fan primary Trophy Team. At most one primary favorite team is allowed per user.';
