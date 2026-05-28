-- Pickup game audience expansion: age ranges are optional and preserve existing rows.

alter table public.pickup_games
  add column if not exists age_min integer,
  add column if not exists age_max integer;

alter table public.pickup_games drop constraint if exists pickup_games_participant_preference_check;
alter table public.pickup_games drop constraint if exists pickup_games_age_range_check;

alter table public.pickup_games
  add constraint pickup_games_participant_preference_check
  check (participant_preference in (
    'everyone',
    'women_only',
    'men_only',
    'kids_only',
    'adults_only',
    'teens_welcome',
    'seniors_welcome'
  ));

alter table public.pickup_games
  add constraint pickup_games_age_range_check
  check (
    (age_min is null and age_max is null)
    or (
      age_min between 1 and 99
      and (age_max is null or age_max between age_min and 99)
    )
  );

comment on column public.pickup_games.participant_preference is 'Audience preference for organizers: everyone, women_only, men_only, kids_only, adults_only, teens_welcome, seniors_welcome.';
comment on column public.pickup_games.age_min is 'Optional minimum participant age for pickup games.';
comment on column public.pickup_games.age_max is 'Optional maximum participant age for pickup games; null means open-ended.';
