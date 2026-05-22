# Community Seed Provenance Migration Plan

Report-only implementation plan. Do not execute the SQL in this document until it has been reviewed against staging data.

## Goal

Prepare FanGeo for nationwide community venue seeding without fake seed business accounts or helper owner emails like `seed.utah.*@example.test`.

The end state is:

- Community venues are public map inventory, not business-owned listings.
- Community provenance lives in venue metadata, not `owner_email` or `business_id`.
- Business authority continues to come only from real business accounts and approved claims.
- Existing claim, release, and delete behavior stays unchanged.

## 1. Final Target Schema

Existing fields that remain central:

- `public.venues.origin_type`: canonical high-level row origin. Values should remain `community` or `business`.
- `public.venues.venue_identity_key`: stable duplicate/provenance identity for name/address matching.
- `public.venues.business_id`, `owner_user_id`, `owner_email`: authority fields only. These must not represent seed provenance.

Add provenance metadata to `public.venues`:

```sql
ALTER TABLE public.venues
  ADD COLUMN IF NOT EXISTS community_source text,
  ADD COLUMN IF NOT EXISTS community_source_id text,
  ADD COLUMN IF NOT EXISTS community_seed_batch text,
  ADD COLUMN IF NOT EXISTS community_seeded_at timestamptz,
  ADD COLUMN IF NOT EXISTS community_curated_by text,
  ADD COLUMN IF NOT EXISTS community_provenance jsonb NOT NULL DEFAULT '{}'::jsonb;
```

Recommended semantics:

- `community_source`: source namespace, for example `utah_seed`, `osm`, `manual_admin`, `partner_import`.
- `community_source_id`: source-specific stable id. For legacy rows this can temporarily hold the old seed email.
- `community_seed_batch`: import batch identifier, for example `utah_2026_q2`.
- `community_seeded_at`: timestamp when FanGeo imported or migrated the row.
- `community_curated_by`: admin/import process marker.
- `community_provenance`: richer source payload, such as old helper email, data provider, confidence score, import notes.

Target invariant for unclaimed community venues:

```sql
origin_type = 'community'
AND business_id IS NULL
AND owner_user_id IS NULL
AND owner_email IS NULL
AND trim(coalesce(cover_photo_url, '')) = ''
AND trim(coalesce(menu_photo_url, '')) = ''
AND trim(coalesce(cover_photo_thumbnail_url, '')) = ''
AND trim(coalesce(menu_photo_thumbnail_url, '')) = ''
AND trim(coalesce(features, '')) = ''
AND screen_count IS NULL
AND serves_food IS NULL
AND has_wifi IS NULL
AND has_garden IS NULL
AND has_projector IS NULL
AND pet_friendly IS NULL
AND supporter_country IS NULL
```

Community seed rows may include only public identity/provenance fields: name, address, city/state/zip/country, latitude/longitude, real public phone/email/website if available, `origin_type = 'community'`, `business_id = NULL`, `owner_user_id = NULL`, `owner_email = NULL`, `admin_status = 'active'`, and provenance fields.

Seeded community rows must not include photos, menu images, business feature copy, screen counts, amenity booleans, supporter/team settings, or business-written descriptions. Businesses add those fields after claiming and updating the venue.

## Preflight Schema Checks

Run these checks before drafting or applying a migration. The current schema may not include `public.venues.created_at`, so migration SQL must not reference it unless a dynamic schema check confirms it exists.

Verify required `public.venues` columns:

```sql
SELECT column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name = 'venues'
  AND column_name IN (
    'id',
    'venue_name',
    'address',
    'city',
    'state',
    'zip_code',
    'country',
    'latitude',
    'longitude',
    'admin_status',
    'origin_type',
    'venue_identity_key',
    'business_id',
    'owner_user_id',
    'owner_email'
  )
ORDER BY column_name;
```

Optional check for `venues.created_at` only if a future migration wants to use it:

```sql
SELECT EXISTS (
  SELECT 1
  FROM information_schema.columns
  WHERE table_schema = 'public'
    AND table_name = 'venues'
    AND column_name = 'created_at'
) AS venues_created_at_exists;
```

Verify required `public.businesses` columns:

```sql
SELECT column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name = 'businesses'
  AND column_name IN (
    'id',
    'display_name',
    'owner_email',
    'owner_user_id',
    'admin_status'
  )
ORDER BY column_name;
```

Verify required `public.venue_claims` columns:

