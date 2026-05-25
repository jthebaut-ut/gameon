import argparse
import csv
import requests
from datetime import datetime, timezone

OVERPASS_URL = "https://overpass-api.de/api/interpreter"

COUNTRIES = {
    "FR": "France",
    "ES": "Spain",
    "IT": "Italy",
    "DE": "Germany",
    "UK": "United Kingdom",
    "PT": "Portugal",
    "NL": "Netherlands",
    "BE": "Belgium",
    "IE": "Ireland",
    "CH": "Switzerland",
    "AT": "Austria",
    "AL": "Albania",
    "BR": "Brazil",
    "AR": "Argentina",
    "CO": "Colombia",
}

CSV_COLUMNS = [
    "venue_name", "address", "city", "state", "zip_code", "phone", "website",
    "sports_supported", "latitude", "longitude", "approved_at",
    "photo_review_status", "admin_status", "country", "origin_type",
    "community_source", "community_source_id", "community_seed_batch",
    "community_seeded_at", "community_curated_by", "community_provenance",
    "place_type",
]

CITY_BOXES = {
    "France": [(48.80,2.20,48.92,2.48), (50.58,2.92,50.72,3.18), (43.60,7.15,43.78,7.35), (43.52,1.30,43.70,1.55), (48.34,-4.58,48.45,-4.40), (43.20,5.25,43.40,5.55), (45.65,4.70,45.85,5.00), (47.15,-1.68,47.32,-1.45), (43.55,3.75,43.70,4.00), (44.78,-0.70,44.92,-0.45), (48.50,7.65,48.65,7.85)],
    "Spain": [(40.35,-3.90,40.55,-3.55), (41.30,2.05,41.50,2.25), (37.30,-6.05,37.45,-5.85)],
    "Italy": [(41.80,12.40,41.98,12.60), (45.40,9.05,45.55,9.30), (40.80,14.15,40.92,14.35)],
    "Germany": [(52.45,13.25,52.60,13.55), (48.05,11.45,48.20,11.70), (50.00,8.55,50.20,8.80)],
    "United Kingdom": [(51.45,-0.30,51.60,0.10), (53.40,-2.35,53.55,-2.15), (55.85,-4.35,56.00,-4.15)],
    "Portugal": [(38.65,-9.25,38.80,-9.05), (41.10,-8.75,41.25,-8.50)],
    "Netherlands": [(52.30,4.75,52.42,5.00), (51.85,4.40,51.98,4.60)],
    "Belgium": [(50.80,4.25,50.92,4.45), (51.15,4.30,51.28,4.50)],
    "Ireland": [(53.30,-6.40,53.42,-6.10), (51.85,-8.60,51.95,-8.40)],
    "Switzerland": [(47.30,8.45,47.42,8.65), (46.15,6.05,46.28,6.18)],
    "Austria": [(48.15,16.25,48.30,16.45), (47.75,13.00,47.90,13.10)],
    "Albania": [(41.28,19.70,41.40,19.90), (40.43,19.43,40.50,19.53), (42.03,19.45,42.10,19.55), (40.60,20.75,40.67,20.83), (41.08,20.75,41.15,20.85), (41.30,19.43,41.36,19.50)],

    "Brazil": [
    (-23.70,-46.85,-23.45,-46.45), # São Paulo
    (-22.98,-43.35,-22.75,-43.10), # Rio de Janeiro
    (-19.98,-44.10,-19.75,-43.85), # Belo Horizonte
    (-25.55,-49.40,-25.35,-49.15), # Curitiba
    (-30.15,-51.35,-29.95,-51.05), # Porto Alegre
    (-12.85,-38.60,-12.75,-38.25), # Salvador
],

    "Argentina": [
        (-34.75,-58.55,-34.50,-58.30), # Buenos Aires
        (-31.50,-64.30,-31.30,-64.05), # Córdoba
        (-32.98,-60.80,-32.85,-60.55), # Rosario
        (-32.95,-68.95,-32.80,-68.75), # Mendoza
        (-38.10,-57.70,-37.90,-57.45), # Mar del Plata
    ],

    "Colombia": [
        (4.55,-74.20,4.80,-73.95),     # Bogotá
        (6.15,-75.70,6.35,-75.45),     # Medellín
        (3.35,-76.65,3.55,-76.45),     # Cali
        (10.90,-74.90,11.10,-74.70),   # Barranquilla
        (10.35,-75.60,10.50,-75.40),   # Cartagena
    ],
}

