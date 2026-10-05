import Foundation

/// Offline "where am I?" for the Lock Screen: which country or ocean you're over, and the
/// nearest town with distance and direction ("35 km SW of Lyon").
///
/// Uses simplified Natural Earth 1:110m outlines (`Areas.json`) and ~7,300 towns
/// (`Towns.json`). Coastlines are coarse, so within a few kilometres of a coast the answer
/// may name the sea rather than the country, which is fine for a glance.
final class PlaceFinder: Sendable {
    struct Area: Sendable {
        enum Kind: Sendable { case country, sea, ocean }
        let name: String
        let kind: Kind
        /// Rings of (longitude, latitude); holes are just more rings (even-odd rule).
        let rings: [[SIMD2<Double>]]
        let minLon: Double, maxLon: Double, minLat: Double, maxLat: Double
    }

    struct Town: Sendable {
        let name: String
        let latitude: Double
        let longitude: Double
    }

    struct Description: Equatable, Sendable {
        /// "Over France", "Over the North Atlantic Ocean".
        var region: String
        /// "35 km SW of Lyon", "Near Lyon".
        var nearestTown: String?
    }

    let areas: [Area]
    let towns: [Town]

    init(areas: [Area], towns: [Town]) {
        // Seas before oceans, so the more specific water body wins where they overlap.
        self.areas = areas.sorted { rank($0.kind) < rank($1.kind) }
        self.towns = towns
        func rank(_ kind: Area.Kind) -> Int {
            switch kind {
            case .country: 0
            case .sea: 1
            case .ocean: 2
            }
        }
    }

    static func loadBundled(from bundle: Bundle = .main) throws -> PlaceFinder {
        guard let areasURL = bundle.url(forResource: "Areas", withExtension: "json"),
              let townsURL = bundle.url(forResource: "Towns", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try PlaceFinder(areasJSON: Data(contentsOf: areasURL), townsJSON: Data(contentsOf: townsURL))
    }

    convenience init(areasJSON: Data, townsJSON: Data) throws {
        // Areas: [name, "country" | "sea" | "ocean", [[lon, lat, lon, lat, ...], ...]]
        struct AreaRow: Decodable {
            let name: String
            let kind: String
            let rings: [[Double]]
            init(from decoder: Decoder) throws {
                var container = try decoder.unkeyedContainer()
                name = try container.decode(String.self)
                kind = try container.decode(String.self)
                rings = try container.decode([[Double]].self)
            }
        }
        let areas = try JSONDecoder().decode([AreaRow].self, from: areasJSON).map { row -> Area in
            let rings = row.rings.map { flat in
                stride(from: 0, to: flat.count - 1, by: 2).map { SIMD2(flat[$0], flat[$0 + 1]) }
            }
            let all = rings.flatMap { $0 }
            let kind: Area.Kind = row.kind == "country" ? .country : row.kind == "ocean" ? .ocean : .sea
            return Area(name: row.name, kind: kind, rings: rings,
                        minLon: all.map(\.x).min() ?? 0, maxLon: all.map(\.x).max() ?? 0,
                        minLat: all.map(\.y).min() ?? 0, maxLat: all.map(\.y).max() ?? 0)
        }
        let towns = try JSONDecoder().decode([[JSONScalar]].self, from: townsJSON).compactMap { row -> Town? in
            guard row.count >= 3, let name = row[0].string, let lat = row[1].double, let lon = row[2].double else {
                return nil
            }
            return Town(name: name, latitude: lat, longitude: lon)
        }
        self.init(areas: areas, towns: towns)
    }

    // MARK: Lookup

    func area(at point: GeoPoint) -> Area? {
        let lon = GeoMath.normalizedLongitude(point.longitude), lat = point.latitude
        return areas.first { area in
            lon >= area.minLon && lon <= area.maxLon && lat >= area.minLat && lat <= area.maxLat
                && Self.contains(area.rings, lon: lon, lat: lat)
        }
    }

    func nearestTown(to point: GeoPoint) -> (town: Town, distance: Double)? {
        // Cheap equirectangular distance to shortlist, exact great-circle for the winner.
        let cosLat = cos(GeoMath.radians(point.latitude))
        var best: Town?
        var bestScore = Double.infinity
        for town in towns {
            let dLat = town.latitude - point.latitude
            let dLon = GeoMath.normalizedLongitude(town.longitude - point.longitude) * cosLat
            let score = dLat * dLat + dLon * dLon
            if score < bestScore { bestScore = score; best = town }
        }
        guard let best else { return nil }
        return (best, GeoMath.distance(point, GeoPoint(latitude: best.latitude, longitude: best.longitude)))
    }

    func describe(_ point: GeoPoint, units: UnitSystem) -> Description {
        let region: String
        if let area = area(at: point) {
            region = "Over " + Self.withArticle(area)
        } else {
            region = "Over the ocean"
        }
        var town: String?
        if let nearest = nearestTown(to: point) {
            if nearest.distance < 5_000 {
                town = "Near \(nearest.town.name)"
            } else {
                let from = GeoPoint(latitude: nearest.town.latitude, longitude: nearest.town.longitude)
                let direction = Self.compassPoint(GeoMath.initialBearing(from: from, to: point))
                let distance = ReadingFormatter.distance(nearest.distance, units: units).joined
                town = "\(distance) \(direction) of \(nearest.town.name)"
            }
        }
        return Description(region: region, nearestTown: town)
    }

    // MARK: Helpers

    static func contains(_ rings: [[SIMD2<Double>]], lon: Double, lat: Double) -> Bool {
        var inside = false
        for ring in rings {
            var j = ring.count - 1
            for i in ring.indices {
                let a = ring[i], b = ring[j]
                if (a.y > lat) != (b.y > lat), lon < (b.x - a.x) * (lat - a.y) / (b.y - a.y) + a.x {
                    inside.toggle()
                }
                j = i
            }
        }
        return inside
    }

    /// "France", "the United Kingdom", "the North Atlantic Ocean".
    static func withArticle(_ area: Area) -> String {
        guard area.kind == .country else { return "the \(area.name)" }
        let needsThe = ["Republic", "United", "Islands", "Kingdom", "States", "Emirates", "Netherlands",
                        "Philippines", "Bahamas", "Gambia", "Maldives"]
        return needsThe.contains(where: area.name.contains) ? "the \(area.name)" : area.name
    }

    static func compassPoint(_ bearing: Double) -> String {
        let points = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        return points[Int((bearing / 45).rounded()) % 8]
    }
}
