-- Allow halftime delivery rows in the Pro Game push dedupe ledger.

ALTER TABLE public.pro_game_score_notification_deliveries
  DROP CONSTRAINT IF EXISTS pro_game_score_notification_deliveries_notification_type_check;

ALTER TABLE public.pro_game_score_notification_deliveries
  ADD CONSTRAINT pro_game_score_notification_deliveries_notification_type_check
  CHECK (notification_type IN ('kickoff', 'score', 'final', 'halftime'));
