#!/bin/zsh
# Downloads the public-domain OurAirports dataset and compacts it to
# Resources/airports.tsv: IATA \t lat \t lon \t ISO country \t city \t airport name
set -euo pipefail
ROOT="${0:A:h:h}"
TMP="$(mktemp -d)"
curl -fsSL https://davidmegginson.github.io/ourairports-data/airports.csv -o "$TMP/airports.csv"
python3 -I - "$TMP/airports.csv" "$ROOT/Resources/airports.tsv" <<'PY'
import csv, sys
src, dst = sys.argv[1], sys.argv[2]
import re, unicodedata
def fold(x):
    return ''.join(c for c in unicodedata.normalize('NFKD', x or '') if not unicodedata.combining(c)).lower()
clean = lambda s: (s or '').replace('\t', ' ').replace('\n', ' ').strip()
GENERIC = re.compile(r"\b(international|intl|regional|municipal|airport|airfield|aerodrome|air base|airpark|field|flughafen|aeroporto|aeropuerto|aéroport|letališče|zračna luka)\b", re.I)

all_rows = list(csv.DictReader(open(src, newline='', encoding='utf-8')))
# every municipality name seen anywhere in the dataset, per country, used to recognise city names
known = {}
for r in all_rows:
    m = clean(r['municipality'])
    if m:
        known.setdefault(r['iso_country'], set()).add(fold(re.sub(r"\s*\(.*?\)", "", m)))

def served_city(r):
    """The city an airport serves: 'Ljubljana' rather than 'Zgornji Brnik'."""
    muni = clean(r['municipality'])
    base = re.sub(r"\s*\(.*?\)", "", muni).strip()
    if '/' in base:
        base = base.split('/')[-1].strip()
    name = clean(r['name'])
    if base and fold(base) in fold(name):
        return base
    # Leading words of the airport name before generic words or a dash, e.g.
    # "Ljubljana Jože Pučnik Airport" -> "Ljubljana", "Washington Dulles International" -> "Washington"
    lead = re.split(r"\s[–—-]\s|[–—]|/|,|\(", name)[0]
    lead = GENERIC.split(lead)[0].strip()
    words = lead.split()
    for n in (3, 2, 1):
        if len(words) >= n:
            cand = ' '.join(words[:n])
            if fold(cand) in known.get(r['iso_country'], ()) and fold(cand) != fold(base):
                return cand
    return base or name

rows = {}
for r in all_rows:
    code = (r['iata_code'] or '').strip().upper()
    if len(code) != 3 or not code.isalpha():
        continue
    if r['type'] not in ('large_airport', 'medium_airport', 'small_airport'):
        continue
    rank = {'large_airport': 3, 'medium_airport': 2, 'small_airport': 1}[r['type']]
    rank += 1 if r['scheduled_service'] == 'yes' else 0
    row = (rank, [code, r['latitude_deg'], r['longitude_deg'], clean(r['iso_country']),
                  served_city(r), clean(r['name'])])
    if code not in rows or rows[code][0] < rank:
        rows[code] = row
with open(dst, 'w', encoding='utf-8') as out:
    for code in sorted(rows):
        out.write('\t'.join(rows[code][1]) + '\n')
print(f"wrote {len(rows)} airports to {dst}")
PY
rm -rf "$TMP"
