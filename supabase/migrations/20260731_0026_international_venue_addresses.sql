-- International venue addresses: add structured, nullable fields while preserving legacy US columns.

ALTER TABLE public.venues
  ADD COLUMN IF NOT EXISTS address_line1 text,
  ADD COLUMN IF NOT EXISTS address_line2 text,
  ADD COLUMN IF NOT EXISTS region text,
  ADD COLUMN IF NOT EXISTS postal_code text,
  ADD COLUMN IF NOT EXISTS formatted_address text;

COMMENT ON COLUMN public.venues.address_line1 IS
  'Primary street/address line for international venue addresses. Legacy venues.address remains for backward compatibility.';
COMMENT ON COLUMN public.venues.address_line2 IS
  'Optional apartment, floor, suite, building, or neighborhood detail.';
COMMENT ON COLUMN public.venues.region IS
  'Region/state/province/prefecture value; optional because formats vary by country.';
COMMENT ON COLUMN public.venues.postal_code IS
  'Postal code/ZIP/CEP value; optional because formats vary by country.';
COMMENT ON COLUMN public.venues.formatted_address IS
  'Country-aware address string for display and search.';

UPDATE public.venues
SET
  address_line1 = COALESCE(NULLIF(address_line1, ''), NULLIF(address, '')),
  region = COALESCE(NULLIF(region, ''), NULLIF(state, '')),
  postal_code = COALESCE(NULLIF(postal_code, ''), NULLIF(zip_code, '')),
  formatted_address = COALESCE(
    NULLIF(formatted_address, ''),
    NULLIF(
      concat_ws(
        ', ',
        NULLIF(address, ''),
        NULLIF(city, ''),
        NULLIF(trim(concat_ws(' ', NULLIF(state, ''), NULLIF(zip_code, ''))), ''),
        NULLIF(country, '')
      ),
      ''
    )
  )
WHERE address_line1 IS NULL
   OR region IS NULL
   OR postal_code IS NULL
   OR formatted_address IS NULL;

ALTER TABLE public.venue_claims
  ADD COLUMN IF NOT EXISTS venue_address_line2 text,
  ADD COLUMN IF NOT EXISTS venue_formatted_address text,
  ADD COLUMN IF NOT EXISTS venue_latitude double precision,
  ADD COLUMN IF NOT EXISTS venue_longitude double precision;

COMMENT ON COLUMN public.venue_claims.venue_address_line2 IS
  'Optional second address line for business owner submitted location claims.';
COMMENT ON COLUMN public.venue_claims.venue_formatted_address IS
  'Country-aware formatted address captured at claim submission time.';
COMMENT ON COLUMN public.venue_claims.venue_latitude IS
  'Latitude resolved from country-aware geocoding at claim submission time when available.';
COMMENT ON COLUMN public.venue_claims.venue_longitude IS
  'Longitude resolved from country-aware geocoding at claim submission time when available.';

UPDATE public.venue_claims
SET venue_formatted_address = COALESCE(
  NULLIF(venue_formatted_address, ''),
  NULLIF(
    concat_ws(
      ', ',
      NULLIF(venue_address, ''),
      NULLIF(venue_city, ''),
      NULLIF(trim(concat_ws(' ', NULLIF(venue_state, ''), NULLIF(venue_zip_code, ''))), ''),
      NULLIF(venue_country, '')
    ),
    ''
  )
)
WHERE venue_formatted_address IS NULL;

CREATE INDEX IF NOT EXISTS venues_country_idx
  ON public.venues (country);
