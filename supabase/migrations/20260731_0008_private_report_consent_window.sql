-- Private conversation report consent: store only the selected admin review window snapshot.
-- Admin review tooling must read conversation_reports.message_snapshot for private DM reports,
-- not unrestricted direct_messages history.

ALTER TABLE public.conversation_reports
  ADD COLUMN IF NOT EXISTS review_window_start timestamptz,
  ADD COLUMN IF NOT EXISTS review_window_end timestamptz,
  ADD COLUMN IF NOT EXISTS admin_review_consent_granted boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS admin_review_consent_granted_at timestamptz,
  ADD COLUMN IF NOT EXISTS reported_message_id uuid REFERENCES public.direct_messages (id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS message_snapshot jsonb NOT NULL DEFAULT '[]'::jsonb;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'conversation_reports_review_window_order_check'
  ) THEN
    ALTER TABLE public.conversation_reports
      ADD CONSTRAINT conversation_reports_review_window_order_check
      CHECK (
        review_window_start IS NULL
        OR review_window_end IS NULL
        OR (
          review_window_start <= review_window_end
          AND review_window_end <= review_window_start + interval '7 days'
        )
      );
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'conversation_reports_consent_fields_check'
  ) THEN
    ALTER TABLE public.conversation_reports
      ADD CONSTRAINT conversation_reports_consent_fields_check
      CHECK (
        admin_review_consent_granted = false
        OR (
          review_window_start IS NOT NULL
          AND review_window_end IS NOT NULL
          AND admin_review_consent_granted_at IS NOT NULL
          AND jsonb_typeof(message_snapshot) = 'array'
        )
      );
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_conversation_reports_review_window
  ON public.conversation_reports (review_window_start, review_window_end);

CREATE INDEX IF NOT EXISTS idx_conversation_reports_reported_message_id
  ON public.conversation_reports (reported_message_id)
  WHERE reported_message_id IS NOT NULL;

CREATE OR REPLACE FUNCTION public.get_private_conversation_report_snapshot(
  p_report_id uuid,
  p_admin_email text
)
RETURNS TABLE (
  report_id uuid,
  reporter_user_id uuid,
  reported_user_id uuid,
  conversation_id uuid,
  category text,
  details text,
  review_window_start timestamptz,
  review_window_end timestamptz,
  admin_review_consent_granted boolean,
  admin_review_consent_granted_at timestamptz,
  reported_message_id uuid,
  message_snapshot jsonb,
  created_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_email text := NULLIF(BTRIM(COALESCE(p_admin_email, '')), '');
BEGIN
  IF auth.role() <> 'service_role' THEN
    RAISE EXCEPTION 'service_role required'
      USING ERRCODE = '42501';
  END IF;

  RAISE LOG '[PrivateReportAudit] admin viewed report_id=%', p_report_id;

  INSERT INTO public.admin_audit_logs (
    admin_email,
    action,
    target_type,
    target_id,
    after_data,
    reason
  )
  VALUES (
    COALESCE(v_admin_email, 'unknown'),
    'private_conversation_report_viewed',
    'conversation_report',
    p_report_id::text,
    jsonb_build_object('report_id', p_report_id),
    'Private conversation report snapshot opened'
  );

  RETURN QUERY
  SELECT
    cr.id AS report_id,
    cr.reporter_user_id,
    cr.reported_user_id,
    cr.conversation_id,
    cr.category,
    cr.details,
    cr.review_window_start,
    cr.review_window_end,
    cr.admin_review_consent_granted,
    cr.admin_review_consent_granted_at,
    cr.reported_message_id,
    cr.message_snapshot,
    cr.created_at
  FROM public.conversation_reports cr
  WHERE cr.id = p_report_id
    AND cr.admin_review_consent_granted = true;
END;
$$;

REVOKE ALL ON FUNCTION public.get_private_conversation_report_snapshot(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_private_conversation_report_snapshot(uuid, text) TO service_role;
