# Community Seed Ownership Audit

Report-only audit. No SQL was executed.

## Executive Summary

The current community-venue architecture is moving in the right direction: `public.venues.origin_type = 'community'` is now the intended signal for community provenance, and `supabase/seeds/utah_community_venues.sql` correctly seeds community rows with `business_id = NULL` and `owner_email = NULL`.

However, the repository still contains an older seed file, `supabase/seeds/utah_venues_seed.sql`, that inserts Utah venues with `owner_email = 'seed.utah.*@example.test'`. Even without helper `public.businesses` rows, those owner emails can make the app treat seeded community venues as business-linked/verified because several client paths still infer ownership or feature verification from `venues.owner_email`, `venues.business_id`, embedded `businesses.owner_email`, or approved `venue_claims`.

I did not find any repository seed that creates `public.businesses` rows for `seed.utah.*@example.test`, but production/staging may still contain manually created helper rows. Those should be audited directly in the database before removal.

## Seed References Found

Static repository references to seed helper emails are only in `supabase/seeds/utah_venues_seed.sql`:

- `seed.utah.beerhive@example.test`
- `seed.utah.legends@example.test`
- `seed.utah.provo-row@example.test`
- `seed.utah.ogden-union@example.test`
- `seed.utah.stgeorge-red@example.test`
- `seed.utah.moab-rim@example.test`
- `seed.utah.logan-cache@example.test`
- `seed.utah.parkcity-alpine@example.test`
- `seed.utah.sandy-state@example.test`
- `seed.utah.draper-traverse@example.test`
- `seed.utah.southjordan-sojo@example.test`
- `seed.utah.westjordan-landing@example.test`
- `seed.utah.orem-parkway@example.test`
- `seed.utah.cedar-main@example.test`

`supabase/seeds/utah_community_venues.sql` does not use helper owner emails or helper business rows. It explicitly documents and inserts:

- `owner_email = NULL`
- `business_id = NULL`
- `admin_status = 'active'`
- unverified amenity columns as `NULL`

## Area Findings

### 1. `public.venues` references to seed ownership

The old seed file inserts legacy community venues with `owner_email = seed.utah.*@example.test`. It does not set `business_id`.

Risk:

- `BarVenue.hasBusinessVerifiedFeatures` treats a strict-valid owner email as business-verified.
- `DiscoverVenueLoadAssembler` merges `venues.owner_email` into `BarVenue.ownerEmail`.
- `VenueGameBusinessEmail` may expose the owner email as public contact if it passes validation.
- `VenueDetailView` and feature-card logic may avoid the unverified community state because the venue appears business-linked.

Safe target state:

- Community seed venues should have `origin_type = 'community'`, `business_id = NULL`, `owner_user_id = NULL`, `owner_email = NULL`.
- Community amenities should be unknown/unverified (`NULL`) unless verified by a real business claim.

### 2. `public.businesses` seed rows

No repo migration or seed file creates `public.businesses` rows with `seed.utah.*@example.test`.

Possible production/staging issue:

- Manual helper businesses may exist with `owner_email LIKE 'seed.utah.%@example.test'`.
- If a venue references one of those rows through `venues.business_id`, Discover will embed `businesses.owner_email` and the client can treat the row as business-linked.
- If `venue_claims.business_id` references helper business ids, admin/business ownership logic can treat those claims as authority.

Safe to remove:

- Yes, if all `venues.business_id`, `venue_claims.business_id`, `venue_events.owner_email`, and active ownership claims are first detached or terminalized.
- Do not hard-delete helper businesses before unlinking references because foreign keys are `ON DELETE SET NULL`, which is safe structurally but does not normalize provenance/status.

### 3. `venue_claims` linked to seed helpers

The app and SQL use approved `venue_claims` as ownership authority:

- `refreshApprovedVenueOwnershipState` reads approved claims by `venue_id`.
- `loadBusinessesLinkedFromApprovedClaims` loads businesses from approved claims by owner email.
- `loadVenuesLinkedFromApprovedClaims` loads managed venues from approved claims by owner email or business ids.
- Claim approval writes `approval_status = 'approved'`, `venue_id`, `business_id`, and owner email.

Risk:

- Any approved claim tied to a seed helper business or seed helper owner email can make a community venue look owned.
- Released/cancelled/business_deleted claims are generally safe history, but approved/pending seed claims are not safe.

Safe target state:

- Seed-helper claims should not remain `approved` or open/pending.
- Historical seed-helper claims can remain with terminal status (`released`, `cancelled`, or `business_deleted`) and no active authority fields.

### 4. Discover/map queries

Discover fetches public venue rows from `public.venues` with:

- `owner_email`
- `business_id`
- `origin_type`
- embedded `businesses(owner_email, admin_status)`

Discover does not explicitly depend on seed helper businesses, but it does depend on generic ownership fields that seed helpers can pollute.

Important behavior:

- A venue with `origin_type = 'community'` but a strict-valid `owner_email` can still look business-verified in client logic.
- A venue with `business_id` linked to an active helper business can expose `businesses.owner_email` and look business-linked.
- Calendar dot and venue-event fetching still use legacy `owner_email` as a fallback only for `venue_events.venue_id IS NULL`.