```sql
SELECT column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name = 'venue_claims'
  AND column_name IN (
    'id',
    'venue_id',
    'venue_name',
    'business_id',
    'owner_email',
    'approval_status',
    'created_at',
    'venue_identity_key'
  )
ORDER BY column_name;
```

Verify provenance columns do not already exist before the first provenance migration. Expected result before first deploy is zero rows; if rows exist, inspect them and make the migration idempotent.

```sql
SELECT column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name = 'venues'
  AND column_name IN (
    'community_source',
    'community_source_id',
    'community_seed_batch',
    'community_seeded_at',
    'community_curated_by',
    'community_provenance'
  )
ORDER BY column_name;
```

Minimum preflight pass criteria:

- `venues` has the authority fields (`business_id`, `owner_user_id`, `owner_email`) and community fields (`origin_type`, `venue_identity_key`).
- `businesses` has `id`, `owner_email`, `owner_user_id`, and `admin_status`.
- `venue_claims` has `id`, `venue_id`, `business_id`, `owner_email`, `approval_status`, and `venue_identity_key`.
- Provenance columns are absent before first deployment or are already present with the expected definitions.
- No migration SQL relies on `venues.created_at` unless the optional existence check is true and the SQL is wrapped in a dynamic `DO` block.

## 2. Migration Steps

### Step 1: Add Columns

Add metadata columns only. This is additive and should be safe to deploy independently.

### Step 1A: Seed Import Rules

All national community seed imports must use an identity-only payload. Allowed fields:

- `venue_name`
- `address`, `address_line1`, `address_line2` if available
- `city`, `state`, `zip_code`, `country`
- `region`, `postal_code`, `formatted_address` if used by the current address schema
- `latitude`, `longitude`
- `phone` only when it is a real public venue phone number
- `website` only when it is a real public venue website
- a future public contact email column only if one exists and the email is real/public
- `origin_type = 'community'`
- `business_id = NULL`
- `owner_user_id = NULL`
- `owner_email = NULL`
- `admin_status = 'active'`
- `venue_identity_key`
- provenance fields (`community_source`, `community_source_id`, `community_seed_batch`, `community_seeded_at`, `community_curated_by`, `community_provenance`)

Fields that must be blank or `NULL` for seeded community venues:

- `cover_photo_url`
- `menu_photo_url`
- `cover_photo_thumbnail_url`
- `menu_photo_thumbnail_url`
- `features`
- `description`, unless it is basic public listing text and not promotional/business-authored
- `screen_count`
- `serves_food`
- `has_wifi`
- `has_garden`
- `has_projector`
- `pet_friendly`
- `supporter_country`

Import behavior:

- Do not create `public.businesses` rows for community seed data.
- Do not set `venues.owner_email` to fake or helper emails.
- Do not set `venue_claims` rows for unclaimed seeded venues.
- Do not fetch or attach photos during seeding.
- Do not infer amenities from venue type or third-party category labels.
- Treat all business-editable fields as unknown until a real business claims and updates the venue.

### Step 2: Backfill Current Valid Community Rows

For community rows already using the desired architecture:

```sql
UPDATE public.venues
SET
  community_source = coalesce(community_source, 'legacy_community'),
  community_seed_batch = coalesce(community_seed_batch, 'pre_provenance_migration'),
  community_seeded_at = coalesce(community_seeded_at, now()),
  community_provenance = community_provenance || jsonb_build_object(
    'migration_note', 'Backfilled provenance for existing unowned community venue'
  )
WHERE origin_type = 'community'
  AND business_id IS NULL
  AND owner_user_id IS NULL
  AND trim(coalesce(owner_email, '')) = '';
```

### Step 3: Convert Legacy Seed-Email Rows

For rows seeded with helper owner emails:

```sql
UPDATE public.venues
SET
  origin_type = 'community',
  community_source = coalesce(community_source, 'utah_legacy_seed'),
  community_source_id = coalesce(community_source_id, owner_email),
  community_seed_batch = coalesce(community_seed_batch, 'utah_venues_seed_legacy'),
  community_seeded_at = coalesce(community_seeded_at, now()),
  community_provenance = community_provenance || jsonb_build_object(
    'legacy_owner_email', owner_email,
    'migration_note', 'Converted seed helper owner_email to community provenance'
  )
WHERE lower(trim(coalesce(owner_email, ''))) LIKE 'seed.utah.%@example.test';
```

### Step 4: Detach Authority Fields

Detach only after provenance is captured.

