DO $$
BEGIN
  IF to_regclass('public.pickup_places') IS NULL THEN
    RETURN;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'pickup_places'
      AND column_name = 'sport'
  ) THEN
    EXECUTE 'CREATE INDEX IF NOT EXISTS idx_pickup_places_sport_lower ON public.pickup_places (lower(sport))';
    EXECUTE 'CREATE INDEX IF NOT EXISTS idx_pickup_places_sport_latitude_longitude ON public.pickup_places (lower(sport), latitude, longitude)';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'pickup_places'
      AND column_name = 'sport_tags'
  ) THEN
    EXECUTE 'CREATE INDEX IF NOT EXISTS idx_pickup_places_sport_tags_gin ON public.pickup_places USING gin (sport_tags)';
    EXECUTE 'CREATE INDEX IF NOT EXISTS idx_pickup_places_sport_tags_text_latitude_longitude ON public.pickup_places (lower(array_to_string(sport_tags, ''|'')), latitude, longitude)';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'pickup_places'
      AND column_name = 'state'
  ) THEN
    EXECUTE 'CREATE INDEX IF NOT EXISTS idx_pickup_places_state_lower ON public.pickup_places (lower(state))';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'pickup_places'
      AND column_name = 'latitude'
  ) AND EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'pickup_places'
      AND column_name = 'longitude'
  ) THEN
    EXECUTE 'CREATE INDEX IF NOT EXISTS idx_pickup_places_latitude_longitude ON public.pickup_places (latitude, longitude)';
  END IF;
END $$;