Recommendation:

- Do not use seed helper emails for community rows.
- Prefer `venue_id` linkage for venue events.
- Treat `origin_type = 'community' AND business_id IS NULL AND owner_email IS NULL` as the canonical unclaimed state.

### 5. Claim/release logic

Current claim/release architecture supports community venues:

- Claim approval updates an existing venue as `origin_type = 'community'`.
- New business-created venue inserts use `origin_type = 'business'`.
- Release/delete RPC uses `origin_type` to release community venues and hard-delete business venues.
- Release clears `business_id`, `owner_user_id`, `owner_email`, business details/photos, and sets `origin_type = 'community'`.

Remaining seed risk:

- Duplicate-protection and claim visibility still compare `business_id` and `owner_email`.
- Any seed helper ownership left in those fields remains semantically active until cleaned.

### 6. Admin dashboard / community tools

Admin claim approval and rejection paths operate on `venue_claims` and do not appear to contain seed-specific logic.

Admin approval depends on:

- `venue_claims.business_id`
- `venue_claims.owner_email`
- `venue_claims.venue_id`
- existing/new venue row behavior

There is no explicit admin surface found that knows `seed.utah.*@example.test` is a helper namespace. That means helper rows are not a first-class concept; they are just ordinary owner/business identity values to the app.

### 7. Venue import / seed scripts

There are two Utah seed scripts with different semantics:

- `supabase/seeds/utah_community_venues.sql`: current preferred community seed architecture. Safe pattern.
- `supabase/seeds/utah_venues_seed.sql`: legacy seed pattern using `owner_email = seed.utah.*@example.test`. Unsafe for community provenance.

Recommendation:

- Deprecate or remove `utah_venues_seed.sql` from operational seed flows.
- If retained for historical/local testing, add a clear warning that it creates legacy owner-email rows and should not run against shared staging/production.

### 8. Business dashboard ownership queries

Business dashboard and profile logic load ownership from:

- `public.businesses.owner_email`
- `public.businesses.owner_user_id`
- `public.venues.business_id`
- `public.venues.owner_email`
- `public.venues.owner_user_id`
- approved `public.venue_claims`

Specific risk:

- `legacyOwnerVenuesForEmailFallback` loads venues by `owner_email`.
- `managedVenuesForOwner()` falls back to legacy owner-email venues if `ownedBusinessVenues` is empty.
- Approved claims can load venues even when `venues.business_id` and `venues.owner_email` are absent.

Seed helper emails are only dangerous if someone can sign in as the helper address, or if helper businesses/claims are linked into real ownership queries. Still, they pollute public/community semantics and feature verification.

## Are Seed Business Rows Safe To Remove?

Based on repository state, there are no seed business rows to remove from code-defined seed data. If rows exist in the database, they are safe to remove only after cleanup verifies:

- No active `public.venues.business_id` points to the seed business.
- No active `public.venue_claims.business_id` points to the seed business.
- No active/open/approved `venue_claims.owner_email` uses `seed.utah.*@example.test`.
- No `venue_events` need legacy owner-email linkage to those seed emails.

For community seed venues, replacement should be:

- `venues.origin_type = 'community'`
- `venues.business_id = NULL`
- `venues.owner_user_id = NULL`
- `venues.owner_email = NULL`
- `venues.venue_identity_key` retained
- optional provenance metadata added separately

## Required Schema Replacement Fields

Current replacement already partly exists:

- `venues.origin_type`: `community` vs `business`
- `venues.venue_identity_key`: stable duplicate/provenance identity

Recommended additional metadata fields:

- `venues.community_source`: text, for source namespace such as `utah_seed`, `osm`, `manual_admin`, `partner_import`
- `venues.community_source_id`: text, optional external/source id
- `venues.community_seed_batch`: text, for migration/import batch id
- `venues.community_seeded_at`: timestamptz
- `venues.community_curated_by`: text or uuid, optional admin/importer marker
- `venues.community_provenance`: jsonb, optional richer provenance payload

Do not use `owner_email` or `business_id` to represent community provenance.

## Migration Plan

1. Add provenance columns to `public.venues`.

   Example plan only:

   ```sql
   ALTER TABLE public.venues
     ADD COLUMN IF NOT EXISTS community_source text,
     ADD COLUMN IF NOT EXISTS community_source_id text,
     ADD COLUMN IF NOT EXISTS community_seed_batch text,
     ADD COLUMN IF NOT EXISTS community_seeded_at timestamptz,
     ADD COLUMN IF NOT EXISTS community_curated_by text,
     ADD COLUMN IF NOT EXISTS community_provenance jsonb NOT NULL DEFAULT '{}'::jsonb;
   ```