```sql
UPDATE public.venues
SET
  business_id = NULL,
  owner_user_id = NULL,
  owner_email = NULL
WHERE origin_type = 'community'
  AND (
    lower(trim(coalesce(community_source_id, ''))) LIKE 'seed.utah.%@example.test'
    OR lower(trim(coalesce(owner_email, ''))) LIKE 'seed.utah.%@example.test'
  );
```

### Step 5: Normalize Seed-Linked Claims

Historical claim rows can remain. They must not grant active authority.

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

### Step 6: Remove Orphan Helper Businesses

Delete only after no references remain.

```sql
DELETE FROM public.businesses b
WHERE lower(trim(coalesce(b.owner_email, ''))) LIKE 'seed.utah.%@example.test'
  AND NOT EXISTS (SELECT 1 FROM public.venues v WHERE v.business_id = b.id)
  AND NOT EXISTS (SELECT 1 FROM public.venue_claims vc WHERE vc.business_id = b.id);
```

## 3. Detach Seed Helper Business Rows Safely

The safe detach order is:

1. Snapshot diagnostics for seed helpers.
2. Backfill venue provenance.
3. Null community venue authority fields.
4. Terminalize seed-linked claims.
5. Verify no active claims remain.
6. Delete helper businesses only if orphaned.

Do not remove helper businesses first. Foreign keys use `ON DELETE SET NULL`, which prevents broken references but does not preserve source metadata or normalize claim statuses.

## 4. Preserve Existing Community Venues

Preservation rules:

- Keep `public.venues.id` stable.
- Keep `venue_identity_key`, name, address, coordinates, city/state/zip/country.
- Keep public community row visible with `admin_status = 'active'`.
- Do not preserve seeded photos, menu images, feature strings, amenity values, screen counts, supporter country, or business-authored descriptions on unclaimed community venues.
- Preserve only public identity fields and provenance. Basic public listing text is allowed only when it is not promotional/business-authored.
- Preserve historical `venue_claims` rows, but terminalize seed-linked active claims.

For unclaimed community venue UI, the app should continue to rely on:

- `origin_type = 'community'`
- no active business authority fields
- no active approved claim

## 5. Keep Claim/Release/Delete Behavior Unchanged

Do not alter these behaviors during the provenance migration:

- Claim approval of an existing community venue still sets the venue row to `origin_type = 'community'` and links the real business.
- Claim approval of a new business-created venue still creates/uses `origin_type = 'business'`.
- Release of a community venue still keeps the venue row and clears business fields.
- Delete of a business-created venue still hard-deletes the venue and linked content.
- Historical claims remain for audit with terminal statuses.

The migration only changes how unclaimed seeded community provenance is stored.

## 6. SQL Verification Queries

### Before Migration

Find legacy seed-owned venues:

```sql
SELECT id, venue_name, owner_email, business_id, owner_user_id, origin_type, admin_status
FROM public.venues
WHERE lower(trim(coalesce(owner_email, ''))) LIKE 'seed.utah.%@example.test'
   OR business_id IN (
     SELECT id
     FROM public.businesses
     WHERE lower(trim(coalesce(owner_email, ''))) LIKE 'seed.utah.%@example.test'
   )
ORDER BY venue_name;
```

Find seed helper businesses:

```sql
SELECT id, display_name, owner_email, owner_user_id, admin_status
FROM public.businesses
WHERE lower(trim(coalesce(owner_email, ''))) LIKE 'seed.utah.%@example.test'
ORDER BY owner_email;
```

Find seed-linked claims:

```sql
SELECT id, venue_id, venue_name, business_id, owner_email, approval_status, created_at
FROM public.venue_claims
WHERE lower(trim(coalesce(owner_email, ''))) LIKE 'seed.utah.%@example.test'
   OR business_id IN (
     SELECT id
     FROM public.businesses
     WHERE lower(trim(coalesce(owner_email, ''))) LIKE 'seed.utah.%@example.test'
   )
ORDER BY created_at DESC NULLS LAST;
```

Find active seed-linked claims:

```sql
SELECT count(*) AS active_seed_claims
FROM public.venue_claims
WHERE (
    lower(trim(coalesce(owner_email, ''))) LIKE 'seed.utah.%@example.test'
    OR business_id IN (
      SELECT id
      FROM public.businesses
      WHERE lower(trim(coalesce(owner_email, ''))) LIKE 'seed.utah.%@example.test'
    )
  )
  AND (
    lower(trim(coalesce(approval_status, ''))) IN ('approved', 'pending')
    OR public.gameon_venue_claim_is_open_pending(approval_status)
  );
```

### After Migration

Verify no community row has business authority:

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

Verify seed helpers no longer own claims:

