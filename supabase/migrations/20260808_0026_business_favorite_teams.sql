-- Business-selected favorite teams for Pro Games discovery.
-- Stores catalog team_id strings separately from fan profile favorites.

CREATE TABLE IF NOT EXISTS public.business_favorite_teams (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id uuid NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  team_id text NOT NULL CHECK (char_length(btrim(team_id)) > 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT business_favorite_teams_business_team_unique UNIQUE (business_id, team_id)
);

CREATE INDEX IF NOT EXISTS idx_business_favorite_teams_business_created
  ON public.business_favorite_teams (business_id, created_at);

CREATE INDEX IF NOT EXISTS idx_business_favorite_teams_team_id
  ON public.business_favorite_teams (team_id);

ALTER TABLE public.business_favorite_teams ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS business_favorite_teams_select_own_business
  ON public.business_favorite_teams;
CREATE POLICY business_favorite_teams_select_own_business
  ON public.business_favorite_teams
  FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.businesses b
      WHERE b.id = business_favorite_teams.business_id
        AND b.admin_status = 'active'
        AND (
          b.owner_user_id = (SELECT auth.uid())
          OR (
            NULLIF(btrim(coalesce(b.owner_email, '')), '') IS NOT NULL
            AND NULLIF(btrim(coalesce(auth.jwt() ->> 'email', '')), '') IS NOT NULL
            AND lower(btrim(b.owner_email)) = lower(btrim(auth.jwt() ->> 'email'))
          )
        )
    )
  );

DROP POLICY IF EXISTS business_favorite_teams_insert_own_business
  ON public.business_favorite_teams;
CREATE POLICY business_favorite_teams_insert_own_business
  ON public.business_favorite_teams
  FOR INSERT
  TO authenticated
  WITH CHECK (
    EXISTS (
      SELECT 1
      FROM public.businesses b
      WHERE b.id = business_favorite_teams.business_id
        AND b.admin_status = 'active'
        AND (
          b.owner_user_id = (SELECT auth.uid())
          OR (
            NULLIF(btrim(coalesce(b.owner_email, '')), '') IS NOT NULL
            AND NULLIF(btrim(coalesce(auth.jwt() ->> 'email', '')), '') IS NOT NULL
            AND lower(btrim(b.owner_email)) = lower(btrim(auth.jwt() ->> 'email'))
          )
        )
    )
  );

DROP POLICY IF EXISTS business_favorite_teams_update_own_business
  ON public.business_favorite_teams;
CREATE POLICY business_favorite_teams_update_own_business
  ON public.business_favorite_teams
  FOR UPDATE
  TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.businesses b
      WHERE b.id = business_favorite_teams.business_id
        AND b.admin_status = 'active'
        AND (
          b.owner_user_id = (SELECT auth.uid())
          OR (
            NULLIF(btrim(coalesce(b.owner_email, '')), '') IS NOT NULL
            AND NULLIF(btrim(coalesce(auth.jwt() ->> 'email', '')), '') IS NOT NULL
            AND lower(btrim(b.owner_email)) = lower(btrim(auth.jwt() ->> 'email'))
          )
        )
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1
      FROM public.businesses b
      WHERE b.id = business_favorite_teams.business_id
        AND b.admin_status = 'active'
        AND (
          b.owner_user_id = (SELECT auth.uid())
          OR (
            NULLIF(btrim(coalesce(b.owner_email, '')), '') IS NOT NULL
            AND NULLIF(btrim(coalesce(auth.jwt() ->> 'email', '')), '') IS NOT NULL
            AND lower(btrim(b.owner_email)) = lower(btrim(auth.jwt() ->> 'email'))
          )
        )
    )
  );

DROP POLICY IF EXISTS business_favorite_teams_delete_own_business
  ON public.business_favorite_teams;
CREATE POLICY business_favorite_teams_delete_own_business
  ON public.business_favorite_teams
  FOR DELETE
  TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.businesses b
      WHERE b.id = business_favorite_teams.business_id
        AND b.admin_status = 'active'
        AND (
          b.owner_user_id = (SELECT auth.uid())
          OR (
            NULLIF(btrim(coalesce(b.owner_email, '')), '') IS NOT NULL
            AND NULLIF(btrim(coalesce(auth.jwt() ->> 'email', '')), '') IS NOT NULL
            AND lower(btrim(b.owner_email)) = lower(btrim(auth.jwt() ->> 'email'))
          )
        )
    )
  );

GRANT SELECT, INSERT, UPDATE, DELETE ON public.business_favorite_teams TO authenticated;

COMMENT ON TABLE public.business_favorite_teams IS
  'Business-owned catalog team_id selections used for business Pro Games discovery and filtering.';
