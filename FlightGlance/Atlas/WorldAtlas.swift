import CoreGraphics
import Foundation
import simd
import SwiftUI

/// The bundled offline world map: Natural Earth land, lakes, country borders, country names
/// and cities.
///
/// Geometry is decoded once, projected into Miller world units and turned into `Path`s up
/// front, so drawing a frame is just filling/stroking cached paths through a transform.
/// Paths are grouped into spatial buckets so zoomed-in frames skip everything off screen.
final class WorldAtlas: @unchecked Sendable {
    // @unchecked: every stored property is an immutable value after init.

    enum Detail: Int, Sendable {
        /// Natural Earth 1:110m — used for the zoomed-out world view.
        case coarse = 0
        /// Natural Earth 1:50m — used once zoomed in to a region.
        case detailed = 1
    }

    /// A group of nearby features drawn together.
    struct Bucket {
        /// World-space bounds of everything in the bucket (for culling).
        let bounds: CGRect
        /// Closed rings, for filling (land, lakes).
        let fill: Path
        /// Lines to stroke: coastlines (land with the artificial antimeridian / south-pole
        /// cut edges removed), lake shores, or borders.
        let stroke: Path
    }

    struct Layer {
        let buckets: [Bucket]
    }

    /// One ring / line for the globe: unit vectors on the sphere plus the original
    /// longitude/latitude (needed to decide which side of a cut-off shape is "inside").
    struct GlobeRing {
        let points: [SIMD3<Double>]
        let lonLat: [SIMD2<Double>]
        /// Longitude/latitude bounds in degrees (x = longitude, y = latitude).
        let bounds: CGRect
        let cap: SphericalCap
        /// For land: true where segment i → i+1 is an antimeridian / south-pole cut, not coast.
        let artificial: [Bool]?
    }

    struct GlobeBucket {
        let cap: SphericalCap
        let rings: [GlobeRing]
    }

    struct GlobeLayer {
        let buckets: [GlobeBucket]
    }

    struct City: Sendable {
        let name: String
        let country: String
        let world: CGPoint
        let unit: SIMD3<Double>
        /// Radians.
        let latitude: Double
        /// Radians.
        let longitude: Double
        let population: Int
        /// Natural Earth's suggested minimum web-map zoom for the label.
        let minZoom: Double
        let isCapital: Bool
    }

    /// A country name and where Natural Earth suggests placing it.
    struct Country: Sendable {
        let name: String
        let world: CGPoint
        let unit: SIMD3<Double>
        /// Radians.
        let latitude: Double
        /// Radians.
        let longitude: Double
        /// Natural Earth's web zoom from which the name should be shown.
        let minZoom: Double
    }

    /// An island, sea or ocean name.
    struct Region: Sendable {
        let name: String
        let kind: MapLabelPlanner.Kind
        let world: CGPoint
        let unit: SIMD3<Double>
        /// Radians.
        let latitude: Double
        /// Radians.
        let longitude: Double
        let minZoom: Double
    }

    let land: [Detail: Layer]
    let lakes: [Detail: Layer]
    let borders: [Detail: Layer]
    let globeLand: [Detail: GlobeLayer]
    let globeLakes: [Detail: GlobeLayer]
    let globeBorders: [Detail: GlobeLayer]
    /// Ordered most-important first (the label planner relies on this).
    let cities: [City]
    /// Ordered most-important first.
    let countries: [Country]
    /// Islands, seas and oceans, ordered most-important first.
    let regions: [Region]
    /// Chooses (and caches) which places are labelled at each zoom step.
    let labelPlanner = MapLabelPlanner()

    private init(flat: [Int: [Detail: Layer]], globe: [Int: [Detail: GlobeLayer]], cities: [City],
                 countries: [Country], regions: [Region]) {
        land = flat[0] ?? [:]
        lakes = flat[1] ?? [:]
        borders = flat[2] ?? [:]
        globeLand = globe[0] ?? [:]
        globeLakes = globe[1] ?? [:]
        globeBorders = globe[2] ?? [:]
        self.cities = cities
        self.countries = countries
        self.regions = regions
    }

    /// Name and position of a labelled place.
    func labelPoint(_ kind: MapLabelPlanner.Kind, _ index: Int) -> (name: String, unit: SIMD3<Double>, world: CGPoint) {
        switch kind {
        case .country: (countries[index].name, countries[index].unit, countries[index].world)
        case .city: (cities[index].name, cities[index].unit, cities[index].world)
        case .ocean, .sea, .island: (regions[index].name, regions[index].unit, regions[index].world)
        }
    }

