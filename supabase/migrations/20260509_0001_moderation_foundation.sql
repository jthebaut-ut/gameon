-- Moderation foundation: user reports + blocking
-- Minimal schema to support App Store moderation readiness.
-- NOTE: This repo previously lacked migrations; add these to restore auditable backend state.

create table if not exists public.blocked_users (
  blocker_user_id uuid not null,
  blocked_user_id uuid not null,
  created_at timestamptz not null default now(),
  primary key (blocker_user_id, blocked_user_id)
);

create table if not exists public.user_reports (
  id uuid primary key default gen_random_uuid(),
  reporter_user_id uuid not null,
  reported_user_id uuid not null,
  category text not null,
  details text,
  created_at timestamptz not null default now()
);

-- Enable RLS (server-side enforcement). Policies are intentionally minimal.
alter table public.blocked_users enable row level security;
alter table public.user_reports enable row level security;

-- blocked_users: users can manage their own block list (does not expose who blocked them).
do $$ begin
  create policy "blocked_users_select_own"
    on public.blocked_users
    for select
    to authenticated
    using (blocker_user_id = auth.uid());
exception when duplicate_object then null; end $$;

do $$ begin
  create policy "blocked_users_insert_own"
    on public.blocked_users
    for insert
    to authenticated
    with check (blocker_user_id = auth.uid());
exception when duplicate_object then null; end $$;

do $$ begin
  create policy "blocked_users_delete_own"
    on public.blocked_users
    for delete
    to authenticated
    using (blocker_user_id = auth.uid());
exception when duplicate_object then null; end $$;

-- user_reports: users can file reports; reading is not allowed to normal users (admin tooling later).
do $$ begin
  create policy "user_reports_insert_own"
    on public.user_reports
    for insert
    to authenticated
    with check (reporter_user_id = auth.uid());
exception when duplicate_object then null; end $$;

