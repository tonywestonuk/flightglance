import Foundation
import Testing
@testable import FlightGlance

@Suite("Bundled data")
struct BundledDataTests {
    @Test func atlasLoadsBothLevelsOfDetail() throws {
        let atlas = try WorldAtlas.loadBundled()
        for detail in [WorldAtlas.Detail.coarse, .detailed] {
            #expect((atlas.land[detail]?.buckets.count ?? 0) > 0)
            #expect((atlas.borders[detail]?.buckets.count ?? 0) > 0)
            #expect((atlas.lakes[detail]?.buckets.count ?? 0) > 0)
        }
        #expect(atlas.cities.count > 1_000)
        #expect(atlas.cities.contains { $0.name == "London" && $0.isCapital })
        // Sorted for greedy label placement.
        #expect(zip(atlas.cities, atlas.cities.dropFirst()).allSatisfy { $0.minZoom <= $1.minZoom })
    }

    @Test func antimeridianCutsAreNotCoastline() {
        let edge = AtlasDecoder.RawPoint(qlon: 32_767, qlat: 1_000)
        let edge2 = AtlasDecoder.RawPoint(qlon: 32_767, qlat: 2_000)
        let pole = AtlasDecoder.RawPoint(qlon: 100, qlat: -32_767)
        let pole2 = AtlasDecoder.RawPoint(qlon: 200, qlat: -32_767)
        let coast = AtlasDecoder.RawPoint(qlon: 100, qlat: 100)
        #expect(WorldAtlas.isArtificialEdge(edge, edge2))
        #expect(WorldAtlas.isArtificialEdge(pole, pole2))
        #expect(!WorldAtlas.isArtificialEdge(coast, edge))
    }

    @Test func corruptAtlasDataIsRejected() {
        #expect(throws: AtlasDecoder.DecodeError.self) { try AtlasDecoder.decode(Data("nope".utf8)) }
        #expect(throws: AtlasDecoder.DecodeError.self) {
            try AtlasDecoder.decode(Data("FGA1".utf8) + Data([1, 0, 1, 0, 0, 0, 9, 0, 0, 0]))
        }
    }

    @Test func airportSearch() throws {
        let airports = try AirportDatabase.loadBundled()
        #expect(airports.airports.count > 3_000)
        #expect(airports.search("LHR").first?.iata == "LHR")
        #expect(airports.search("lhr").first?.iata == "LHR")
        #expect(airports.search("EGLL").first?.iata == "LHR")
        #expect(airports.search("heathrow").contains { $0.iata == "LHR" })
        #expect(airports.search("zurich").contains { $0.iata == "ZRH" })   // diacritic-insensitive
        #expect(airports.search("São Paulo").contains { $0.iata == "GRU" })
        #expect(airports.search("   ").isEmpty)
        #expect(airports.airport(code: "jfk")?.timeZone?.identifier == "America/New_York")
    }

    @Test func nearestAirport() throws {
        let airports = try AirportDatabase.loadBundled()
        let nearHeathrow = GeoMath.destination(from: heathrow, bearing: 45, distance: 2_000)
        #expect(airports.nearest(to: nearHeathrow).first?.iata == "LHR")
        // Mid-Atlantic: nothing within range.
        #expect(airports.nearest(to: GeoPoint(latitude: 45, longitude: -35)).isEmpty)
    }
}

@Suite("Formatting")
struct ReadingFormatterTests {
    @Test func course() {
        #expect(ReadingFormatter.course(5).value == "005°")
        #expect(ReadingFormatter.course(359.6).value == "000°")
        #expect(ReadingFormatter.course(271).unit == "W")
        #expect(ReadingFormatter.course(44).unit == "NE")
    }

    @Test func durations() {
        #expect(ReadingFormatter.duration(20).value == "< 1")
        #expect(ReadingFormatter.duration(14 * 60).value == "14")
        #expect(ReadingFormatter.duration(14 * 60).unit == "min")
        #expect(ReadingFormatter.duration(2 * 3600 + 5 * 60).value == "2h 05m")
        #expect(ReadingFormatter.duration(-30).value == "< 1")
    }

    @Test func unitsConvert() {
        #expect(ReadingFormatter.speed(257.222, units: .aviation).unit == "kt")
        #expect(ReadingFormatter.speed(257.222, units: .aviation).value.filter(\.isNumber) == "500")
        #expect(ReadingFormatter.speed(100, units: .metric).value == "360")
        #expect(ReadingFormatter.altitude(10_668, units: .aviation).value.filter(\.isNumber) == "35000")
        #expect(ReadingFormatter.distance(1_852, units: .aviation).value == "1.0")
    }
}

