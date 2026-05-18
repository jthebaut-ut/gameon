CREATE UNIQUE INDEX IF NOT EXISTS uq_favorite_venues_user_email_venue_id
  ON public.favorite_venues (user_email, venue_id);

CREATE INDEX IF NOT EXISTS idx_favorite_venues_user_email
  ON public.favorite_venues (user_email);

CREATE INDEX IF NOT EXISTS idx_favorite_venues_venue_id
  ON public.favorite_venues (venue_id);

CREATE INDEX IF NOT EXISTS idx_favorite_venues_user_email_id_desc
  ON public.favorite_venues (user_email, id DESC);

CREATE UNIQUE INDEX IF NOT EXISTS uq_venue_event_vibes_event_user_vibe
  ON public.venue_event_vibes (venue_event_id, user_email, vibe_type);

CREATE UNIQUE INDEX IF NOT EXISTS uq_venue_event_interests_user_email_event
  ON public.venue_event_interests (user_email, venue_event_id);

CREATE INDEX IF NOT EXISTS idx_venue_event_interests_user_email
  ON public.venue_event_interests (user_email);

CREATE UNIQUE INDEX IF NOT EXISTS uq_conversation_read_state_conversation_user
  ON public.conversation_read_state (conversation_id, user_id);

CREATE INDEX IF NOT EXISTS idx_conversation_read_state_user_id
  ON public.conversation_read_state (user_id);

CREATE INDEX IF NOT EXISTS idx_conversation_read_state_conversation_id
  ON public.conversation_read_state (conversation_id);