```sql
SELECT count(*) AS active_seed_claims
FROM public.venue_claims
WHERE (
    lower(trim(coalesce(owner_email, ''))) LIKE 'seed.utah.%@example.test'
    OR business_id IN (
      SELECT id
      FROM public.businesses
      WHERE lower(trim(coalesce(owner_email, ''))) LIKE 'seed.utah.%@example.test'
    )
  )
  AND (
    lower(trim(coalesce(approval_status, ''))) IN ('approved', 'pending')
    OR public.gameon_venue_claim_is_open_pending(approval_status)
  );
```

Verify provenance exists:

```sql
SELECT count(*) AS community_without_source
FROM public.venues
WHERE origin_type = 'community'
  AND community_source IS NULL;
```

Verify Utah seed rows remain visible:

```sql
SELECT id, venue_name, city, state, origin_type, community_source, business_id, owner_email, admin_status
FROM public.venues
WHERE state = 'UT'
  AND origin_type = 'community'
ORDER BY city, venue_name;
```

Verify unclaimed community seed rows have no photos:

```sql
SELECT id, venue_name, state, community_source,
       cover_photo_url, menu_photo_url, cover_photo_thumbnail_url, menu_photo_thumbnail_url
FROM public.venues
WHERE origin_type = 'community'
  AND business_id IS NULL
  AND owner_user_id IS NULL
  AND trim(coalesce(owner_email, '')) = ''
  AND (
    trim(coalesce(cover_photo_url, '')) <> ''
    OR trim(coalesce(menu_photo_url, '')) <> ''
    OR trim(coalesce(cover_photo_thumbnail_url, '')) <> ''
    OR trim(coalesce(menu_photo_thumbnail_url, '')) <> ''
  )
ORDER BY state, venue_name;
```

Verify unclaimed community seed rows have no business feature/description payloads beyond allowed public listing text:

```sql
SELECT id, venue_name, state, community_source, features, description
FROM public.venues
WHERE origin_type = 'community'
  AND business_id IS NULL
  AND owner_user_id IS NULL
  AND trim(coalesce(owner_email, '')) = ''
  AND (
    trim(coalesce(features, '')) <> ''
    OR length(trim(coalesce(description, ''))) > 240
  )
ORDER BY state, venue_name;
```

Verify unclaimed community seed rows have no amenity or supporter values:

```sql
SELECT id, venue_name, state, community_source,
       screen_count, serves_food, has_wifi, has_garden, has_projector, pet_friendly, supporter_country
FROM public.venues
WHERE origin_type = 'community'
  AND business_id IS NULL
  AND owner_user_id IS NULL
  AND trim(coalesce(owner_email, '')) = ''
  AND (
    screen_count IS NOT NULL
    OR serves_food IS NOT NULL
    OR has_wifi IS NOT NULL
    OR has_garden IS NOT NULL
    OR has_projector IS NOT NULL
    OR pet_friendly IS NOT NULL
    OR supporter_country IS NOT NULL
  )
ORDER BY state, venue_name;
```

Aggregate validation for release gates:

```sql
SELECT
  count(*) FILTER (
    WHERE trim(coalesce(cover_photo_url, '')) <> ''
       OR trim(coalesce(menu_photo_url, '')) <> ''
       OR trim(coalesce(cover_photo_thumbnail_url, '')) <> ''
       OR trim(coalesce(menu_photo_thumbnail_url, '')) <> ''
  ) AS unclaimed_community_with_photos,
  count(*) FILTER (
    WHERE trim(coalesce(features, '')) <> ''
       OR length(trim(coalesce(description, ''))) > 240
  ) AS unclaimed_community_with_business_copy,
  count(*) FILTER (
    WHERE screen_count IS NOT NULL
       OR serves_food IS NOT NULL
       OR has_wifi IS NOT NULL
       OR has_garden IS NOT NULL
       OR has_projector IS NOT NULL
       OR pet_friendly IS NOT NULL
       OR supporter_country IS NOT NULL
  ) AS unclaimed_community_with_amenities
FROM public.venues
WHERE origin_type = 'community'
  AND business_id IS NULL
  AND owner_user_id IS NULL
  AND trim(coalesce(owner_email, '')) = '';
```

## 7. Rollback Plan

Rollback should avoid restoring fake ownership unless absolutely necessary.

Preferred rollback:

1. Keep provenance columns.
2. Revert only data changed in the failed migration from a pre-migration snapshot table.
3. Restore `business_id`, `owner_user_id`, `owner_email`, and claim statuses only for rows proven to have been incorrectly migrated.
4. Keep app behavior unchanged while investigating.

