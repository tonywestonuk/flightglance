#!/usr/bin/env python3
"""
Builds FlightGlance's bundled, offline map and airport data.

Outputs (written to FlightGlance/Resources/Data):
  WorldAtlas.bin  - quantized land / lake / border geometry at two levels of detail
  Cities.json     - major populated places for map labels
  Countries.json  - country names with Natural Earth's label points and zoom ranges
  Regions.json    - island, sea and ocean names with label points and zoom ranges
  Areas.json      - simplified country and ocean/sea outlines, to name what you're flying over
  Towns.json      - ~7,000 towns for "35 km SW of Lyon" style descriptions
  Airports.json   - airports with scheduled passenger service, for manual route entry

Sources (all downloaded on demand into a cache directory):
  * Natural Earth 1:110m and 1:50m vectors (public domain) - https://www.naturalearthdata.com
  * OurAirports airport list (public domain)               - https://ourairports.com/data/
  * mwgg/Airports time zone field (MIT licence)            - https://github.com/mwgg/Airports

Usage:
  python3 Tools/build_atlas_data.py [--cache DIR]

WorldAtlas.bin format (little endian):
  char[4]  magic "FGA1"
  u16      version (1)
  u16      layer count
  per layer:
    u8     kind   (0 = land polygons, 1 = lake polygons, 2 = country border lines)
    u8     lod    (0 = coarse / 1:110m, 1 = detail / 1:50m)
    u32    ring count
    u32[]  point count of each ring
    i16[]  interleaved lon, lat for every point of every ring.
           lon = round(deg / 180 * 32767), lat = round(deg / 90 * 32767)
           (~300 m resolution, far finer than the source scale)
"""

import argparse
import csv
import json
import math
import os
import struct
import sys
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(ROOT, "FlightGlance", "Resources", "Data")

NE_BASE = "https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/"
OURAIRPORTS_URL = "https://davidmegginson.github.io/ourairports-data/airports.csv"
MWGG_URL = "https://raw.githubusercontent.com/mwgg/Airports/master/airports.json"

Q = 32767


def fetch(url, cache):
    path = os.path.join(cache, os.path.basename(url))
    if not os.path.exists(path):
        print(f"  downloading {url}")
        urllib.request.urlretrieve(url, path)
    return path


def load_geojson(name, cache):
    with open(fetch(NE_BASE + name + ".geojson", cache), encoding="utf-8") as f:
        return json.load(f)


def rings_of(geometry):
    """Yields every ring / line string of a (Multi)Polygon or (Multi)LineString."""
    if geometry is None:
        return
    t, c = geometry["type"], geometry["coordinates"]
    if t == "Polygon":
        yield from c
    elif t == "MultiPolygon":
        for poly in c:
            yield from poly
    elif t == "LineString":
        yield c
    elif t == "MultiLineString":
        yield from c


def perpendicular_distance(p, a, b):
    if a == b:
        return math.hypot(p[0] - a[0], p[1] - a[1])
    dx, dy = b[0] - a[0], b[1] - a[1]
    t = ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / (dx * dx + dy * dy)
    t = max(0.0, min(1.0, t))
    return math.hypot(p[0] - (a[0] + t * dx), p[1] - (a[1] + t * dy))


def simplify(points, tolerance):
    """Iterative Douglas-Peucker in degrees. Endpoints are always kept."""
    if tolerance <= 0 or len(points) < 3:
        return points
    keep = [False] * len(points)
    keep[0] = keep[-1] = True
    stack = [(0, len(points) - 1)]
    while stack:
        i, j = stack.pop()
        best, index = 0.0, -1
        for k in range(i + 1, j):
            d = perpendicular_distance(points[k], points[i], points[j])
            if d > best:
                best, index = d, k
        if best > tolerance and index > 0:
            keep[index] = True
            stack.append((i, index))
            stack.append((index, j))
    return [p for p, k in zip(points, keep) if k]