2. Backfill old seed-email rows into community provenance.

   ```sql
   UPDATE public.venues
   SET
     origin_type = 'community',
     community_source = 'utah_legacy_seed',
     community_source_id = owner_email,
     community_seed_batch = 'utah_venues_seed_legacy',
     community_seeded_at = coalesce(created_at, now()),
     community_provenance = community_provenance || jsonb_build_object(
       'legacy_owner_email', owner_email,
       'migration_note', 'Converted seed helper owner_email to community provenance'
     )
   WHERE lower(trim(coalesce(owner_email, ''))) LIKE 'seed.utah.%@example.test';
   ```

3. Unlink community venues from seed helper ownership fields.

   ```sql
   UPDATE public.venues
   SET
     business_id = NULL,
     owner_user_id = NULL,
     owner_email = NULL
   WHERE origin_type = 'community'
     AND lower(trim(coalesce(community_source_id, ''))) LIKE 'seed.utah.%@example.test';
   ```

4. Normalize historical seed claims.

   ```sql
   UPDATE public.venue_claims
   SET
     approval_status = CASE
       WHEN lower(trim(coalesce(approval_status, ''))) = 'approved' THEN 'released'
       WHEN public.gameon_venue_claim_is_open_pending(approval_status) THEN 'cancelled'
       ELSE approval_status
     END,
     business_id = NULL,
     owner_email = NULL
   WHERE lower(trim(coalesce(owner_email, ''))) LIKE 'seed.utah.%@example.test'
      OR business_id IN (
        SELECT id
        FROM public.businesses
        WHERE lower(trim(coalesce(owner_email, ''))) LIKE 'seed.utah.%@example.test'
      );
   ```

5. Remove helper businesses after references are normalized.

   ```sql
   DELETE FROM public.businesses
   WHERE lower(trim(coalesce(owner_email, ''))) LIKE 'seed.utah.%@example.test'
     AND NOT EXISTS (
       SELECT 1 FROM public.venues v WHERE v.business_id = businesses.id
     )
     AND NOT EXISTS (
       SELECT 1 FROM public.venue_claims vc WHERE vc.business_id = businesses.id
     );
   ```

6. Add guardrails.

   Recommended check:

   ```sql
   SELECT
     count(*) AS bad_community_owned_rows
   FROM public.venues
   WHERE origin_type = 'community'
     AND (business_id IS NOT NULL OR owner_user_id IS NOT NULL OR trim(coalesce(owner_email, '')) <> '');
   ```

## SQL Cleanup Plan

Do not execute until reviewed against staging data.

Diagnostics:

```sql
SELECT id, venue_name, owner_email, business_id, owner_user_id, origin_type, admin_status
FROM public.venues
WHERE lower(trim(coalesce(owner_email, ''))) LIKE 'seed.utah.%@example.test'
   OR business_id IN (
     SELECT id FROM public.businesses
     WHERE lower(trim(coalesce(owner_email, ''))) LIKE 'seed.utah.%@example.test'
   )
ORDER BY venue_name;
```

```sql
SELECT id, display_name, owner_email, owner_user_id, admin_status
FROM public.businesses
WHERE lower(trim(coalesce(owner_email, ''))) LIKE 'seed.utah.%@example.test'
ORDER BY owner_email;
```

```sql
SELECT id, venue_id, venue_name, business_id, owner_email, approval_status, created_at
FROM public.venue_claims
WHERE lower(trim(coalesce(owner_email, ''))) LIKE 'seed.utah.%@example.test'
   OR business_id IN (
     SELECT id FROM public.businesses
     WHERE lower(trim(coalesce(owner_email, ''))) LIKE 'seed.utah.%@example.test'
   )
ORDER BY created_at DESC NULLS LAST;
```

Cleanup order:

1. Backfill provenance on matching venues.
2. Set matching community venue ownership fields to null.
3. Terminalize matching claims.
4. Delete orphan helper business rows.
5. Verify no active authority remains.

Final verification:

```sql
SELECT count(*) AS active_seed_claims
FROM public.venue_claims
WHERE (
    lower(trim(coalesce(owner_email, ''))) LIKE 'seed.utah.%@example.test'
    OR business_id IN (
      SELECT id FROM public.businesses
      WHERE lower(trim(coalesce(owner_email, ''))) LIKE 'seed.utah.%@example.test'
    )
  )
  AND (
    lower(trim(coalesce(approval_status, ''))) IN ('approved', 'pending')
    OR public.gameon_venue_claim_is_open_pending(approval_status)
  );
```

```sql
SELECT count(*) AS community_rows_with_business_authority
FROM public.venues
WHERE origin_type = 'community'
  AND (
    business_id IS NOT NULL
    OR owner_user_id IS NOT NULL
    OR trim(coalesce(owner_email, '')) <> ''
  );
```

## Recommendations

1. Treat `utah_community_venues.sql` as the current seed source and retire `utah_venues_seed.sql` from shared environments.
2. Do not use helper businesses to represent community provenance.
3. Add explicit provenance metadata to `venues` instead of encoding source in `owner_email`.
4. Keep claim/release authority based on real business rows and approved claims only.
5. Keep historical rows, but ensure seed-helper claims are terminal and no longer grant ownership.
6. Consider tightening client feature verification so `origin_type = 'community'` with no active approved claim is always treated as unverified, even if legacy owner fields exist during migration.
