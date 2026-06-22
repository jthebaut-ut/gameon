-- Expand support request issue types for unified Contact Support flow.

ALTER TABLE public.support_requests
  DROP CONSTRAINT IF EXISTS support_requests_category_check;

ALTER TABLE public.support_requests
  ADD CONSTRAINT support_requests_category_check CHECK (
    category IN (
      'bug_report',
      'question',
      'feature_request',
      'account_issue',
      'business_support',
      'other',
      -- legacy values (existing rows)
      'technical_issue',
      'account_help',
      'report_problem',
      'venue_support',
      'billing_other'
    )
  );