def quantize(ring):
    out = []
    for lon, lat in ring:
        q = (int(round(max(-180, min(180, lon)) / 180 * Q)), int(round(max(-90, min(90, lat)) / 90 * Q)))
        if not out or out[-1] != q:
            out.append(q)
    return out


def build_layer(features, kind, lod, tolerance, closed, min_points):
    rings = []
    for feature in features:
        for ring in rings_of(feature["geometry"]):
            ring = simplify([tuple(p[:2]) for p in ring], tolerance)
            q = quantize(ring)
            if closed and len(q) > 1 and q[0] == q[-1]:
                q = q[:-1]  # the renderer closes rings itself
            if len(q) >= min_points:
                rings.append(q)
    blob = struct.pack("<BBI", kind, lod, len(rings))
    blob += struct.pack(f"<{len(rings)}I", *[len(r) for r in rings])
    flat = [v for r in rings for p in r for v in p]
    blob += struct.pack(f"<{len(flat)}h", *flat)
    print(f"  layer kind={kind} lod={lod}: {len(rings)} rings, {len(flat) // 2} points")
    return blob


def build_atlas(cache):
    print("Building WorldAtlas.bin")
    layers = [
        build_layer(load_geojson("ne_110m_land", cache)["features"], 0, 0, 0.0, True, 3),
        build_layer(load_geojson("ne_50m_land", cache)["features"], 0, 1, 0.02, True, 3),
        build_layer(load_geojson("ne_110m_lakes", cache)["features"], 1, 0, 0.0, True, 3),
        build_layer(
            [f for f in load_geojson("ne_50m_lakes", cache)["features"] if f["properties"].get("scalerank", 9) <= 1],
            1, 1, 0.02, True, 3),
        build_layer(load_geojson("ne_110m_admin_0_boundary_lines_land", cache)["features"], 2, 0, 0.0, False, 2),
        build_layer(load_geojson("ne_50m_admin_0_boundary_lines_land", cache)["features"], 2, 1, 0.02, False, 2),
    ]
    data = b"FGA1" + struct.pack("<HH", 1, len(layers)) + b"".join(layers)
    path = os.path.join(OUT_DIR, "WorldAtlas.bin")
    with open(path, "wb") as f:
        f.write(data)
    print(f"  wrote {path} ({len(data) / 1024:.0f} KB)")


