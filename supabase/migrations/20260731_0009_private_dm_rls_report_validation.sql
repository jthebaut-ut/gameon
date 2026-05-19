-- Private chat security step 2: tighten DM RLS and validate private report inserts
-- against server-side conversation/message rows. This migration intentionally does
-- not add admin access to direct_messages or expose full private DM history.

CREATE OR REPLACE FUNCTION public.is_direct_conversation_participant(
  p_conversation_id uuid,
  p_user_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.direct_conversations dc
    WHERE dc.id = p_conversation_id
      AND p_user_id IS NOT NULL
      AND (dc.user_a_id = p_user_id OR dc.user_b_id = p_user_id)
  );
$$;

COMMENT ON FUNCTION public.is_direct_conversation_participant(uuid, uuid) IS
  'Server-side helper for DM RLS/report validation: true when the supplied user participates in the direct conversation.';

REVOKE ALL ON FUNCTION public.is_direct_conversation_participant(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.is_direct_conversation_participant(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_direct_conversation_participant(uuid, uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.is_direct_conversation_other_participant(
  p_conversation_id uuid,
  p_reporter_user_id uuid,
  p_reported_user_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.direct_conversations dc
    WHERE dc.id = p_conversation_id
      AND p_reporter_user_id IS NOT NULL
      AND p_reported_user_id IS NOT NULL
      AND (
        (dc.user_a_id = p_reporter_user_id AND dc.user_b_id = p_reported_user_id)
        OR
        (dc.user_b_id = p_reporter_user_id AND dc.user_a_id = p_reported_user_id)
      )
  );
$$;

COMMENT ON FUNCTION public.is_direct_conversation_other_participant(uuid, uuid, uuid) IS
  'Server-side helper for private conversation reports: true when reported_user_id is the reporter''s peer in the conversation.';

REVOKE ALL ON FUNCTION public.is_direct_conversation_other_participant(uuid, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.is_direct_conversation_other_participant(uuid, uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_direct_conversation_other_participant(uuid, uuid, uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.can_report_direct_message(
  p_message_id uuid,
  p_reporter_user_id uuid,
  p_reported_user_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.direct_messages dm
    INNER JOIN public.direct_conversations dc
      ON dc.id = dm.conversation_id
    WHERE dm.id = p_message_id
      AND p_reporter_user_id IS NOT NULL
      AND p_reported_user_id IS NOT NULL
      AND dm.sender_id = p_reported_user_id
      AND (dc.user_a_id = p_reporter_user_id OR dc.user_b_id = p_reporter_user_id)
  );
$$;

COMMENT ON FUNCTION public.can_report_direct_message(uuid, uuid, uuid) IS
  'Server-side helper for message_reports: validates reporter participation and reported_user_id against the message sender.';

REVOKE ALL ON FUNCTION public.can_report_direct_message(uuid, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.can_report_direct_message(uuid, uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.can_report_direct_message(uuid, uuid, uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- direct_conversations: participants may discover only their own conversation ids.
-- Creation remains behind existing RPCs (start_direct_conversation); no direct
-- authenticated INSERT/UPDATE/DELETE policy is created here.
-- ---------------------------------------------------------------------------

ALTER TABLE public.direct_conversations ENABLE ROW LEVEL SECURITY;

DO $$
DECLARE
  policy_record record;
BEGIN
  FOR policy_record IN
    SELECT policyname
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'direct_conversations'
      AND cmd IN ('SELECT', 'INSERT', 'UPDATE', 'DELETE', 'ALL')
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.direct_conversations', policy_record.policyname);
  END LOOP;
END $$;

CREATE POLICY "direct_conversations_select_participants"
ON public.direct_conversations
FOR SELECT
TO authenticated
USING (user_a_id = auth.uid() OR user_b_id = auth.uid());

-- ---------------------------------------------------------------------------
-- conversation_read_state: each participant can manage only their own cursor.
-- ---------------------------------------------------------------------------

ALTER TABLE public.conversation_read_state ENABLE ROW LEVEL SECURITY;

DO $$
DECLARE
  policy_record record;
BEGIN
  FOR policy_record IN
    SELECT policyname
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'conversation_read_state'
      AND cmd IN ('SELECT', 'INSERT', 'UPDATE', 'DELETE', 'ALL')
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.conversation_read_state', policy_record.policyname);
  END LOOP;
END $$;

CREATE POLICY "conversation_read_state_select_own_participant"
ON public.conversation_read_state
FOR SELECT
TO authenticated
USING (
  user_id = auth.uid()
  AND public.is_direct_conversation_participant(conversation_id, user_id)
);

CREATE POLICY "conversation_read_state_insert_own_participant"
ON public.conversation_read_state
FOR INSERT
TO authenticated
WITH CHECK (
  user_id = auth.uid()
  AND public.is_direct_conversation_participant(conversation_id, user_id)
);

CREATE POLICY "conversation_read_state_update_own_participant"
ON public.conversation_read_state
FOR UPDATE
TO authenticated
USING (
  user_id = auth.uid()
  AND public.is_direct_conversation_participant(conversation_id, user_id)
)
WITH CHECK (
  user_id = auth.uid()
  AND public.is_direct_conversation_participant(conversation_id, user_id)
);

-- ---------------------------------------------------------------------------
-- direct_messages: participants can read/send; authenticated clients cannot
-- UPDATE/DELETE message rows. Moderation changes must use trusted server paths.
-- ---------------------------------------------------------------------------

ALTER TABLE public.direct_messages ENABLE ROW LEVEL SECURITY;

DO $$
DECLARE
  policy_record record;
BEGIN
  FOR policy_record IN
    SELECT policyname
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'direct_messages'
      AND cmd IN ('SELECT', 'INSERT', 'UPDATE', 'DELETE', 'ALL')
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.direct_messages', policy_record.policyname);
  END LOOP;
END $$;

CREATE POLICY "direct_messages_select_thread_participants"
ON public.direct_messages
FOR SELECT
TO authenticated
USING (
  public.is_direct_conversation_participant(conversation_id, auth.uid())
);

CREATE POLICY "direct_messages_insert_as_participant_sender"
ON public.direct_messages
FOR INSERT
TO authenticated
WITH CHECK (
  sender_id = auth.uid()
  AND public.is_direct_conversation_participant(conversation_id, sender_id)
);

-- ---------------------------------------------------------------------------
-- message_reports: client-supplied snapshot text remains informational only.
-- Authorization and reported_user_id are validated from direct_messages and
-- direct_conversations on the server.
-- ---------------------------------------------------------------------------

ALTER TABLE public.message_reports ENABLE ROW LEVEL SECURITY;

DO $$
DECLARE
  policy_record record;
BEGIN
  FOR policy_record IN
    SELECT policyname
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'message_reports'
      AND cmd IN ('INSERT', 'UPDATE', 'DELETE', 'ALL')
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.message_reports', policy_record.policyname);
  END LOOP;
END $$;

DROP POLICY IF EXISTS "Users can read own message reports" ON public.message_reports;
DROP POLICY IF EXISTS "message_reports_select_own" ON public.message_reports;

CREATE POLICY "message_reports_insert_validated_dm_report"
ON public.message_reports
FOR INSERT
TO authenticated
WITH CHECK (
  reporter_user_id = auth.uid()
  AND public.can_report_direct_message(message_id, reporter_user_id, reported_user_id)
);

CREATE POLICY "message_reports_select_own"
ON public.message_reports
FOR SELECT
TO authenticated
USING (reporter_user_id = auth.uid());

-- ---------------------------------------------------------------------------
-- conversation_reports: preserve report-consent columns while validating that
-- the reporter is a participant and reported_user_id is the other participant.
-- If a seed message is supplied, it must belong to the conversation and have
-- been sent by reported_user_id. The message_snapshot JSON remains the bounded
-- consent artifact for admin review, not a source of authorization truth.
-- ---------------------------------------------------------------------------

ALTER TABLE public.conversation_reports ENABLE ROW LEVEL SECURITY;

DO $$
DECLARE
  policy_record record;
BEGIN
  FOR policy_record IN
    SELECT policyname
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'conversation_reports'
      AND cmd IN ('INSERT', 'UPDATE', 'DELETE', 'ALL')
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.conversation_reports', policy_record.policyname);
  END LOOP;
END $$;

DROP POLICY IF EXISTS "Users can read own conversation reports" ON public.conversation_reports;
DROP POLICY IF EXISTS "conversation_reports_select_own" ON public.conversation_reports;

CREATE POLICY "conversation_reports_insert_validated_dm_report"
ON public.conversation_reports
FOR INSERT
TO authenticated
WITH CHECK (
  reporter_user_id = auth.uid()
  AND public.is_direct_conversation_other_participant(
    conversation_id,
    reporter_user_id,
    reported_user_id
  )
  AND (
    reported_message_id IS NULL
    OR EXISTS (
      SELECT 1
      FROM public.direct_messages dm
      WHERE dm.id = reported_message_id
        AND dm.conversation_id = conversation_reports.conversation_id
        AND dm.sender_id = reported_user_id
    )
  )
);

CREATE POLICY "conversation_reports_select_own"
ON public.conversation_reports
FOR SELECT
TO authenticated
USING (reporter_user_id = auth.uid());
