-- Allow card delivery rows in the Pro Game push dedupe ledger.

ALTER TABLE public.pro_game_score_notification_deliveries
  DROP CONSTRAINT IF EXISTS pro_game_score_notification_deliveries_notification_type_check;

ALTER TABLE public.pro_game_score_notification_deliveries
  ADD CONSTRAINT pro_game_score_notification_deliveries_notification_type_check
  CHECK (notification_type IN (
    'kickoff',
    'score',
    'final',
    'halftime',
    'yellow_card',
    'red_card',
    'second_yellow_card'
  ));

COMMENT ON TABLE public.pro_game_score_notification_deliveries IS
  'Dedupe ledger for closed-app Pro Game kickoff, score, final, halftime, and card push notifications. Card rows store stable_event_key in scoreline.';
