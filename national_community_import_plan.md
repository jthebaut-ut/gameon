# National Community Venue Import Plan

Report and operations plan for the backend import pipeline. No iOS UI changes are included.

## Goal

Create a production-safe path for nationwide community venue seeding with:

- no fake seed business accounts
- duplicate prevention before insert into `public.venues`
- provenance tracking on every promoted community venue
- no seeded photos, menus, features, screen counts, amenity booleans, supporter country, or business-written details

## Migration Artifact

The backend pipeline is defined in:

`supabase/migrations/20260731_0037_national_community_venue_import_pipeline.sql`

It adds:

- `public.community_venue_import_staging`
- normalization helper functions for venue names and addresses
- a helper wrapper for `venue_identity_key`
- duplicate detection via `community_venue_import_duplicate_candidates(...)`
- batch validation via `validate_community_venue_import_batch(...)`
- controlled promotion via `promote_community_venue_import_batch(...)`

The migration creates architecture only. It does not import, update, delete, or backfill existing venue rows by itself.

## Staging Contract

Each staged row must represent an unclaimed community venue and use an identity-only payload.

Allowed import data:

- venue name
- address fields
- city, state, ZIP/postal code, country
- latitude and longitude
- real public phone, if available
- real public website, if available
- real public email, if available, stored in staging/provenance only
- source and batch provenance

Required community authority state:

- `origin_type = 'community'`
- `business_id IS NULL`
- `owner_user_id IS NULL`
- `owner_email` blank/null
- `admin_status = 'active'`

Disallowed seeded data:

- cover/menu photos
- photo thumbnails
- `features`
- screen count
- amenity booleans
- supporter country
- promotional or business-authored descriptions

Basic public listing description is allowed only when `description_is_basic_public_listing = true` and the text is short.

## Normalization and Identity

The pipeline exposes:

- `community_venue_import_normalize_venue_name(text)`
- `community_venue_import_normalize_address(text)`
- `community_venue_import_identity_key(name, address, city, state, zip)`

The staging table stores:

- `normalized_venue_name`
- `normalized_address`
- `normalized_city`
- `normalized_state`
- `venue_identity_key`

These are generated columns so source imports cannot manually spoof normalized values.

## Duplicate Detection

Duplicate candidates are detected against:

- existing `public.venues.venue_identity_key`
- existing normalized venue name + address + city + state
- same-batch `venue_identity_key`
- same-batch normalized venue name + address + city + state

Inspect duplicates for a batch:

```sql
SELECT *
FROM public.community_venue_import_duplicate_candidates('national_seed_v1_utah');
```

## Validation

Validate a batch:

```sql
SELECT public.validate_community_venue_import_batch('national_seed_v1_utah');
```

Validation marks rows as:

- `invalid` when required fields or strict community rules fail
- `duplicate` when existing or same-batch duplicates are found
- `ready` when rows are safe to promote

Inspect status:

```sql
SELECT import_status, duplicate_reason, count(*)
FROM public.community_venue_import_staging
WHERE import_batch_id = 'national_seed_v1_utah'
GROUP BY import_status, duplicate_reason
ORDER BY import_status, duplicate_reason;
```

Inspect invalid rows:

```sql
SELECT source_row_number, venue_name, address, city, state, duplicate_reason
FROM public.community_venue_import_staging
WHERE import_batch_id = 'national_seed_v1_utah'
  AND import_status = 'invalid'
ORDER BY source_row_number;
```

Inspect duplicate rows:

```sql
SELECT source_row_number, venue_name, address, city, state, duplicate_reason
FROM public.community_venue_import_staging
WHERE import_batch_id = 'national_seed_v1_utah'
  AND import_status = 'duplicate'
ORDER BY source_row_number;
```

## Promotion

Promote only validated `ready` rows:

```sql
SELECT public.promote_community_venue_import_batch(
  'national_seed_v1_utah',
  'national_import_pipeline'
);
```

Promotion inserts into `public.venues` with:

- `origin_type = 'community'`
- `admin_status = 'active'`
- no business authority fields
- no seeded photos
- no seeded feature/amenity data
- provenance columns populated

Promoted staging rows receive:

- `import_status = 'promoted'`
- `promoted_venue_id`
- `promoted_at`

## Post-Promotion Verification

Verify promoted rows:

```sql
SELECT promoted_venue_id, venue_name, import_status, promoted_at
FROM public.community_venue_import_staging
WHERE import_batch_id = 'national_seed_v1_utah'
ORDER BY source_row_number;
```

Verify no unclaimed community venue has business authority:

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

Verify no seeded community venue has photos:

```sql
SELECT count(*) AS community_rows_with_seeded_photos
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
  );
```

Verify no seeded community venue has feature or amenity values:

```sql
SELECT count(*) AS community_rows_with_seeded_features_or_amenities
FROM public.venues
WHERE origin_type = 'community'
  AND business_id IS NULL
  AND owner_user_id IS NULL
  AND trim(coalesce(owner_email, '')) = ''
  AND (
    trim(coalesce(features, '')) <> ''
    OR screen_count IS NOT NULL
    OR serves_food IS NOT NULL
    OR has_wifi IS NOT NULL
    OR has_garden IS NOT NULL
    OR has_projector IS NOT NULL
    OR pet_friendly IS NOT NULL
    OR supporter_country IS NOT NULL
  );
```

Verify provenance:

```sql
SELECT count(*) AS community_rows_missing_provenance
FROM public.venues
WHERE origin_type = 'community'
  AND (
    community_source IS NULL
    OR community_seed_batch IS NULL
    OR community_seeded_at IS NULL
  );
```

## Rollout Plan

1. Load a small Utah-only batch into staging.
2. Run validation and inspect invalid/duplicate rows.
3. Fix source data outside production tables.
4. Re-stage corrected rows in a new batch id.
5. Promote Utah only.
6. Verify Discover/map visibility and claim flow.
7. Expand by region with separate batch ids.
8. Promote national data only after duplicate and strict seed-data validation are clean.

## Operational Guardrails

- Never insert directly into `public.venues` for national seed imports.
- Never use fake `owner_email`, fake `owner_user_id`, or helper `businesses` rows.
- Never seed business-controlled fields.
- Treat duplicates as review items, not automatic overwrites.
- Keep all staged batches queryable for audit.
