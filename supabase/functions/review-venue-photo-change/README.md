## `review-venue-photo-change` (email moderation endpoint)

This Edge Function is opened from **clickable email links** (Approve / Reject) and therefore must be deployed with JWT verification disabled.

### Deploy (required)

```bash
supabase functions deploy review-venue-photo-change --no-verify-jwt
```

### Security model

- No JWT auth
- HMAC-signed expiring query params:
  - `action` (`approve` / `reject`)
  - `venue_id`
  - `exp`
  - `sig` = HMAC-SHA256(`action:venue_id:exp`, `MODERATION_HMAC_SECRET`)
- Uses service role key server-side only to update `venues`.

### Required secrets

- `MODERATION_HMAC_SECRET`
- `SERVICE_ROLE_KEY` (or `SUPABASE_SERVICE_ROLE_KEY`)
- `SUPABASE_URL` (or `PROJECT_URL`)

