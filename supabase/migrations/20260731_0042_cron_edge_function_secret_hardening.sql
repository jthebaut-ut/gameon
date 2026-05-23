-- FanGeo cron Edge Function secret hardening.
--
-- SQL/migration only. No raw service role key is stored in this migration.
-- If Supabase Vault contains the required secret rows, the sync-live-matches
-- cron job is recreated so cron.job stores only Vault secret names.

CREATE SCHEMA IF NOT EXISTS extensions;
CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA extensions;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_available_extensions
    WHERE name = 'pg_net'
  ) THEN
    EXECUTE 'CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA extensions';
  ELSE
    RAISE NOTICE 'pg_net is not available; Edge Function cron jobs must be configured manually.';
  END IF;
END $$;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_available_extensions
    WHERE name = 'supabase_vault'
  ) THEN
    EXECUTE 'CREATE SCHEMA IF NOT EXISTS vault';
    EXECUTE 'CREATE EXTENSION IF NOT EXISTS supabase_vault WITH SCHEMA vault';
  ELSE
    RAISE NOTICE 'supabase_vault is not available; see docs/ops/Supabase_Cron_Secrets.md for manual secret-safe cron setup.';
  END IF;
END $$;

-- Redacted audit of the relevant cron rows. This reports whether a placeholder
-- or legacy purge command is present without printing command text.
DO $$
DECLARE
  inspected_job record;
BEGIN
  FOR inspected_job IN
    SELECT
      jobname,
      schedule,
      active,
      command ILIKE '%YOUR_SERVICE_ROLE_KEY%' AS has_placeholder_service_role_key,
      command ILIKE '%purge_expired_venue_events%' AS calls_legacy_venue_purge,
      command ILIKE '%cleanup_expired_game_social_phase2%' AS calls_safe_cleanup
    FROM cron.job
    WHERE jobname IN (
      'sync-live-matches-every-5-min',
      'fangeo_expired_game_social_cleanup_hourly'
    )
       OR command ILIKE '%purge_expired_venue_events%'
  LOOP
    RAISE NOTICE
      'cron audit jobname=%, schedule=%, active=%, has_placeholder_service_role_key=%, calls_legacy_venue_purge=%, calls_safe_cleanup=%',
      inspected_job.jobname,
      inspected_job.schedule,
      inspected_job.active,
      inspected_job.has_placeholder_service_role_key,
      inspected_job.calls_legacy_venue_purge,
      inspected_job.calls_safe_cleanup;
  END LOOP;
END $$;

-- Remove any broken placeholder cron entries so cron.job no longer contains
-- "Bearer YOUR_SERVICE_ROLE_KEY".
DO $$
DECLARE
  placeholder_job record;
BEGIN
  FOR placeholder_job IN
    SELECT jobid
    FROM cron.job
    WHERE command ILIKE '%YOUR_SERVICE_ROLE_KEY%'
       OR command ILIKE '%Bearer YOUR_SERVICE_ROLE_KEY%'
  LOOP
    PERFORM cron.unschedule(placeholder_job.jobid);
  END LOOP;
END $$;

-- Keep the legacy venue-event purge off the scheduler. The Phase 2 cleanup job
-- below is the only scheduled venue-event/social cleanup path.
DO $$
DECLARE
  legacy_job record;
BEGIN
  FOR legacy_job IN
    SELECT jobid
    FROM cron.job
    WHERE command ILIKE '%purge_expired_venue_events%'
  LOOP
    PERFORM cron.unschedule(legacy_job.jobid);
  END LOOP;
END $$;

-- Ensure the hourly database cleanup remains active. This job calls the safe
-- Phase 2B cleanup RPC directly inside Postgres, so it does not need an HTTP
-- Authorization header or a stored service-role key.
SELECT cron.unschedule('fangeo_expired_game_social_cleanup_hourly')
WHERE EXISTS (
  SELECT 1
  FROM cron.job
  WHERE jobname = 'fangeo_expired_game_social_cleanup_hourly'
);

SELECT cron.schedule(
  'fangeo_expired_game_social_cleanup_hourly',
  '0 * * * *',
  $$
    SELECT public.cleanup_expired_game_social_phase2(
      p_now := now(),
      p_limit := 500,
      p_dry_run := false
    );
  $$
);

-- Recreate the live matches Edge Function cron with Vault-backed runtime
-- secret lookup when the project has Vault and the expected secret rows.
DO $$
DECLARE
  v_url_secret_name text;
  v_service_role_secret_name text;
  v_sync_command text;
BEGIN
  IF to_regclass('vault.decrypted_secrets') IS NULL THEN
    RAISE NOTICE 'Vault decrypted secrets view is unavailable; sync-live-matches cron was not recreated automatically.';
    RETURN;
  END IF;

  IF to_regnamespace('net') IS NULL THEN
    RAISE NOTICE 'pg_net schema is unavailable; sync-live-matches cron was not recreated automatically.';
    RETURN;
  END IF;

  EXECUTE $secrets$
    SELECT
      COALESCE(
        (
          SELECT name
          FROM vault.decrypted_secrets
          WHERE name = 'fangeo_supabase_url'
            AND NULLIF(BTRIM(decrypted_secret), '') IS NOT NULL
          LIMIT 1
        ),
        (
          SELECT name
          FROM vault.decrypted_secrets
          WHERE name = 'SUPABASE_URL'
            AND NULLIF(BTRIM(decrypted_secret), '') IS NOT NULL
          LIMIT 1
        )
      ) AS url_secret_name,
      COALESCE(
        (
          SELECT name
          FROM vault.decrypted_secrets
          WHERE name = 'fangeo_service_role_key'
            AND NULLIF(BTRIM(decrypted_secret), '') IS NOT NULL
          LIMIT 1
        ),
        (
          SELECT name
          FROM vault.decrypted_secrets
          WHERE name = 'SUPABASE_SERVICE_ROLE_KEY'
            AND NULLIF(BTRIM(decrypted_secret), '') IS NOT NULL
          LIMIT 1
        )
      ) AS service_role_secret_name
  $secrets$
  INTO v_url_secret_name, v_service_role_secret_name;

  IF v_url_secret_name IS NULL OR v_service_role_secret_name IS NULL THEN
    RAISE NOTICE 'Required Vault secrets are missing; create fangeo_supabase_url and fangeo_service_role_key, then rerun the scheduling SQL from docs/ops/Supabase_Cron_Secrets.md.';
    RETURN;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM cron.job
    WHERE jobname = 'sync-live-matches-every-5-min'
  ) THEN
    PERFORM cron.unschedule('sync-live-matches-every-5-min');
  END IF;

  v_sync_command := format(
    $command$
      SELECT net.http_post(
        url := (
          SELECT RTRIM(decrypted_secret, '/')
          FROM vault.decrypted_secrets
          WHERE name = %L
          ORDER BY updated_at DESC NULLS LAST, created_at DESC
          LIMIT 1
        ) || '/functions/v1/sync-live-matches',
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'Authorization', 'Bearer ' || (
            SELECT decrypted_secret
            FROM vault.decrypted_secrets
            WHERE name = %L
            ORDER BY updated_at DESC NULLS LAST, created_at DESC
            LIMIT 1
          )
        ),
        body := '{}'::jsonb,
        timeout_milliseconds := 30000
      );
    $command$,
    v_url_secret_name,
    v_service_role_secret_name
  );

  PERFORM cron.schedule(
    'sync-live-matches-every-5-min',
    '*/5 * * * *',
    v_sync_command
  );
END $$;
