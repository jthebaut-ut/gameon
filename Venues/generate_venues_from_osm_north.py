import requests
import pandas as pd
import time
import re
import hashlib

OVERPASS_URL = "https://overpass-api.de/api/interpreter"

# =========================================================
# CONFIG
# =========================================================

COUNTRY = "France"

OUTPUT_FILE = "venues_france_osm_v5.csv"

# North France focus
AREAS = [
    "Lille",
    "Lens",
    "Arras",
    "Douai",
    "Valenciennes",
    "Dunkerque",
    "Calais",
    "Boulogne-sur-Mer",
    "Béthune",
    "Saint-Omer",
    "Amiens",
    "Roubaix",
    "Tourcoing",
    "Cambrai",
    "Le Touquet",
]

# =========================================================
# VENUE TAGS
# =========================================================

SPORT_KEYWORDS = [
    "sports",
    "sport",
    "football",
    "soccer",
    "rugby",
    "basketball",
    "f1",
    "formula",
    "tennis",
    "bar sportif",
    "sports bar",
    "watch",
    "pub",
    "fan",
]

# =========================================================
# HELPERS
# =========================================================

def normalize_text(value):
    if value is None:
        return ""

    value = str(value).strip()

    value = re.sub(r"\s+", " ", value)

    return value


def build_identity_key(name, city, country):
    raw = f"{name.lower()}|{city.lower()}|{country.lower()}"
    return hashlib.sha256(raw.encode()).hexdigest()[:24]


def looks_like_sports_venue(name, tags):
    combined = f"{name} {' '.join(tags.values())}".lower()

    for keyword in SPORT_KEYWORDS:
        if keyword in combined:
            return True

    return False


# =========================================================
# OVERPASS QUERY
# =========================================================

def build_query(city):

    return f"""
    [out:json][timeout:120];

    area["name"="{city}"]->.searchArea;

    (
      node(area.searchArea)["amenity"~"bar|pub|cafe|restaurant|biergarten"];
      way(area.searchArea)["amenity"~"bar|pub|cafe|restaurant|biergarten"];
      relation(area.searchArea)["amenity"~"bar|pub|cafe|restaurant|biergarten"];
    );

    out center tags;
    """


# =========================================================
# MAIN
# =========================================================

all_rows = []

seen_keys = set()

for city in AREAS:

    print(f"\nFetching venues for {city}...")

    query = build_query(city)

    response = requests.post(
        OVERPASS_URL,
        data=query,
        headers={"Content-Type": "text/plain"},
    )

    data = response.json()

    elements = data.get("elements", [])

    print(f"Found {len(elements)} raw elements")

    for element in elements:

        tags = element.get("tags", {})

        name = normalize_text(tags.get("name"))

        if not name:
            continue

        if not looks_like_sports_venue(name, tags):
            continue

        lat = element.get("lat")
        lon = element.get("lon")

        if lat is None or lon is None:
            center = element.get("center", {})
            lat = center.get("lat")
            lon = center.get("lon")

        if lat is None or lon is None:
            continue

        address = normalize_text(
            f"{tags.get('addr:housenumber', '')} "
            f"{tags.get('addr:street', '')}"
        )

        website = normalize_text(tags.get("website"))

        phone = normalize_text(tags.get("phone"))

        state = "Hauts-de-France"

        dedupe_key = (
            name.lower(),
            round(float(lat), 4),
            round(float(lon), 4),
        )

        if dedupe_key in seen_keys:
            continue

        seen_keys.add(dedupe_key)

        identity_key = build_identity_key(
            name=name,
            city=city,
            country=COUNTRY,
        )

        row = {
            "name": name,
            "display_name": name,
            "country": COUNTRY,
            "state": state,
            "city": city,
            "address": address,
            "latitude": lat,
            "longitude": lon,
            "phone": phone,
            "website": website,
            "community_type": "sports_bar",
            "origin_source": "osm",
            "venue_identity_key": identity_key,
            "admin_status": "active",
            "is_seeded": True,
        }

        all_rows.append(row)

    time.sleep(2)

# =========================================================
# EXPORT
# =========================================================

df = pd.DataFrame(all_rows)

df = df.drop_duplicates(
    subset=["venue_identity_key"]
)

df = df.sort_values(
    by=["country", "city", "name"]
)

print("\n=================================================")
print(f"FINAL VENUES: {len(df)}")
print("=================================================\n")

df.to_csv(OUTPUT_FILE, index=False)

print(f"Saved to {OUTPUT_FILE}")
