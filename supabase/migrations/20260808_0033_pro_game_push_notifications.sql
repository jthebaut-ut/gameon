-- Backend push notification support for closed-app Pro Game score alerts.
-- Local notifications remain for kickoff reminders and foreground fallback alerts.

CREATE TABLE IF NOT EXISTS public.user_push_tokens (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  token text NOT NULL CHECK (char_length(trim(token)) > 0),
  platform text NOT NULL DEFAULT 'ios' CHECK (platform IN ('ios')),
  environment text NOT NULL CHECK (environment IN ('sandbox', 'production')),
  is_active boolean NOT NULL DEFAULT true,
  invalidated_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  last_seen_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT user_push_tokens_user_token_env_unique UNIQUE (user_id, token, environment)
);

CREATE INDEX IF NOT EXISTS idx_user_push_tokens_user_active
  ON public.user_push_tokens (user_id, is_active);

CREATE OR REPLACE FUNCTION public.user_push_tokens_touch_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS user_push_tokens_touch_updated_at_bu
  ON public.user_push_tokens;
CREATE TRIGGER user_push_tokens_touch_updated_at_bu
  BEFORE UPDATE ON public.user_push_tokens
  FOR EACH ROW
  EXECUTE FUNCTION public.user_push_tokens_touch_updated_at();

ALTER TABLE public.user_push_tokens ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS user_push_tokens_select_own
  ON public.user_push_tokens;
