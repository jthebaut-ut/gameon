-- Keyset pagination indexes: (parent id, created_at DESC, id DESC) for DM threads and fan-update comments.
-- Complements idx_direct_messages_conversation_created / idx_venue_event_comments_venue_event_created (ascending time only).

CREATE INDEX IF NOT EXISTS idx_direct_messages_conv_created_id_desc
  ON public.direct_messages (conversation_id, created_at DESC, id DESC);

CREATE INDEX IF NOT EXISTS idx_venue_event_comments_event_created_id_desc
  ON public.venue_event_comments (venue_event_id, created_at DESC, id DESC);
