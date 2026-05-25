create table if not exists public.business_bans (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  owner_user_id uuid null,
  owner_email text null,
  is_permanent boolean not null default false,
  banned_until timestamptz null,
  reason text not null,
  admin_note text null,
  created_at timestamptz not null default now(),
  created_by uuid null,
  lifted_at timestamptz null,
  lifted_by uuid null,
  lift_reason text null
);

create index if not exists business_bans_business_id_idx
  on public.business_bans (business_id);

create index if not exists business_bans_owner_user_id_idx
  on public.business_bans (owner_user_id)
  where owner_user_id is not null;

create index if not exists business_bans_owner_email_idx
  on public.business_bans (lower(owner_email))
  where owner_email is not null;

create index if not exists business_bans_active_idx
  on public.business_bans (business_id, lifted_at, is_permanent, banned_until);

create index if not exists business_bans_created_at_idx
  on public.business_bans (created_at desc);

alter table public.business_bans enable row level security;

drop policy if exists "service_role_manage_business_bans" on public.business_bans;
create policy "service_role_manage_business_bans"
  on public.business_bans
  for all
  using (auth.role() = 'service_role')
  with check (auth.role() = 'service_role');
