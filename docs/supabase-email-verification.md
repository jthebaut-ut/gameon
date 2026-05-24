# Supabase Email Verification

Required Supabase Auth setting for FanGeo account creation:

1. Go to `Authentication` -> `Sign In / Providers` -> `Email`.
2. Set `Confirm email` to `ON`.
3. Keep SMTP configured to the existing Resend sender, `support@fangeosports.com`.
4. Allowlist these redirect URLs:
   - `fangeo://email-confirmed`
   - `fangeo://auth-callback`

When email confirmation is enabled, new fan and business-owner signups should not receive full app access until the confirmation link is opened and the user signs in again.
