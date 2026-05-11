-- In-app support requests (audit trail for future admin tooling; email is sent via Edge Function).

CREATE TABLE IF NOT EXISTS public.support_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  category text NOT NULL,
  subject text NOT NULL,
  message text NOT NULL,
  app_version text,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT support_requests_category_check CHECK (
    category IN (
      'technical_issue',
      'account_help',
      'report_problem',
      'venue_support',
      'billing_other'
    )
  ),
  CONSTRAINT support_requests_subject_len CHECK (char_length(subject) <= 200),
  CONSTRAINT support_requests_message_len CHECK (char_length(message) <= 1000)
);

CREATE INDEX IF NOT EXISTS idx_support_requests_user_created
  ON public.support_requests (user_id, created_at DESC);

ALTER TABLE public.support_requests ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users insert own support_requests"
  ON public.support_requests FOR INSERT
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users read own support_requests"
  ON public.support_requests FOR SELECT
  USING (auth.uid() = user_id);

-- TODO: Admin/service-role policy for dashboard reads across all rows.