    static func loadBundled(from bundle: Bundle = .main) throws -> WorldAtlas {
        guard let geometryURL = bundle.url(forResource: "WorldAtlas", withExtension: "bin"),
              let citiesURL = bundle.url(forResource: "Cities", withExtension: "json"),
              let countriesURL = bundle.url(forResource: "Countries", withExtension: "json"),
              let regionsURL = bundle.url(forResource: "Regions", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try WorldAtlas(geometry: Data(contentsOf: geometryURL), cities: Data(contentsOf: citiesURL),
                              countries: Data(contentsOf: countriesURL), regions: Data(contentsOf: regionsURL))
    }

    convenience init(geometry: Data, cities citiesJSON: Data, countries countriesJSON: Data,
                     regions regionsJSON: Data) throws {
        let layers = try AtlasDecoder.decode(geometry)
        var flat: [Int: [Detail: Layer]] = [:]
        var globe: [Int: [Detail: GlobeLayer]] = [:]
        for layer in layers {
            guard let detail = Detail(rawValue: Int(layer.lod)), layer.kind <= 2 else { continue }
            let kind = Int(layer.kind)
            let closed = kind != 2
            let built = Self.buildLayer(layer, closed: closed, skipArtificialEdges: kind == 0)
            flat[kind, default: [:]][detail] = built.flat
            globe[kind, default: [:]][detail] = built.globe
        }
        let rows = try JSONDecoder().decode([[JSONScalar]].self, from: citiesJSON)
        let cities = rows.compactMap { row -> City? in
            guard row.count >= 7, let name = row[0].string, let lat = row[2].double, let lon = row[3].double else {
                return nil
            }
            return City(name: name, country: row[1].string ?? "",
                        world: MillerProjection.project(latitude: lat, longitude: lon),
                        unit: GlobeProjection.unitVector(latitude: lat, longitude: lon),
                        latitude: GeoMath.radians(lat), longitude: GeoMath.radians(lon),
                        population: Int(row[4].double ?? 0), minZoom: row[5].double ?? 9,
                        isCapital: (row[6].double ?? 0) > 0)
        }
        // Rows are [name, label latitude, label longitude, min zoom, max zoom, label rank].
        let countryRows = try JSONDecoder().decode([[JSONScalar]].self, from: countriesJSON)
        let countries = countryRows.compactMap { row -> Country? in
            guard row.count >= 5, let name = row[0].string, let lat = row[1].double, let lon = row[2].double else {
                return nil
            }
            return Country(name: name, world: MillerProjection.project(latitude: lat, longitude: lon),
                           unit: GlobeProjection.unitVector(latitude: lat, longitude: lon),
                           latitude: GeoMath.radians(lat), longitude: GeoMath.radians(lon),
                           minZoom: row[3].double ?? 9)
        }
        // Rows are [name, latitude, longitude, min zoom, max zoom, "island" | "sea" | "ocean"].
        let regionRows = try JSONDecoder().decode([[JSONScalar]].self, from: regionsJSON)
        let regions = regionRows.compactMap { row -> Region? in
            guard row.count >= 6, let name = row[0].string, let lat = row[1].double, let lon = row[2].double else {
                return nil
            }
            let kind: MapLabelPlanner.Kind = switch row[5].string {
            case "ocean": .ocean
            case "sea": .sea
            default: .island
            }
            return Region(name: name, kind: kind, world: MillerProjection.project(latitude: lat, longitude: lon),
                          unit: GlobeProjection.unitVector(latitude: lat, longitude: lon),
                          latitude: GeoMath.radians(lat), longitude: GeoMath.radians(lon),
                          minZoom: row[3].double ?? 9)
        }
        self.init(flat: flat, globe: globe, cities: cities, countries: countries, regions: regions)
    }

    // MARK: Building

    /// Bucket size in degrees. Big enough that the coarse world is a handful of draw calls,
    /// small enough that a zoomed-in view touches only a few buckets.
    private static let bucketDegrees = 30

    private static func buildLayer(_ layer: AtlasDecoder.RawLayer, closed: Bool,
                                   skipArtificialEdges: Bool) -> (flat: Layer, globe: GlobeLayer) {
        struct Accumulator {
            var bounds = CGRect.null
            var fill = Path()
            var stroke = Path()
            var rings: [GlobeRing] = []
        }
        var grid: [Int: Accumulator] = [:]

        for ring in layer.rings {
            guard ring.count >= 2 else { continue }
            let projected = ring.map { MillerProjection.project(latitude: $0.latitude, longitude: $0.longitude) }
            var bounds = CGRect.null
            for point in projected { bounds = bounds.union(CGRect(origin: point, size: .zero)) }

            // Assign the ring to the bucket containing its centre.
            let center = MillerProjection.unproject(CGPoint(x: bounds.midX, y: bounds.midY))
            let column = Int((center.longitude + 180) / Double(bucketDegrees))
            let row = Int((center.latitude + 90) / Double(bucketDegrees))
            var bucket = grid[row * 100 + column] ?? Accumulator()
            bucket.bounds = bucket.bounds.union(bounds)

            if closed {
                bucket.fill.addLines(projected)
                bucket.fill.closeSubpath()
            }
            appendStroke(ring: ring, projected: projected, closed: closed,
                         skipArtificialEdges: skipArtificialEdges, to: &bucket.stroke)
            bucket.rings.append(globeRing(ring, closed: closed, skipArtificialEdges: skipArtificialEdges))
            grid[row * 100 + column] = bucket
        }
        let flat = Layer(buckets: grid.values.map { Bucket(bounds: $0.bounds, fill: $0.fill, stroke: $0.stroke) })
        let globe = GlobeLayer(buckets: grid.values.map { bucket in
            GlobeBucket(cap: SphericalCap(points: bucket.rings.flatMap(\.points)), rings: bucket.rings)
        })
        return (flat, globe)
    }

    private static func globeRing(_ ring: [AtlasDecoder.RawPoint], closed: Bool, skipArtificialEdges: Bool) -> GlobeRing {
        let lonLat = ring.map { SIMD2($0.longitude, $0.latitude) }
        let points = lonLat.map { GlobeProjection.unitVector(latitude: $0.y, longitude: $0.x) }
        var minLon = Double.infinity, maxLon = -Double.infinity, minLat = Double.infinity, maxLat = -Double.infinity
        for p in lonLat {
            minLon = min(minLon, p.x); maxLon = max(maxLon, p.x)
            minLat = min(minLat, p.y); maxLat = max(maxLat, p.y)
        }
        var artificial: [Bool]?
        if skipArtificialEdges {
            artificial = ring.indices.map { isArtificialEdge(ring[$0], ring[($0 + 1) % ring.count]) }
        }
        return GlobeRing(points: points, lonLat: lonLat,
                         bounds: CGRect(x: minLon, y: minLat, width: maxLon - minLon, height: maxLat - minLat),
                         cap: SphericalCap(points: points), artificial: artificial)
    }

    /// Natural Earth land polygons are cut along the antimeridian (±180°) and Antarctica is
    /// closed along the bottom of the map (-90°). Those edges are not coastline, so the
    /// coastline stroke lifts the pen over them while the fill still uses the full ring.
    private static func appendStroke(ring: [AtlasDecoder.RawPoint], projected: [CGPoint], closed: Bool,
                                     skipArtificialEdges: Bool, to path: inout Path) {
        let count = ring.count
        let segmentCount = closed ? count : count - 1
        var penDown = false
        for index in 0..<segmentCount {
            let next = (index + 1) % count
            if skipArtificialEdges && isArtificialEdge(ring[index], ring[next]) {
                penDown = false
                continue
            }
            if !penDown {
                path.move(to: projected[index])
                penDown = true
            }
            path.addLine(to: projected[next])
        }
    }

    static func isArtificialEdge(_ a: AtlasDecoder.RawPoint, _ b: AtlasDecoder.RawPoint) -> Bool {
        let q = AtlasDecoder.quantizationMax
        let onAntimeridian = abs(Int(a.qlon)) == q && a.qlon == b.qlon
        let onSouthPole = Int(a.qlat) == -q && Int(b.qlat) == -q
        return onAntimeridian || onSouthPole
    }
}

/// Decodes the compact binary format written by `Tools/build_atlas_data.py`.
enum AtlasDecoder {
    static let quantizationMax = 32_767