@Suite("Map labels")
struct MapLabelTests {
    let atlas = try! WorldAtlas.loadBundled()

    func plan(_ zoom: CGFloat) -> [MapLabelPlanner.Placement] {
        atlas.labelPlanner.placements(atlas: atlas, webZoom: zoom, bias: 1.3, textSize: .large, airports: [])
    }

    @Test func labelSetDependsOnlyOnTheZoomStep() {
        // Anywhere within one zoom step (and wherever the map points) the labels are the same.
        #expect(plan(2.05).map(\.index) == plan(2.45).map(\.index))
        // Zooming in reveals more cities.
        let world = plan(2).filter { $0.kind == .city }, region = plan(5).filter { $0.kind == .city }
        #expect(region.count > world.count)
        // Big countries are named at world scale.
        let countries = plan(2).filter { $0.kind == .country }.map { atlas.countries[$0.index].name }
        #expect(countries.contains("Brazil") && countries.contains("Russia"))
        #expect(!countries.contains("Luxembourg"))
        // ...and stay named all the way in (Natural Earth's max label zoom is ignored).
        for zoom in [CGFloat(3), 5, 7.2] {
            let names = plan(zoom).filter { $0.kind == .country }.map { atlas.countries[$0.index].name }
            #expect(names.contains("Greece"), "Greece missing at zoom \(zoom)")
        }
        // Islands and seas are labelled too.
        let regions = plan(5).filter { $0.kind == .island || $0.kind == .sea }.map { atlas.regions[$0.index].name }
        #expect(regions.contains("Sicily") && regions.contains("Mediterranean Sea"))
    }

    @Test(arguments: [CGFloat(1.5), 2.5, 4, 6])
    func plannedLabelsDoNotOverlapOnTheMap(zoom: CGFloat) {
        // Draw the plan on the flat map at the bottom of its zoom step and check every pair.
        let scale = 256 * pow(2, zoom) / (2 * .pi)
        let rects = plan(zoom).map { placement -> CGRect in
            let world = atlas.labelPoint(placement.kind, placement.index).world
            return placement.rect.offsetBy(dx: world.x * scale, dy: -world.y * scale)
        }
        #expect(!rects.isEmpty)
        for i in rects.indices {
            for j in rects.indices where j > i {
                #expect(!rects[i].insetBy(dx: 1, dy: 1).intersects(rects[j].insetBy(dx: 1, dy: 1)),
                        "labels \(i) and \(j) overlap at zoom \(zoom)")
            }
        }
    }
}

@Suite("Place finder")
struct PlaceFinderTests {
    let places = try! PlaceFinder.loadBundled()

    @Test func namesTheCountryOrSeaBelow() {
        #expect(places.describe(GeoPoint(latitude: 48.86, longitude: 2.35), units: .metric).region == "Over France")
        #expect(places.describe(GeoPoint(latitude: 52.5, longitude: -1.5), units: .metric).region == "Over the United Kingdom")
        #expect(places.describe(GeoPoint(latitude: 39.0, longitude: -98.0), units: .metric).region == "Over the United States")
        #expect(places.describe(GeoPoint(latitude: 45.0, longitude: -35.0), units: .metric).region == "Over the North Atlantic Ocean")
        #expect(places.describe(GeoPoint(latitude: 35.0, longitude: 18.0), units: .metric).region == "Over the Mediterranean Sea")
        #expect(places.describe(GeoPoint(latitude: 37.5, longitude: 14.2), units: .metric).region == "Over Italy") // Sicily
    }

    @Test func describesTheNearestTown() throws {
        // 30 km due south-west of Lyon.
        let lyon = GeoPoint(latitude: 45.76, longitude: 4.84)
        let point = GeoMath.destination(from: lyon, bearing: 225, distance: 30_000)
        let town = try #require(places.nearestTown(to: point))
        let description = places.describe(point, units: .metric).nearestTown ?? ""
        // Described relative to whichever town is actually nearest, with distance and direction.
        let from = GeoPoint(latitude: town.town.latitude, longitude: town.town.longitude)
        let direction = PlaceFinder.compassPoint(GeoMath.initialBearing(from: from, to: point))
        #expect(description.hasSuffix("km \(direction) of \(town.town.name)"), "\(description)")
        #expect(town.distance < 40_000)
        #expect(places.describe(lyon, units: .metric).nearestTown?.hasPrefix("Near") == true)
    }

    @Test func compassPoints() {
        #expect(PlaceFinder.compassPoint(0) == "N")
        #expect(PlaceFinder.compassPoint(359) == "N")
        #expect(PlaceFinder.compassPoint(225) == "SW")
        #expect(PlaceFinder.compassPoint(100) == "E")
    }
}
