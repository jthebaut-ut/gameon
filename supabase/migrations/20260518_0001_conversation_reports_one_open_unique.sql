-- At most one open conversation report per reporter per conversation (prevents duplicate spam).
-- Deduplicate any existing duplicate open rows before creating the unique index.

DELETE FROM public.conversation_reports a
    USING public.conversation_reports b
WHERE a.id > b.id
  AND a.reporter_user_id = b.reporter_user_id
  AND a.conversation_id = b.conversation_id
  AND a.status = 'open'
  AND b.status = 'open';

CREATE UNIQUE INDEX IF NOT EXISTS conversation_reports_one_open_per_reporter_conversation
  ON public.conversation_reports (reporter_user_id, conversation_id)
  WHERE (status = 'open');
