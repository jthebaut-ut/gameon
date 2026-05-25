
import argparse
import csv
import time
import requests

OVERPASS_URLS = [
    "https://overpass-api.de/api/interpreter",
    "https://overpass.kumi.systems/api/interpreter",
]

STATE_AREAS = {
    "AL": "Alabama",
    "AK": "Alaska",
    "AZ": "Arizona",
    "AR": "Arkansas",
    "CA": "California",
    "CO": "Colorado",
    "CT": "Connecticut",
    "DE": "Delaware",
    "FL": "Florida",
    "GA": "Georgia",
    "HI": "Hawaii",
    "ID": "Idaho",
    "IL": "Illinois",
    "IN": "Indiana",
    "IA": "Iowa",
    "KS": "Kansas",
    "KY": "Kentucky",
    "LA": "Louisiana",
    "ME": "Maine",
    "MD": "Maryland",
    "MA": "Massachusetts",
    "MI": "Michigan",
    "MN": "Minnesota",
    "MS": "Mississippi",
    "MO": "Missouri",
    "MT": "Montana",
    "NE": "Nebraska",
    "NV": "Nevada",
    "NH": "New Hampshire",
    "NJ": "New Jersey",
    "NM": "New Mexico",
    "NY": "New York",
    "NC": "North Carolina",
    "ND": "North Dakota",
    "OH": "Ohio",
    "OK": "Oklahoma",
    "OR": "Oregon",
    "PA": "Pennsylvania",
    "RI": "Rhode Island",
    "SC": "South Carolina",
    "SD": "South Dakota",
    "TN": "Tennessee",
    "TX": "Texas",
    "UT": "Utah",
    "VT": "Vermont",
    "VA": "Virginia",
    "WA": "Washington",
    "WV": "West Virginia",
    "WI": "Wisconsin",
    "WY": "Wyoming",
    "DC": "District of Columbia",
    "PR": "Puerto Rico",
    "GU": "Guam",
    "VI": "U.S. Virgin Islands",
}
SPORT_MAP = {
    "soccer": "soccer",
    "basketball": "basketball",
    "football": "american_football",
    "tennis": "tennis",
    "pickleball": "pickleball",
    "baseball": "baseball",
    "softball": "softball",
    "golf": "golf",
}

FIELDNAMES = [
    "name",
    "sport",
    "place_type",
    "latitude",
    "longitude",
    "address",
    "city",
    "state",
    "zip",
    "indoor",
    "outdoor",
    "verified",
    "source",
]

def build_query(state_name, osm_sport):
    return f"""
[out:json][timeout:180];
area["boundary"="administrative"]["admin_level"="4"]["name"="{state_name}"]->.searchArea;
(
  node["leisure"="pitch"]["sport"="{osm_sport}"](area.searchArea);
  way["leisure"="pitch"]["sport"="{osm_sport}"](area.searchArea);
  relation["leisure"="pitch"]["sport"="{osm_sport}"](area.searchArea);

  node["leisure"="sports_centre"]["sport"="{osm_sport}"](area.searchArea);
  way["leisure"="sports_centre"]["sport"="{osm_sport}"](area.searchArea);
  relation["leisure"="sports_centre"]["sport"="{osm_sport}"](area.searchArea);

  node["sport"="{osm_sport}"]["name"](area.searchArea);
  way["sport"="{osm_sport}"]["name"](area.searchArea);
  relation["sport"="{osm_sport}"]["name"](area.searchArea);
);
out center tags;
"""

def fetch_elements(query):
    last_error = None

    for url in OVERPASS_URLS:
        try:
            print(f"Querying {url} ...")
            response = requests.post(
                url,
                data={"data": query},
                headers={
                    "User-Agent": "FanGeoPickupPlacesImporter/1.0 (contact: support@fangeosports.com)"
                },
                timeout=240,
            )

            if response.status_code != 200:
                print(f"Overpass status={response.status_code}")
                print(response.text[:500])

            response.raise_for_status()
            return response.json().get("elements", [])
        except Exception as exc:
            last_error = exc
            print(f"Overpass failed on {url}: {exc}")
            time.sleep(3)

    raise last_error

def bool_from_tags(tags, key):
    value = str(tags.get(key, "")).strip().lower()
    return value in {"yes", "true", "1"}

def row_from_element(el, app_sport, state):
    tags = el.get("tags", {}) or {}

    lat = el.get("lat")
    lon = el.get("lon")

    if lat is None or lon is None:
        center = el.get("center", {}) or {}
        lat = center.get("lat")
        lon = center.get("lon")

    if lat is None or lon is None:
        return None

    name = (
        tags.get("name")
        or tags.get("operator")
        or tags.get("official_name")
    )

    if not name:
        return None

    street_parts = [
        tags.get("addr:housenumber", ""),
        tags.get("addr:street", ""),
    ]
    address = " ".join([p for p in street_parts if p]).strip()

    place_type = tags.get("leisure") or tags.get("amenity") or "pitch"

    location = str(tags.get("location", "")).lower()
    covered = str(tags.get("covered", "")).lower()
    indoor = bool_from_tags(tags, "indoor") or location == "indoor" or covered == "yes"

    return {
        "name": name,
        "sport": app_sport,
        "place_type": place_type,
        "latitude": lat,
        "longitude": lon,
        "address": address,
        "city": tags.get("addr:city", ""),
        "state": state,
        "zip": tags.get("addr:postcode", ""),
        "indoor": str(indoor).lower(),
        "outdoor": str(not indoor).lower(),
        "verified": "false",
        "source": "openstreetmap",
    }

def normalize_key(row):
    return (
        row["name"].strip().lower(),
        round(float(row["latitude"]), 5),
        round(float(row["longitude"]), 5),
    )

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--sport", required=True)
    parser.add_argument("--state", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    state = args.state.upper().strip()
    app_sport = args.sport.lower().strip()

    if state not in STATE_AREAS:
        raise SystemExit(f"Unsupported state: {state}")

    if app_sport not in SPORT_MAP:
        raise SystemExit(f"Unsupported sport: {app_sport}")

    query = build_query(STATE_AREAS[state], SPORT_MAP[app_sport])
    elements = fetch_elements(query)

    rows = []
    seen = set()

    for el in elements:
        row = row_from_element(el, app_sport, state)
        if not row:
            continue

        key = normalize_key(row)
        if key in seen:
            continue

        seen.add(key)
        rows.append(row)

    rows.sort(key=lambda r: (r["city"] or "", r["name"] or ""))

    with open(args.output, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=FIELDNAMES)
        writer.writeheader()
        writer.writerows(rows)

    print(f"Exported {len(rows)} rows to {args.output}")

if __name__ == "__main__":
    main()

