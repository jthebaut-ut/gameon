-- Backfill `responded_at` for historical approve/reject rows created before the audit trigger
-- reliably set it (UI shows decision timestamps in Manage Requests).
-- New writes continue to be stamped by `pickup_game_requests_touch_audit`.

UPDATE public.pickup_game_requests
SET responded_at = updated_at
WHERE responded_at IS NULL
  AND status IN ('approved', 'rejected');