def build_cities(cache):
    print("Building Cities.json")
    features = load_geojson("ne_50m_populated_places_simple", cache)["features"]
    cities = []
    for f in features:
        p = f["properties"]
        if p["featurecla"] in ("Scientific station", "Historic place"):
            continue
        capital = 1 if p["featurecla"].startswith("Admin-0 capital") or p.get("adm0cap") == 1 else 0
        cities.append([
            p["name"], p["adm0name"],
            round(p["latitude"], 3), round(p["longitude"], 3),
            int(p["pop_max"] or 0), round(float(p["min_zoom"]), 1), capital,
        ])
    # Most important first: the renderer places labels greedily in this order.
    cities.sort(key=lambda c: (c[5], -c[6], -c[4]))
    path = os.path.join(OUT_DIR, "Cities.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(cities, f, ensure_ascii=False, separators=(",", ":"))
    print(f"  wrote {path} ({len(cities)} cities, {os.path.getsize(path) / 1024:.0f} KB)")


def build_countries(cache):
    print("Building Countries.json")
    features = load_geojson("ne_50m_admin_0_countries", cache)["features"]
    rename = {"United States of America": "United States"}
    countries = []
    for f in features:
        p = f["properties"]
        name = rename.get(p["NAME"], p["NAME"])
        countries.append([
            name, round(float(p["LABEL_Y"]), 3), round(float(p["LABEL_X"]), 3),
            round(float(p["MIN_LABEL"]), 1), round(float(p["MAX_LABEL"]), 1), int(p["LABELRANK"]),
        ])
    # Most important first, as for cities.
    countries.sort(key=lambda c: (c[3], c[5], c[0]))
    path = os.path.join(OUT_DIR, "Countries.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(countries, f, ensure_ascii=False, separators=(",", ":"))
    print(f"  wrote {path} ({len(countries)} countries, {os.path.getsize(path) / 1024:.0f} KB)")


def ring_area_centroid(ring):
    """Signed area and centroid of a lon/lat ring (planar; fine for label placement)."""
    a = cx = cy = 0.0
    for (x0, y0), (x1, y1) in zip(ring, ring[1:] + ring[:1]):
        cross = x0 * y1 - x1 * y0
        a += cross
        cx += (x0 + x1) * cross
        cy += (y0 + y1) * cross
    a *= 0.5
    if abs(a) < 1e-12:
        return 0.0, ring[0]
    return a, (cx / (6 * a), cy / (6 * a))


def point_in_ring(x, y, ring):
    inside = False
    j = len(ring) - 1
    for i in range(len(ring)):
        xi, yi = ring[i]
        xj, yj = ring[j]
        if (yi > y) != (yj > y) and x < (xj - xi) * (y - yi) / (yj - yi) + xi:
            inside = not inside
        j = i
    return inside


def label_point(geometry):
    """A point inside the largest polygon: its centroid if that is inside, otherwise the
    interior grid point farthest from the outline (a cheap pole of inaccessibility)."""
    polys = [geometry["coordinates"]] if geometry["type"] == "Polygon" else geometry["coordinates"]
    outer = max((p[0] for p in polys), key=lambda r: abs(ring_area_centroid([tuple(q[:2]) for q in r])[0]))
    ring = [tuple(q[:2]) for q in outer]
    _, (cx, cy) = ring_area_centroid(ring)
    if point_in_ring(cx, cy, ring):
        return cy, cx
    xs, ys = [q[0] for q in ring], [q[1] for q in ring]
    best, best_d = (cy, cx), -1
    n = 40
    for i in range(1, n):
        for j in range(1, n):
            x = min(xs) + (max(xs) - min(xs)) * i / n
            y = min(ys) + (max(ys) - min(ys)) * j / n
            if not point_in_ring(x, y, ring):
                continue
            d = min((x - px) ** 2 + (y - py) ** 2 for px, py in ring[::max(1, len(ring) // 400)])
            if d > best_d:
                best, best_d = (y, x), d
    return best


def build_regions(cache):
    print("Building Regions.json")
    country_names = {f["properties"]["NAME"] for f in load_geojson("ne_50m_admin_0_countries", cache)["features"]}
    regions = []
    for f in load_geojson("ne_50m_geography_regions_polys", cache)["features"]:
        p = f["properties"]
        if p["FEATURECLA"] not in ("Island", "Island group") or not f["geometry"]:
            continue
        name = p.get("NAME_EN") or p["NAME"]
        if name in country_names:
            continue  # e.g. Iceland, Madagascar: already labelled as countries
        lat, lon = label_point(f["geometry"])
        regions.append([name, round(lat, 3), round(lon, 3), float(p["MIN_LABEL"]), float(p["MAX_LABEL"] or 99), "island"])
    for f in load_geojson("ne_50m_geography_marine_polys", cache)["features"]:
        p = f["properties"]
        if p["featurecla"] not in ("ocean", "sea") or not f["geometry"] or p.get("min_label") is None:
            continue
        lat, lon = label_point(f["geometry"])
        regions.append([p["name"], round(lat, 3), round(lon, 3), float(p["min_label"]),
                        float(p.get("max_label") or 99), p["featurecla"]])
    regions.sort(key=lambda r: (r[3], r[0]))
    path = os.path.join(OUT_DIR, "Regions.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(regions, f, ensure_ascii=False, separators=(",", ":"))
    print(f"  wrote {path} ({len(regions)} regions, {os.path.getsize(path) / 1024:.0f} KB)")


def build_areas(cache):
    """Country and ocean/sea outlines for "what am I flying over?" lookups. Coarse (1:110m,
    further simplified) because a few kilometres either side of a coastline doesn't matter."""
    print("Building Areas.json")
    areas = []

    def rings(geometry, tolerance):
        polys = [geometry["coordinates"]] if geometry["type"] == "Polygon" else geometry["coordinates"]
        out = []
        for poly in polys:
            for ring in poly:
                ring = simplify([tuple(p[:2]) for p in ring], tolerance)
                if len(ring) >= 4:
                    out.append([round(v, 2) for p in ring for v in p])
        return out

    for f in load_geojson("ne_110m_admin_0_countries", cache)["features"]:
        p = f["properties"]
        name = p.get("NAME_LONG") or p["NAME"]
        areas.append([name, "country", rings(f["geometry"], 0.03)])
    for f in load_geojson("ne_110m_geography_marine_polys", cache)["features"]:
        p = f["properties"]
        name = " ".join(w if w.lower() in ("of", "the", "and") else w.capitalize() for w in p["name"].lower().split())
        kind = "ocean" if p["featurecla"] == "ocean" else "sea"
        areas.append([name, kind, rings(f["geometry"], 0.05)])
    path = os.path.join(OUT_DIR, "Areas.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(areas, f, ensure_ascii=False, separators=(",", ":"))
    print(f"  wrote {path} ({len(areas)} areas, {os.path.getsize(path) / 1024:.0f} KB)")


def build_towns(cache):
    print("Building Towns.json")
    towns = []
    for f in load_geojson("ne_10m_populated_places_simple", cache)["features"]:
        p = f["properties"]
        towns.append([p["name"], round(p["latitude"], 3), round(p["longitude"], 3)])
    path = os.path.join(OUT_DIR, "Towns.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(towns, f, ensure_ascii=False, separators=(",", ":"))
    print(f"  wrote {path} ({len(towns)} towns, {os.path.getsize(path) / 1024:.0f} KB)")


def build_airports(cache):
    print("Building Airports.json")
    with open(fetch(OURAIRPORTS_URL, cache), encoding="utf-8") as f:
        rows = list(csv.DictReader(f))
    with open(fetch(MWGG_URL, cache), encoding="utf-8") as f:
        mwgg = json.load(f)
    tz_by_iata = {v["iata"]: v["tz"] for v in mwgg.values() if v.get("iata")}

    size_rank = {"large_airport": 0, "medium_airport": 1, "small_airport": 2}
    seen = set()
    airports = []
    for r in rows:
        iata = r["iata_code"].strip().upper()
        if not iata or len(iata) != 3 or r["scheduled_service"] != "yes" or r["type"] not in size_rank:
            continue
        if iata in seen:
            continue
        seen.add(iata)
        icao = (r["icao_code"] or r["gps_code"] or "").strip().upper()
        tz = ""
        for key in (icao, r["ident"].strip().upper()):
            if key in mwgg:
                tz = mwgg[key].get("tz", "")
                break
        tz = tz or tz_by_iata.get(iata, "")
        airports.append([
            iata, icao if len(icao) == 4 else "", r["name"].strip(), r["municipality"].strip(), r["iso_country"],
            round(float(r["latitude_deg"]), 4), round(float(r["longitude_deg"]), 4), tz, size_rank[r["type"]],
        ])
    airports.sort(key=lambda a: a[0])
    path = os.path.join(OUT_DIR, "Airports.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(airports, f, ensure_ascii=False, separators=(",", ":"))
    print(f"  wrote {path} ({len(airports)} airports, {os.path.getsize(path) / 1024:.0f} KB)")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--cache", default=os.path.join(ROOT, ".data-cache"), help="download cache directory")
    args = parser.parse_args()
    os.makedirs(args.cache, exist_ok=True)
    os.makedirs(OUT_DIR, exist_ok=True)
    build_atlas(args.cache)
    build_cities(args.cache)
    build_countries(args.cache)
    build_regions(args.cache)
    build_areas(args.cache)
    build_towns(args.cache)
    build_airports(args.cache)


if __name__ == "__main__":
    sys.exit(main())