Before migration, create snapshot tables:

```sql
CREATE TABLE IF NOT EXISTS public._rollback_seed_venue_snapshot AS
SELECT *
FROM public.venues
WHERE lower(trim(coalesce(owner_email, ''))) LIKE 'seed.utah.%@example.test'
   OR origin_type = 'community';
```

```sql
CREATE TABLE IF NOT EXISTS public._rollback_seed_claim_snapshot AS
SELECT *
FROM public.venue_claims
WHERE lower(trim(coalesce(owner_email, ''))) LIKE 'seed.utah.%@example.test'
   OR business_id IN (
     SELECT id
     FROM public.businesses
     WHERE lower(trim(coalesce(owner_email, ''))) LIKE 'seed.utah.%@example.test'
   );
```

Rollback checks:

- Confirm target ids before restoring.
- Restore only affected ids, not entire tables.
- Do not drop provenance columns unless a later deployment requires it.

## 8. Utah-First Test Plan

Use Utah only as the pilot.

Preflight:

1. Run before-migration diagnostics.
2. Confirm exact count of legacy `seed.utah.*@example.test` venues.
3. Confirm whether any helper `businesses` rows exist.
4. Confirm active seed-linked claims count.
5. Confirm current Utah venue visibility in Discover.

Migration dry run:

1. Run all planned updates inside a transaction on staging.
2. Inspect affected row counts.
3. Roll back manually in staging after count validation.
4. Re-run in staging and commit once counts match expectation.

Functional staging tests:

1. Open Discover in Utah bounds and confirm seeded community venues still appear.
2. Open a migrated venue detail screen and confirm it shows as unclaimed/community, not verified business-owned.
3. Confirm features show the unverified community venue state.
4. Submit a claim for one migrated Utah venue.
5. Approve the claim through the admin flow.
6. Confirm the venue becomes managed by the real business.
7. Release the venue from the business.
8. Confirm the venue remains on Discover, returns to unclaimed state, and keeps provenance metadata.
9. Delete a business-created venue and confirm hard-delete behavior is unchanged.

Production Utah rollout:

1. Apply schema columns.
2. Run diagnostics and store snapshots.
3. Migrate Utah seed-helper rows only.
4. Validate with after queries.
5. Smoke test Discover and one claim/release cycle.

## 9. Phased National Rollout

### Phase 0: Readiness

- Add provenance schema.
- Retire fake-owner seed flows from operational scripts.
- Ensure import tooling writes `origin_type = 'community'`, `business_id = NULL`, `owner_user_id = NULL`, `owner_email = NULL`.
- Ensure import tooling writes no photo URLs, menu URLs, features, amenity values, screen counts, supporter country, or business-authored descriptions for unclaimed community venues.
- Establish source namespaces such as `utah_seed`, `national_seed_v1`, `osm`, `manual_admin`, `partner_import`.

### Phase 1: Utah Pilot

- Migrate legacy Utah helper-owner rows.
- Validate UI, claim, release, and delete behavior.
- Monitor active claim counts and community row authority invariants.

### Phase 2: Regional Expansion

- Add a limited set of neighboring states or one metro cluster.
- Use provenance batch ids per state/metro, for example `co_denver_2026_q3`.
- Import in small batches with post-import verification:
  - no business authority fields
  - no seeded photos
  - no seeded amenities or screen counts
  - no seeded feature/menu/business detail payloads
  - unique `venue_identity_key`
  - valid coordinates
  - `admin_status = 'active'`
  - `origin_type = 'community'`

### Phase 3: National Seed V1

- Import nationwide community venues in state or metro batches.
- Require every imported row to have:
  - `origin_type = 'community'`
  - provenance fields
  - stable identity key
  - no owner/business authority
- Require every imported row to omit photos, menu images, feature strings, screen counts, amenity booleans, supporter country, and business-written descriptions.
- Keep amenities and business details unknown until a real business claims and updates the venue.

### Phase 4: Ongoing Governance

- Add periodic invariant checks:
  - community rows with owner/business authority
  - unclaimed community rows with photos
  - unclaimed community rows with amenity/feature values
  - active seed-helper claims
  - missing provenance
  - duplicate identity keys
- Add admin tooling to view provenance metadata.
- Add import audit logs for each national batch.

## Non-Goals

- Do not change business claim approval semantics.
- Do not change community release semantics.
- Do not delete historical claim rows.
- Do not use fake auth/business accounts for community inventory.
- Do not make public community amenities appear verified unless a real business or trusted source verifies them.
