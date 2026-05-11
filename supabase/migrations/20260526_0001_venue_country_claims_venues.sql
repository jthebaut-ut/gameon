-- Business location forms: persist country on claims and copy to venues on approval.

ALTER TABLE public.venue_claims
  ADD COLUMN IF NOT EXISTS venue_country text NOT NULL DEFAULT 'USA';

COMMENT ON COLUMN public.venue_claims.venue_country IS
  'Country code from owner signup / add-location (e.g. USA). Default USA for legacy rows.';

ALTER TABLE public.venues
  ADD COLUMN IF NOT EXISTS country text;

COMMENT ON COLUMN public.venues.country IS
  'Country from approved claim; optional for legacy venue rows.';