def safe_get(tags, key):
    value = tags.get(key, "")
    return value.strip() if isinstance(value, str) else ""

def build_query(country_name):
    parts = []
    for s, w, n, e in CITY_BOXES[country_name]:
        parts.append(f'''
        node["amenity"~"bar|pub|restaurant|cafe"]["name"~"sport|sports|foot|football|soccer|rugby|irish|pub|bar|futbol|fútbol", i]({s},{w},{n},{e});
        way["amenity"~"bar|pub|restaurant|cafe"]["name"~"sport|sports|foot|football|soccer|rugby|irish|pub|bar|futbol|fútbol", i]({s},{w},{n},{e});
        relation["amenity"~"bar|pub|restaurant|cafe"]["name"~"sport|sports|foot|football|soccer|rugby|irish|pub|bar|futbol|fútbol", i]({s},{w},{n},{e});
        ''')

    return f"""
    [out:json][timeout:180];
    (
    {"".join(parts)}
    );
    out center tags 500;
    """

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--country", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    country_code = args.country.upper()

    if country_code not in COUNTRIES:
        raise ValueError(f"Unsupported country: {country_code}")

    country_name = COUNTRIES[country_code]
    print(f"Fetching venues for {country_name}...")

    response = requests.post(
        OVERPASS_URL,
        data={"data": build_query(country_name)},
        timeout=240,
        headers={"User-Agent": "FanGeoVenueImporter/4.0"}
    )

    response.raise_for_status()

    data = response.json()
    now = datetime.now(timezone.utc).isoformat()

    rows = []
    seen = set()

    for element in data.get("elements", []):
        tags = element.get("tags", {})
        name = safe_get(tags, "name")

        if not name:
            continue

        city = safe_get(tags, "addr:city") or safe_get(tags, "city")
        address = " ".join([
            safe_get(tags, "addr:housenumber"),
            safe_get(tags, "addr:street"),
        ]).strip()

        lat = element.get("lat")
        lon = element.get("lon")

        if (lat is None or lon is None) and "center" in element:
            lat = element["center"].get("lat")
            lon = element["center"].get("lon")

        if lat is None or lon is None:
            continue

        logical_key = (
            name.strip().lower(),
            address.strip().lower(),
            city.strip().lower(),
            country_name.lower(),
            round(float(lat), 5),
            round(float(lon), 5),
        )

        if logical_key in seen:
            continue

        seen.add(logical_key)

        rows.append({
            "venue_name": name,
            "address": address,
            "city": city,
            "state": "",
            "zip_code": safe_get(tags, "addr:postcode"),
            "phone": safe_get(tags, "phone") or safe_get(tags, "contact:phone"),
            "website": safe_get(tags, "website") or safe_get(tags, "contact:website"),
            "sports_supported": "",
            "latitude": lat,
            "longitude": lon,
            "approved_at": now,
            "photo_review_status": "approved",
            "admin_status": "active",
            "country": country_name,
            "origin_type": "community",
            "community_source": f"osm_venues_{country_code.lower()}_v4",
            "community_source_id": f"{country_code.lower()}_{len(rows)+1:05d}",
            "community_seed_batch": f"{country_code.lower()}_venues_batch_v4",
            "community_seeded_at": now,
            "community_curated_by": "osm_import_terminal_v4",
            "community_provenance": "{}",
            "place_type": "venue",
        })

    print(f"Writing {len(rows)} venues...")

    with open(args.output, "w", newline="", encoding="utf-8") as csvfile:
        writer = csv.DictWriter(csvfile, fieldnames=CSV_COLUMNS)
        writer.writeheader()
        writer.writerows(rows)

    print(f"Done: {args.output}")

if __name__ == "__main__":
    main()
