## `review-venue-claim` (email moderation endpoint)

This Edge Function is designed to be opened from **clickable email links** (Approve / Reject).

Because the link is opened in a normal browser tab, it **cannot** include a Supabase user JWT `Authorization` header.
Supabase's default function-level JWT verification must be disabled, otherwise the platform returns:
`UNAUTHORIZED_NO_AUTH_HEADER` before the function code runs.

### Deploy (required)

```bash
supabase functions deploy review-venue-claim --no-verify-jwt
```

### Security model

- **No JWT auth**
- Authorization relies entirely on an **HMAC-signed expiring token** in query params:
  - `action` (`approve` / `reject`)
  - `claim_id`
  - `exp` (expiry unix timestamp)
  - `sig` (HMAC-SHA256 of `action:claim_id:exp` using `MODERATION_HMAC_SECRET`)
- The function uses the Supabase **service role key server-side only** to persist the update.

### Required secrets

- `MODERATION_HMAC_SECRET`
- `SERVICE_ROLE_KEY` (or `SUPABASE_SERVICE_ROLE_KEY`)
- `SUPABASE_URL` (or `PROJECT_URL`)