    struct RawPoint {
        let qlon: Int16
        let qlat: Int16
        var longitude: Double { Double(qlon) / Double(quantizationMax) * 180 }
        var latitude: Double { Double(qlat) / Double(quantizationMax) * 90 }
    }

    struct RawLayer {
        let kind: UInt8
        let lod: UInt8
        let rings: [[RawPoint]]
    }

    enum DecodeError: Error {
        case badMagic, truncated
    }

    static func decode(_ data: Data) throws -> [RawLayer] {
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> [RawLayer] in
            var offset = 0
            func read<T: FixedWidthInteger>(_: T.Type) throws -> T {
                guard offset + MemoryLayout<T>.size <= buffer.count else { throw DecodeError.truncated }
                let value = buffer.loadUnaligned(fromByteOffset: offset, as: T.self)
                offset += MemoryLayout<T>.size
                return T(littleEndian: value)
            }
            guard buffer.count >= 8,
                  buffer[0] == UInt8(ascii: "F"), buffer[1] == UInt8(ascii: "G"),
                  buffer[2] == UInt8(ascii: "A"), buffer[3] == UInt8(ascii: "1") else {
                throw DecodeError.badMagic
            }
            offset = 4
            _ = try read(UInt16.self) // version
            let layerCount = Int(try read(UInt16.self))
            var layers: [RawLayer] = []
            for _ in 0..<layerCount {
                let kind = try read(UInt8.self)
                let lod = try read(UInt8.self)
                let ringCount = Int(try read(UInt32.self))
                var counts: [Int] = []
                counts.reserveCapacity(ringCount)
                for _ in 0..<ringCount { counts.append(Int(try read(UInt32.self))) }
                var rings: [[RawPoint]] = []
                rings.reserveCapacity(ringCount)
                for count in counts {
                    var ring: [RawPoint] = []
                    ring.reserveCapacity(count)
                    for _ in 0..<count {
                        let lon = try read(Int16.self)
                        let lat = try read(Int16.self)
                        ring.append(RawPoint(qlon: lon, qlat: lat))
                    }
                    rings.append(ring)
                }
                layers.append(RawLayer(kind: kind, lod: lod, rings: rings))
            }
            return layers
        }
    }
}
