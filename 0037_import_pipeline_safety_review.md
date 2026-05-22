# 0037 Import Pipeline Safety Review

Reviewed file:

`supabase/migrations/20260731_0037_national_community_venue_import_pipeline.sql`

Report only. No SQL was modified as part of this review.

## Findings

### Medium: promotion is partial-batch, not all-or-nothing by validation result

`promote_community_venue_import_batch(...)` calls `validate_community_venue_import_batch(...)`, then promotes every row whose status is `ready`. If a batch contains both safe rows and invalid/duplicate rows, the safe rows can still be inserted into `public.venues`.

This does not insert invalid rows, and a runtime SQL error still rolls back the function call. However, if the intended live-execution policy is "do not promote any part of a batch unless all rows validate cleanly", the current function does not enforce that.

Recommendation before live national execution:

- Add a guard in promotion that raises if the batch has any `invalid` or `duplicate` rows after validation.
- Or explicitly document partial-batch promotion as the intended operator behavior.

### Medium: `skipped` rows are reset to `pending` during validation

`validate_community_venue_import_batch(...)` resets rows in `invalid`, `duplicate`, `ready`, and `skipped` status back to `pending`. That means an operator-marked `skipped` row can be reconsidered and promoted later by a normal promotion call.

Recommendation before live execution:

- Do not reset `skipped` rows automatically.
- Treat `skipped` as terminal/manual unless an operator explicitly changes it.

### Low: not every helper RPC has explicit public EXECUTE revoked

The migration revokes public execution for:

- `validate_community_venue_import_batch(text)`
- `promote_community_venue_import_batch(text, text)`

It grants staging table access and import RPC execution to `service_role`.

However, `community_venue_import_duplicate_candidates(text)` is granted to `service_role` but not explicitly revoked from `PUBLIC`. PostgreSQL grants EXECUTE on new functions to `PUBLIC` by default unless defaults have been changed.

Because the duplicate function is not `SECURITY DEFINER` and staging table access is revoked/RLS-restricted, anon/authenticated callers should not be able to read staging through it. Still, for clean least-privilege posture, explicitly revoke it.

Recommendation:

- `REVOKE ALL ON FUNCTION public.community_venue_import_duplicate_candidates(text) FROM PUBLIC;`
- Optionally revoke public EXECUTE on non-user-facing validation helper functions as well.

## Requested Safety Checks

### 1. Does it modify existing `public.venues` rows?

No direct modification of existing `public.venues` rows was found.

The migration creates functions, a staging table, indexes, comments, RLS, grants, and revokes. The only production `public.venues` DML is an `INSERT INTO public.venues` inside `promote_community_venue_import_batch(...)`.

Promotion inserts new rows only. It does not `UPDATE` or `DELETE` existing venues.

### 2. Does it modify `businesses`, `venue_claims`, or auth users?

No.

No DML or DDL targets were found for:

- `public.businesses`
- `public.venue_claims`
- `auth.users`

The duplicate detection reads `public.venues` only.

### 3. Are staging/RPC permissions service-role only?

Mostly yes, with one hardening note.

The staging table has:

- RLS enabled
- a deny-all select policy for `anon` and `authenticated`
- `REVOKE ALL ... FROM PUBLIC`
- `GRANT SELECT, INSERT, UPDATE, DELETE ... TO service_role`

The mutating RPCs have:

- `REVOKE ALL ... FROM PUBLIC`
- `GRANT EXECUTE ... TO service_role`

Hardening gap:

- `community_venue_import_duplicate_candidates(text)` should also explicitly revoke public EXECUTE before granting service-role execution.

### 4. Can public/authenticated users insert into staging?

No, based on the migration as written.

`PUBLIC` privileges are revoked from the staging table, and only `service_role` receives table privileges. There is also no insert policy for `anon` or `authenticated`.

Even if table privileges were accidentally granted later, RLS would still block normal client inserts unless an insert policy were added.

### 5. Does promotion enforce community-only, no-owner, no-business, no-photo, no-feature output?

