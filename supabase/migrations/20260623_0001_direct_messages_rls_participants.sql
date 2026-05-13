-- RLS for direct_messages so Realtime (and PostgREST) only expose rows for conversations
-- the authenticated user participates in. Realtime uses the same role as the client session.
--
-- Requires public.direct_conversations(id, user_a_id, user_b_id) as used by the app RPCs.

ALTER TABLE public.direct_messages ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "direct_messages_select_thread_participants" ON public.direct_messages;
CREATE POLICY "direct_messages_select_thread_participants"
ON public.direct_messages
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.direct_conversations dc
    WHERE dc.id = direct_messages.conversation_id
      AND (dc.user_a_id = auth.uid() OR dc.user_b_id = auth.uid())
  )
);

DROP POLICY IF EXISTS "direct_messages_insert_as_participant_sender" ON public.direct_messages;
CREATE POLICY "direct_messages_insert_as_participant_sender"
ON public.direct_messages
FOR INSERT
TO authenticated
WITH CHECK (
  sender_id = auth.uid()
  AND EXISTS (
    SELECT 1
    FROM public.direct_conversations dc
    WHERE dc.id = conversation_id
      AND (dc.user_a_id = auth.uid() OR dc.user_b_id = auth.uid())
  )
);

-- Moderation / soft-delete may UPDATE rows; participants must remain able to see consistent state.
DROP POLICY IF EXISTS "direct_messages_update_participant_row" ON public.direct_messages;
CREATE POLICY "direct_messages_update_participant_row"
ON public.direct_messages
FOR UPDATE
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.direct_conversations dc
    WHERE dc.id = direct_messages.conversation_id
      AND (dc.user_a_id = auth.uid() OR dc.user_b_id = auth.uid())
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM public.direct_conversations dc
    WHERE dc.id = conversation_id
      AND (dc.user_a_id = auth.uid() OR dc.user_b_id = auth.uid())
  )
);
