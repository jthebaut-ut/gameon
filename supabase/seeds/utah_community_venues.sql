-- Curated Utah community watch venues intended to bootstrap Discover map density
-- before business onboarding.
--
-- Production source of truth is database-only. The iOS app must remain read-only
-- for `public.venues`.
--
-- Community venue rules for this seed:
--   - owner_email = NULL
--   - business_id = NULL
--   - admin_status = 'active'
--   - country = 'USA'
--   - amenity columns (screen_count, serves_food, has_wifi, etc.) = NULL (unverified)
--
-- Idempotency:
--   - dedupe by `venue_identity_key`
--   - insert only when no existing venue row shares the same identity
--   - never update or overwrite `owner_email` / `business_id`
--
-- `sports_supported` exists in the curation source as future metadata only.
-- `public.venues` does not currently store that field, so this seed does not
-- write a sports default of any kind.

WITH seed_source AS (
  SELECT *
  FROM (
    VALUES
      ('Beerhive Pub', '128 S Main St', 'Salt Lake City', 'UT', '84101', 40.7669, -111.8910, '', '', 12, true, true, true, 'Downtown Salt Lake watch spot with multiple screens and walkable access.', 'Downtown,Main Street,Multiple screens', NULL, 'USA', 'active'),
      ('Legends Sports Pub', '677 S 200 W', 'Salt Lake City', 'UT', '84101', 40.7590, -111.9010, '', '', 8, true, true, false, 'Central Salt Lake pub with a compact game-day setup near the arena district.', 'Central city,Big screens,Game-day crowd', NULL, 'USA', 'active'),
      ('Gateway Watch Taproom', '175 S Rio Grande St', 'Salt Lake City', 'UT', '84101', 40.7661, -111.9033, '', '', 9, true, true, true, 'Downtown Salt Lake community watch venue near the Gateway with flexible group seating.', 'Downtown,Gateway,Projector nights', NULL, 'USA', 'active'),
      ('The Pitch Provo', '4801 N University Ave', 'Provo', 'UT', '84604', 40.2971, -111.6595, '', '', 6, true, true, false, 'North Provo community watch venue near the BYU corridor.', 'Patio,College town,Group-friendly', NULL, 'USA', 'active'),
      ('Center Street Watch House', '65 W Center St', 'Provo', 'UT', '84601', 40.2338, -111.6603, '', '', 7, true, true, false, 'Downtown Provo watch spot with casual dining and a reliable TV wall for major games.', 'Downtown Provo,College town,Casual dining', NULL, 'USA', 'active'),
      ('Union Grill & Sports', '2501 Wall Ave', 'Ogden', 'UT', '84401', 41.2230, -111.9738, '', '', 10, true, true, true, 'Ogden watch venue with food service and strong TV coverage.', 'Ogden,Food specials,Large room', NULL, 'USA', 'active'),
      ('Red Rock Tavern', '25 N Main St', 'St. George', 'UT', '84770', 37.0965, -113.5684, '', '', 9, true, true, true, 'Southern Utah downtown watch venue suited for night games and road trips.', 'Downtown,Southern Utah,Late hours', NULL, 'USA', 'active'),
      ('Rimrock Sports Bar', '58 S Main St', 'Moab', 'UT', '84532', 38.5723, -109.5498, '', '', 4, true, true, false, 'Moab downtown stop for visitors looking for a reliable game screen.', 'Moab,Downtown,Tourist-friendly', NULL, 'USA', 'active'),
      ('Cache Valley Sports Lounge', '696 N Main St', 'Logan', 'UT', '84321', 41.7363, -111.8358, '', '', 7, true, true, false, 'Logan-area watch lounge close to campus and neighborhood traffic.', 'College town,Neighborhood,Easy parking', NULL, 'USA', 'active'),
      ('Alpine View Tavern', '738 Lower Main St', 'Park City', 'UT', '84060', 40.6412, -111.4965, '', '', 5, true, true, false, 'Main Street Park City venue for visitors and locals catching major games.', 'Main Street,Resort town,Walkable', NULL, 'USA', 'active'),
      ('State Street Tavern', '10600 S State St', 'Sandy', 'UT', '84070', 40.5657, -111.8902, '', '', 10, true, true, true, 'South Valley watch spot with room for larger weekend crowds.', 'South Valley,Multiple screens,Game-day crowd', NULL, 'USA', 'active'),
      ('South Towne Sports Kitchen', '10450 S State St', 'Sandy', 'UT', '84070', 40.5669, -111.8900, '', '', 8, true, true, true, 'Sandy-area watch kitchen positioned for South Towne and weekend group traffic.', 'Sandy,South Towne,Projector', NULL, 'USA', 'active'),
      ('Traverse Ridge Grill', '13800 S Bangerter Hwy', 'Draper', 'UT', '84020', 40.5247, -111.8588, '', '', 8, true, true, false, 'Draper-area watch venue with family-friendly food service.', 'South valley,Family-friendly,Large tables', NULL, 'USA', 'active'),
      ('SoJo Social House', '11259 S Kestrel Rise Rd', 'South Jordan', 'UT', '84095', 40.9142, -111.9806, '', '', 6, true, true, true, 'South Jordan gathering spot set up for casual watch parties.', 'Daybreak area,Social groups,Projector nights', NULL, 'USA', 'active'),
      ('Jordan Landing Pub', '7182 S Plaza Center Dr', 'West Jordan', 'UT', '84084', 40.6097, -111.9391, '', '', 9, true, true, true, 'West Jordan plaza watch venue with strong suburban access.', 'Jordan Landing,Suburban,Large screens', NULL, 'USA', 'active'),
      ('University Parkway Tavern', '765 E University Pkwy', 'Orem', 'UT', '84097', 40.2969, -111.6946, '', '', 7, true, true, false, 'Orem watch venue along the University Parkway corridor.', 'University corridor,Casual dining,Accessible parking', NULL, 'USA', 'active'),
      ('Main Street Social Cedar', '86 N Main St', 'Cedar City', 'UT', '84720', 37.6775, -113.0619, '', '', 5, true, true, false, 'Cedar City downtown venue with a simple sports viewing setup.', 'Downtown,Southern Utah,Community spot', NULL, 'USA', 'active'),
      ('Lehi Station Watch House', '1675 W Traverse Pkwy', 'Lehi', 'UT', '84043', 40.4364, -111.8931, '', '', 8, true, true, true, 'Silicon Slopes-area venue designed for after-work game meetups.', 'Tech corridor,After work,Multiple screens', NULL, 'USA', 'active'),
      ('Bountiful Bench Sports Grill', '273 W 500 S', 'Bountiful', 'UT', '84010', 40.8847, -111.8858, '', '', 6, true, true, false, 'North Davis County neighborhood grill with dependable game coverage.', 'North Davis,Neighborhood,Dinner service', NULL, 'USA', 'active'),
      ('Station Park Sports Social', '115 N West Promontory', 'Farmington', 'UT', '84025', 40.9812, -111.9042, '', '', 7, true, true, true, 'Farmington mixed-use district watch venue with strong family traffic.', 'Station Park,Mixed-use,Projector', NULL, 'USA', 'active'),
      ('American Fork Goalpost Grill', '648 E State Rd', 'American Fork', 'UT', '84003', 40.3765, -111.7861, '', '', 7, true, true, false, 'North Utah County watch venue positioned for local weekend groups.', 'Utah County,Casual,Weekend crowd', NULL, 'USA', 'active'),
      ('Midvale Junction Watch Bar', '7687 S Main St', 'Midvale', 'UT', '84047', 40.6137, -111.8908, '', '', 6, true, true, false, 'Transit-accessible central valley watch bar with easy stop-in traffic.', 'TRAX access,Central valley,Quick stop', NULL, 'USA', 'active'),
      ('Murray Central Sports Kitchen', '4885 S State St', 'Murray', 'UT', '84107', 40.6622, -111.8872, '', '', 9, true, true, true, 'Central valley kitchen and sports venue close to hospital and retail traffic.', 'Central valley,Kitchen,Large room', NULL, 'USA', 'active'),
      ('Fort Union Watch Co.', '6985 S Union Park Ave', 'Cottonwood Heights', 'UT', '84047', 40.6244, -111.8575, '', '', 8, true, true, true, 'Fort Union corridor venue suited for small groups and playoff nights.', 'Fort Union,Playoff nights,Projector', NULL, 'USA', 'active'),
      ('Herriman Game Day House', '13353 S 5200 W', 'Herriman', 'UT', '84096', 40.4962, -112.0137, '', '', 7, true, true, false, 'Southwest valley venue with room for youth sports families and bigger parties.', 'Southwest valley,Family groups,Newer build', NULL, 'USA', 'active'),
      ('Riverton Watch & Gather', '13298 S Market Center Dr', 'Riverton', 'UT', '84065', 40.5125, -111.9787, '', '', 6, true, true, false, 'Riverton neighborhood venue with casual food and screen coverage.', 'Neighborhood,Market center,Casual dining', NULL, 'USA', 'active'),
      ('Layton Hills Sports Room', '1350 N Hill Field Rd', 'Layton', 'UT', '84041', 41.0791, -111.9797, '', '', 8, true, true, true, 'Layton retail corridor venue with easy freeway access and broad TV coverage.', 'Retail corridor,Freeway access,Projector', NULL, 'USA', 'active'),
      ('Heber Valley Social Club', '190 S Main St', 'Heber City', 'UT', '84032', 40.5054, -111.4130, '', '', 5, true, true, false, 'Heber Valley community venue serving both locals and weekend visitors.', 'Mountain town,Community spot,Walkable', NULL, 'USA', 'active'),
      ('Spanish Fork Fieldhouse Pub', '826 Expressway Ln', 'Spanish Fork', 'UT', '84660', 40.1032, -111.6585, '', '', 6, true, true, false, 'South Utah County venue for highway travelers and local fans alike.', 'Highway access,Utah County,Group seating', NULL, 'USA', 'active')
  ) AS v(
    venue_name,
    address,
    city,
    state,
    zip_code,
    latitude,
    longitude,
    phone,
    website,
    screen_count,
    serves_food,
    has_wifi,
    has_projector,
    description,
    features,
    cover_photo_url,
    country,
    admin_status
  )
),
prepared AS (
  SELECT
    src.*,
    public.gameon_venue_identity_key(
      src.venue_name,
      src.address,
      src.city,
      src.state,
      src.zip_code
    ) AS venue_identity_key
  FROM seed_source src
)
INSERT INTO public.venues (
  id,
  owner_email,
  business_id,
  venue_name,
  address,
  city,
  state,
  zip_code,
  phone,
  website,
  description,
  features,
  screen_count,
  serves_food,
  has_wifi,
  has_garden,
  has_projector,
  pet_friendly,
  latitude,
  longitude,
  cover_photo_url,
  menu_photo_url,
  cover_photo_thumbnail_url,
  menu_photo_thumbnail_url,
  country,
  admin_status
)
SELECT
  gen_random_uuid(),
  NULL,
  NULL,
  p.venue_name,
  p.address,
  p.city,
  p.state,
  p.zip_code,
  p.phone,
  p.website,
  p.description,
  p.features,
  NULL,
  NULL,
  NULL,
  NULL,
  NULL,
  NULL,
  p.latitude,
  p.longitude,
  p.cover_photo_url,
  NULL,
  NULL,
  NULL,
  p.country,
  p.admin_status
FROM prepared p
WHERE NOT EXISTS (
  SELECT 1
  FROM public.venues v
  WHERE COALESCE(
    v.venue_identity_key,
    public.gameon_venue_identity_key(
      v.venue_name,
      v.address,
      v.city,
      v.state,
      v.zip_code
    )
  ) = p.venue_identity_key
);