CREATE POLICY user_push_tokens_select_own
  ON public.user_push_tokens
  FOR SELECT
  TO authenticated
  USING (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS user_push_tokens_insert_own
  ON public.user_push_tokens;
CREATE POLICY user_push_tokens_insert_own
  ON public.user_push_tokens
  FOR INSERT
  TO authenticated
  WITH CHECK (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS user_push_tokens_update_own
  ON public.user_push_tokens;
CREATE POLICY user_push_tokens_update_own
  ON public.user_push_tokens
  FOR UPDATE
  TO authenticated
  USING (user_id = (SELECT auth.uid()))
  WITH CHECK (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS user_push_tokens_delete_own
  ON public.user_push_tokens;
CREATE POLICY user_push_tokens_delete_own
  ON public.user_push_tokens
  FOR DELETE
  TO authenticated
  USING (user_id = (SELECT auth.uid()));

GRANT SELECT, INSERT, UPDATE, DELETE ON public.user_push_tokens TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.user_push_tokens TO service_role;

ALTER TABLE public.saved_pro_games
  ADD COLUMN IF NOT EXISTS score_alerts_enabled boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS final_score_alerts_enabled boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS last_notified_scoreline text,
  ADD COLUMN IF NOT EXISTS last_notified_status text,
  ADD COLUMN IF NOT EXISTS score_alerts_updated_at timestamptz NOT NULL DEFAULT now();

CREATE INDEX IF NOT EXISTS idx_saved_pro_games_score_alert_worker
  ON public.saved_pro_games (start_time, score_alerts_enabled, final_score_alerts_enabled);

CREATE TABLE IF NOT EXISTS public.user_notification_preferences (
  user_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  pro_game_final_score_alerts_enabled boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION public.user_notification_preferences_touch_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS user_notification_preferences_touch_updated_at_bu
  ON public.user_notification_preferences;
CREATE TRIGGER user_notification_preferences_touch_updated_at_bu
  BEFORE UPDATE ON public.user_notification_preferences
  FOR EACH ROW
  EXECUTE FUNCTION public.user_notification_preferences_touch_updated_at();

ALTER TABLE public.user_notification_preferences ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS user_notification_preferences_select_own
  ON public.user_notification_preferences;
CREATE POLICY user_notification_preferences_select_own
  ON public.user_notification_preferences
  FOR SELECT
  TO authenticated
  USING (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS user_notification_preferences_insert_own
  ON public.user_notification_preferences;
CREATE POLICY user_notification_preferences_insert_own
  ON public.user_notification_preferences
  FOR INSERT
  TO authenticated
  WITH CHECK (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS user_notification_preferences_update_own
  ON public.user_notification_preferences;
CREATE POLICY user_notification_preferences_update_own
  ON public.user_notification_preferences
  FOR UPDATE
  TO authenticated
  USING (user_id = (SELECT auth.uid()))
  WITH CHECK (user_id = (SELECT auth.uid()));

GRANT SELECT, INSERT, UPDATE ON public.user_notification_preferences TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.user_notification_preferences TO service_role;

CREATE TABLE IF NOT EXISTS public.pro_game_alert_subscriptions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  live_match_id text NOT NULL,
  subscription_source text NOT NULL DEFAULT 'favorite_team'
    CHECK (subscription_source IN ('favorite_team')),
  favorite_team_id text,
  favorite_team_name text,
  source text,
  external_id text,
  home_team text NOT NULL,
  away_team text NOT NULL,
  league text,
  sport text,
  start_time timestamptz NOT NULL,
  match_status text,
  score_home integer NOT NULL DEFAULT 0,
  score_away integer NOT NULL DEFAULT 0,
  score_alerts_enabled boolean NOT NULL DEFAULT false,
  final_score_alerts_enabled boolean NOT NULL DEFAULT true,
  last_notified_scoreline text,
  last_notified_status text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT pro_game_alert_subscriptions_user_game_source_unique
    UNIQUE (user_id, live_match_id, subscription_source)
);

CREATE INDEX IF NOT EXISTS idx_pro_game_alert_subscriptions_worker
  ON public.pro_game_alert_subscriptions (start_time, score_alerts_enabled, final_score_alerts_enabled);

CREATE OR REPLACE FUNCTION public.pro_game_alert_subscriptions_touch_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS pro_game_alert_subscriptions_touch_updated_at_bu
  ON public.pro_game_alert_subscriptions;
CREATE TRIGGER pro_game_alert_subscriptions_touch_updated_at_bu
  BEFORE UPDATE ON public.pro_game_alert_subscriptions
  FOR EACH ROW
  EXECUTE FUNCTION public.pro_game_alert_subscriptions_touch_updated_at();

ALTER TABLE public.pro_game_alert_subscriptions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS pro_game_alert_subscriptions_select_own
  ON public.pro_game_alert_subscriptions;
CREATE POLICY pro_game_alert_subscriptions_select_own
  ON public.pro_game_alert_subscriptions
  FOR SELECT
  TO authenticated
  USING (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS pro_game_alert_subscriptions_insert_own
  ON public.pro_game_alert_subscriptions;
CREATE POLICY pro_game_alert_subscriptions_insert_own
  ON public.pro_game_alert_subscriptions
  FOR INSERT
  TO authenticated
  WITH CHECK (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS pro_game_alert_subscriptions_update_own
  ON public.pro_game_alert_subscriptions;
CREATE POLICY pro_game_alert_subscriptions_update_own
  ON public.pro_game_alert_subscriptions
  FOR UPDATE
  TO authenticated
  USING (user_id = (SELECT auth.uid()))
  WITH CHECK (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS pro_game_alert_subscriptions_delete_own
  ON public.pro_game_alert_subscriptions;
CREATE POLICY pro_game_alert_subscriptions_delete_own
  ON public.pro_game_alert_subscriptions
  FOR DELETE
  TO authenticated
  USING (user_id = (SELECT auth.uid()));

GRANT SELECT, INSERT, UPDATE, DELETE ON public.pro_game_alert_subscriptions TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.pro_game_alert_subscriptions TO service_role;

CREATE TABLE IF NOT EXISTS public.pro_game_score_notification_deliveries (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  game_id text NOT NULL,
  notification_type text NOT NULL CHECK (notification_type IN ('score', 'final')),
  scoreline text NOT NULL,
  delivered_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT pro_game_score_notification_deliveries_unique
    UNIQUE (user_id, game_id, notification_type, scoreline)
);

CREATE INDEX IF NOT EXISTS idx_pro_game_score_notification_deliveries_user_game
  ON public.pro_game_score_notification_deliveries (user_id, game_id);

ALTER TABLE public.pro_game_score_notification_deliveries ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS pro_game_score_notification_deliveries_select_own
  ON public.pro_game_score_notification_deliveries;
CREATE POLICY pro_game_score_notification_deliveries_select_own
  ON public.pro_game_score_notification_deliveries
  FOR SELECT
  TO authenticated
  USING (user_id = (SELECT auth.uid()));

GRANT SELECT ON public.pro_game_score_notification_deliveries TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.pro_game_score_notification_deliveries TO service_role;

COMMENT ON TABLE public.user_push_tokens IS
  'APNs device tokens for backend push notifications. Tokens are user-owned and inactive tokens are deleted or marked inactive by Edge Functions.';

COMMENT ON TABLE public.pro_game_alert_subscriptions IS
  'Backend-visible Pro Game alert subscriptions for favorite-team tracked games that are not manually saved.';

COMMENT ON TABLE public.pro_game_score_notification_deliveries IS
  'Dedupe ledger for closed-app Pro Game score and final push notifications.';
