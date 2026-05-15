-- Split venue game social attendance for counts (Following tab, analytics).
-- One row per (user_email, venue_event_id); status is either going or interested.

ALTER TABLE public.venue_event_interests
  ADD COLUMN IF NOT EXISTS interest_status text;

UPDATE public.venue_event_interests
SET interest_status = 'going'
WHERE interest_status IS NULL;

ALTER TABLE public.venue_event_interests
  ALTER COLUMN interest_status SET DEFAULT 'going';

ALTER TABLE public.venue_event_interests
  ALTER COLUMN interest_status SET NOT NULL;

ALTER TABLE public.venue_event_interests
  DROP CONSTRAINT IF EXISTS venue_event_interests_interest_status_check;

ALTER TABLE public.venue_event_interests
  ADD CONSTRAINT venue_event_interests_interest_status_check
  CHECK (interest_status IN ('going', 'interested'));

COMMENT ON COLUMN public.venue_event_interests.interest_status IS
  'Fan attendance: going vs interested (unique per user per venue event).';
