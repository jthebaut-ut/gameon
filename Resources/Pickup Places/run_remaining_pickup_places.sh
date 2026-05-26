#!/usr/bin/env bash

SPORTS=("soccer" "basketball" "tennis" "pickleball" "football" "baseball")

STATES=(
"AL:alabama"
"AK:alaska"
"AZ:arizona"
"AR:arkansas"
"CA:california"
"CO:colorado"
"CT:connecticut"
"DE:delaware"
"FL:florida"
"GA:georgia"
"HI:hawaii"
"ID:idaho"
"IL:illinois"
"IN:indiana"
"IA:iowa"
"KS:kansas"
"KY:kentucky"
"LA:louisiana"
"ME:maine"
"MD:maryland"
"MA:massachusetts"
"MI:michigan"
"MN:minnesota"
"MS:mississippi"
"MO:missouri"
"MT:montana"
"NE:nebraska"
"NV:nevada"
"NH:new_hampshire"
"NJ:new_jersey"
"NM:new_mexico"
"NY:new_york"
"NC:north_carolina"
"ND:north_dakota"
"OH:ohio"
"OK:oklahoma"
"OR:oregon"
"PA:pennsylvania"
"RI:rhode_island"
"SC:south_carolina"
"SD:south_dakota"
"TN:tennessee"
"TX:texas"
"UT:utah"
"VT:vermont"
"VA:virginia"
"WA:washington"
"WV:west_virginia"
"WI:wisconsin"
"WY:wyoming"
"DC:washington_dc"
"PR:puerto_rico"
"GU:guam"
"VI:us_virgin_islands"
)

for entry in "${STATES[@]}"; do

  code="${entry%%:*}"
  slug="${entry##*:}"

  for sport in "${SPORTS[@]}"; do

    output="pickup_places_${sport}_${slug}.csv"

    echo ""
    echo "==========================================="
    echo "Generating: ${sport} - ${code}"
    echo "Output: ${output}"
    echo "==========================================="

    python3 generate_pickup_places_from_osm.py \
      --sport "$sport" \
      --state "$code" \
      --output "$output"

    sleep 1

  done

done

echo ""
echo "==========================================="
echo "DONE GENERATING ALL PICKUP PLACE CSV FILES"
echo "==========================================="

