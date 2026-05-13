-- Pickup games: extended fan metadata (play environment, preferences, cost, capacity).
-- Skill level vocabulary replaces legacy beginner/intermediate/expert/any.

ALTER TABLE public.pickup_games
  ADD COLUMN IF NOT EXISTS players_needed integer NOT NULL DEFAULT 1;

ALTER TABLE public.pickup_games
  ADD COLUMN IF NOT EXISTS play_environment text NOT NULL DEFAULT 'either';

ALTER TABLE public.pickup_games
  ADD COLUMN IF NOT EXISTS participant_preference text NOT NULL DEFAULT 'everyone';

ALTER TABLE public.pickup_games
  ADD COLUMN IF NOT EXISTS is_free boolean NOT NULL DEFAULT true;

ALTER TABLE public.pickup_games
  ADD COLUMN IF NOT EXISTS entry_fee_amount numeric(12, 2);

ALTER TABLE public.pickup_games
  ADD COLUMN IF NOT EXISTS max_players integer;

UPDATE public.pickup_games
SET entry_fee_amount = NULL
WHERE is_free = true;

-- Must drop legacy CHECK before writing new skill_level tokens.
ALTER TABLE public.pickup_games DROP CONSTRAINT IF EXISTS pickup_games_skill_level_check;

UPDATE public.pickup_games
SET skill_level = CASE lower(trim(both from coalesce(skill_level, '')))
    WHEN 'beginner' THEN 'beginner_friendly'
    WHEN 'intermediate' THEN 'intermediate'
    WHEN 'expert' THEN 'competitive'
    WHEN 'any' THEN 'casual'
    WHEN 'casual' THEN 'casual'
    WHEN 'beginner_friendly' THEN 'beginner_friendly'
    WHEN 'competitive' THEN 'competitive'
    ELSE 'casual'
  END;

UPDATE public.pickup_games
SET skill_level = 'casual'
WHERE skill_level IS NULL OR trim(both from skill_level) = '';

ALTER TABLE public.pickup_games
  ALTER COLUMN skill_level SET DEFAULT 'casual';

ALTER TABLE public.pickup_games
  ALTER COLUMN skill_level SET NOT NULL;

-- Idempotent constraint refresh (safe re-run).
ALTER TABLE public.pickup_games DROP CONSTRAINT IF EXISTS pickup_games_skill_level_check;
ALTER TABLE public.pickup_games DROP CONSTRAINT IF EXISTS pickup_games_play_environment_check;
ALTER TABLE public.pickup_games DROP CONSTRAINT IF EXISTS pickup_games_participant_preference_check;
ALTER TABLE public.pickup_games DROP CONSTRAINT IF EXISTS pickup_games_players_needed_check;
ALTER TABLE public.pickup_games DROP CONSTRAINT IF EXISTS pickup_games_max_players_check;
ALTER TABLE public.pickup_games DROP CONSTRAINT IF EXISTS pickup_games_entry_fee_consistency_check;
ALTER TABLE public.pickup_games DROP CONSTRAINT IF EXISTS pickup_games_capacity_vs_needed_check;

UPDATE public.pickup_games
SET max_players = players_needed
WHERE max_players IS NOT NULL AND max_players < players_needed;

ALTER TABLE public.pickup_games
  ADD CONSTRAINT pickup_games_skill_level_check
  CHECK (skill_level IN ('casual', 'beginner_friendly', 'intermediate', 'competitive'));

ALTER TABLE public.pickup_games
  ADD CONSTRAINT pickup_games_play_environment_check
  CHECK (play_environment IN ('indoor', 'outdoor', 'either'));

ALTER TABLE public.pickup_games
  ADD CONSTRAINT pickup_games_participant_preference_check
  CHECK (participant_preference IN (
    'everyone', 'women_only', 'men_only', 'adults_only', 'teens_welcome'
  ));

ALTER TABLE public.pickup_games
  ADD CONSTRAINT pickup_games_players_needed_check
  CHECK (players_needed >= 1 AND players_needed <= 20);

ALTER TABLE public.pickup_games
  ADD CONSTRAINT pickup_games_max_players_check
  CHECK (max_players IS NULL OR (max_players >= 1 AND max_players <= 100));

ALTER TABLE public.pickup_games
  ADD CONSTRAINT pickup_games_entry_fee_consistency_check
  CHECK (
    (is_free = true AND entry_fee_amount IS NULL)
    OR (
      is_free = false
      AND entry_fee_amount IS NOT NULL
      AND entry_fee_amount > 0
      AND entry_fee_amount <= 999999.99
    )
  );

ALTER TABLE public.pickup_games
  ADD CONSTRAINT pickup_games_capacity_vs_needed_check
  CHECK (
    max_players IS NULL
    OR players_needed <= max_players
  );

COMMENT ON COLUMN public.pickup_games.play_environment IS 'indoor | outdoor | either';
COMMENT ON COLUMN public.pickup_games.participant_preference IS 'Audience / age preference for organizers.';
COMMENT ON COLUMN public.pickup_games.is_free IS 'When true, entry_fee_amount must be null.';
COMMENT ON COLUMN public.pickup_games.entry_fee_amount IS 'USD-style numeric entry fee when is_free is false.';
COMMENT ON COLUMN public.pickup_games.max_players IS 'Total game capacity cap (optional). Must be >= players_needed when set.';
COMMENT ON COLUMN public.pickup_games.players_needed IS 'Open spots the creator wants to fill (1–20).';