Yes for the inserted production row.

`promote_community_venue_import_batch(...)` inserts these constants into `public.venues`:

- `owner_email = NULL`
- `business_id = NULL`
- `owner_user_id = NULL`
- `admin_status = 'active'`
- `origin_type = 'community'`
- `features = ''`
- `screen_count = NULL`
- amenity booleans = `NULL`
- `cover_photo_url = ''`
- `menu_photo_url = ''`
- photo thumbnails = `NULL`
- `supporter_country = NULL`

The validation function also marks staging rows invalid when they contain owner/business authority, seeded photos, feature payloads, screen count, amenity booleans, supporter country, or disallowed descriptions.

### 6. Does duplicate detection prevent existing Utah duplicates?

Likely yes for active existing venue rows.

Duplicate detection checks against active `public.venues` using:

- `venue_identity_key`
- fallback computed `gameon_venue_identity_key(...)` when existing rows have no key
- normalized venue name + normalized address + normalized city + normalized state

It also checks same-batch duplicates by:

- `venue_identity_key`
- normalized name/address/city/state

This should catch existing active Utah seed duplicates if their name/address/city/state/ZIP data normalizes to the same identity or same normalized location.

Limits:

- It intentionally ignores archived/non-active venues.
- It does not check `venue_claims`, which is acceptable for seed venue insertion if `public.venues` remains the production source of map venue identity.
- It does not do fuzzy/geospatial matching, so near-duplicates with materially different spelling or address formatting may still need manual review.

### 7. Are helper functions immutable/stable where appropriate?

Yes.

Pure normalization wrappers are `IMMUTABLE` and `PARALLEL SAFE`:

- `community_venue_import_normalize_venue_name(text)`
- `community_venue_import_normalize_address(text)`
- `community_venue_import_identity_key(...)`

They call existing immutable venue identity helpers.

Table-reading duplicate detection is `STABLE`, which is appropriate.

The row validation helper is `STABLE`; it could be `IMMUTABLE` because it only inspects the supplied row, but `STABLE` is safe and conservative.

The batch validation and promotion functions are `plpgsql SECURITY DEFINER`, which is appropriate for service-role controlled backend operations.

### 8. Is promotion transactional?

Yes.

PostgreSQL executes the function inside the caller's transaction. In normal RPC/autocommit usage, the full function call is one transaction. If an error occurs during validation, insertion, unique-index enforcement, trigger execution, or staging update, the function call rolls back.

Important nuance:

- Transactional does not mean all rows in a batch must be valid.
- The current logic can promote ready rows while leaving invalid/duplicate rows unpromoted.

### 9. Can failed validation partially insert venues?

Yes, depending on what "failed validation" means.

If validation marks some rows as `invalid` or `duplicate` but other rows become `ready`, promotion inserts the ready rows. That is partial-batch promotion.

If the actual `INSERT INTO public.venues` fails, the function call rolls back and should not leave partial production inserts from that failed statement.

Recommendation:

- Before live national execution, decide whether partial-batch promotion is acceptable.
- If not, add a post-validation guard that raises when any row in the batch is `invalid` or `duplicate`.

### 10. Any dangerous `DELETE`/`UPDATE` statements?

No dangerous production `DELETE`/`UPDATE` statements were found.

There are no `DELETE` statements.

All `UPDATE` statements target only `public.community_venue_import_staging` to manage import status and promotion metadata.

The only production-table DML is `INSERT INTO public.venues` inside the promotion function.

## Overall Assessment

The migration is broadly safe from a destructive-data perspective: it does not delete data, does not update existing venues, and does not touch businesses, venue claims, or auth users.

Before live execution, I recommend hardening two things:

- Make promotion all-or-nothing per batch, unless partial promotion is explicitly desired.
- Preserve `skipped` as a terminal/manual status instead of resetting it during validation.

I also recommend explicitly revoking public EXECUTE on the duplicate-candidate helper for a cleaner service-role-only security posture.
