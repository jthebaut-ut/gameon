-- Document open_to_items array on fan_identity_preferences (client migrates legacy booleans).

COMMENT ON COLUMN public.user_profiles.fan_identity_preferences IS
  'Public fan identity prefs: open_to_items (string[]), personality_tags (string[]). Legacy open_to_* booleans still read by clients.';
