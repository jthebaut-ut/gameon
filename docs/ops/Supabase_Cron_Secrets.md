# Supabase Cron Secrets

FanGeo uses Supabase cron for backend-only maintenance. Cron jobs must never store the raw service role key in the iOS app, client code, or committed migrations.

## Current Cron Jobs

- `sync-live-matches-every-5-min`: invokes the `sync-live-matches` Edge Function every five minutes. It needs a service role bearer token because the function updates the `live_matches` cache.
- `fangeo_expired_game_social_cleanup_hourly`: runs `public.cleanup_expired_game_social_phase2(p_now := now(), p_limit := 500, p_dry_run := false)` hourly inside Postgres. It does not invoke an Edge Function and does not need an HTTP bearer token.

The legacy `public.purge_expired_venue_events()` job must not be scheduled. It removes moderation reports and has been replaced by the Phase 2 cleanup path.

## Secret Storage

Preferred storage is Supabase Vault:

- `fangeo_supabase_url`: the project URL, for example `https://<project-ref>.supabase.co`.
- `fangeo_service_role_key`: the service role key.

The migration `20260731_0042_cron_edge_function_secret_hardening.sql` also accepts existing Vault names `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY`, but the `fangeo_*` names are preferred so cron-only secrets are easy to audit.

Create or rotate Vault secrets from the Supabase SQL editor. Paste the real service role key only into the SQL editor session, never into repo files:

```sql
select vault.create_secret('https://<project-ref>.supabase.co', 'fangeo_supabase_url');
select vault.create_secret('<service-role-key>', 'fangeo_service_role_key');
```

After the secrets exist, rerun the scheduling block from the hardening migration or apply the migration again in the target environment. The resulting `cron.job.command` stores only Vault secret names, not the decrypted key.

## How Cron Authenticates

For `sync-live-matches-every-5-min`, cron calls:

```sql
select net.http_post(
  url := (
    select rtrim(decrypted_secret, '/')
    from vault.decrypted_secrets
    where name = 'fangeo_supabase_url'
    order by updated_at desc nulls last, created_at desc
    limit 1
  ) || '/functions/v1/sync-live-matches',
  headers := jsonb_build_object(
    'Content-Type', 'application/json',
    'Authorization', 'Bearer ' || (
      select decrypted_secret
      from vault.decrypted_secrets
      where name = 'fangeo_service_role_key'
      order by updated_at desc nulls last, created_at desc
      limit 1
    )
  ),
  body := '{}'::jsonb,
  timeout_milliseconds := 30000
);
```

The secret is decrypted at job runtime by Postgres. The raw key should not appear in `cron.job.command`.

To manually reschedule the live sync job with Vault-backed auth, use this shape in the Supabase SQL editor after both Vault secrets exist:

```sql
select cron.unschedule('sync-live-matches-every-5-min')
where exists (
  select 1
  from cron.job
  where jobname = 'sync-live-matches-every-5-min'
);

select cron.schedule(
  'sync-live-matches-every-5-min',
  '*/5 * * * *',
  $$
    select net.http_post(
      url := (
        select rtrim(decrypted_secret, '/')
        from vault.decrypted_secrets
        where name = 'fangeo_supabase_url'
        order by updated_at desc nulls last, created_at desc
        limit 1
      ) || '/functions/v1/sync-live-matches',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Bearer ' || (
          select decrypted_secret
          from vault.decrypted_secrets
          where name = 'fangeo_service_role_key'
          order by updated_at desc nulls last, created_at desc
          limit 1
        )
      ),
      body := '{}'::jsonb,
      timeout_milliseconds := 30000
    );
  $$
);
```

## Vault Unavailable Fallback

If `supabase_vault` is unavailable, the safest option is to avoid a database HTTP cron job and use Supabase's scheduled Edge Function/dashboard scheduler if it can attach project secrets without storing them in `cron.job`.

If the only available path is `pg_cron + pg_net`, use a one-time SQL editor session to replace the broken bearer token manually. Do not save that SQL in the repo, screenshots, notes, or issue comments. Restrict `cron.job` visibility to privileged database operators and rotate the service role key immediately if it was ever copied into source control or shared logs.

## Rotate Service Role Key

1. Generate a new service role key in Supabase project settings.
2. Update the Edge Function secret if functions read it from project secrets:

```bash
supabase secrets set SUPABASE_SERVICE_ROLE_KEY='<new-service-role-key>'
```

3. Update Vault:

```sql
select vault.create_secret('<new-service-role-key>', 'fangeo_service_role_key');
```

4. Rerun the cron scheduling SQL so new jobs read the current Vault secret name.
5. Verify no cron command contains a literal bearer key or legacy placeholder.
6. Revoke the old service role key.

## Verification SQL

Inspect the active jobs:

```sql
select jobid, jobname, schedule, active, command
from cron.job
where jobname in (
  'sync-live-matches-every-5-min',
  'fangeo_expired_game_social_cleanup_hourly'
)
order by jobname;
```

Confirm the live sync job does not contain a placeholder or a literal JWT-looking service key:

```sql
select jobname, command
from cron.job
where jobname = 'sync-live-matches-every-5-min'
  and (
    command ilike '%YOUR_SERVICE_ROLE_KEY%'
    or command ~ 'Bearer[[:space:]]+eyJ'
  );
```

Expected result: zero rows.

Confirm hourly cleanup remains active:

```sql
select jobname, schedule, active, command
from cron.job
where jobname = 'fangeo_expired_game_social_cleanup_hourly'
  and schedule = '0 * * * *'
  and command ilike '%cleanup_expired_game_social_phase2%'
  and command not ilike '%purge_expired_venue_events%';
```

Expected result: one active hourly job.

Confirm the legacy venue-event purge is not scheduled:

```sql
select jobid, jobname, schedule, active, command
from cron.job
where command ilike '%purge_expired_venue_events%';
```

Expected result: zero rows.

Confirm Vault secret rows exist without printing decrypted values:

```sql
select name, created_at, updated_at
from vault.decrypted_secrets
where name in ('fangeo_supabase_url', 'fangeo_service_role_key')
order by name;
```

Expected result: two rows.

Confirm there is only one active row per preferred secret name:

```sql
select name, count(*) as rows
from vault.decrypted_secrets
where name in ('fangeo_supabase_url', 'fangeo_service_role_key')
group by name
having count(*) <> 1;
```

Expected result: zero rows.
