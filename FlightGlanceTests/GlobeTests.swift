import CoreGraphics
import Foundation
import simd
import SwiftUI
import Testing
@testable import FlightGlance

@Suite("Globe projection")
struct GlobeProjectionTests {
    let size = CGSize(width: 400, height: 600)

    func projection(latitude: Double = 30, longitude: Double = 10, radius: CGFloat = 150) -> GlobeProjection {
        GlobeProjection(camera: GeoCamera(latitude: latitude, longitude: longitude, radius: radius), size: size)
    }

    @Test func viewCentreIsInTheMiddleFacingTheViewer() {
        let p = projection()
        let v = GlobeProjection.unitVector(latitude: 30, longitude: 10)
        #expect(isClose(p.depth(v), 1, within: 1e-12))
        let s = p.screen(v)
        #expect(isClose(Double(s.x), 200, within: 1e-9) && isClose(Double(s.y), 300, within: 1e-9))
    }

    @Test func northIsUpAndEastIsRight() {
        let p = projection()
        let north = p.screen(GlobeProjection.unitVector(latitude: 40, longitude: 10))
        let east = p.screen(GlobeProjection.unitVector(latitude: 30, longitude: 20))
        #expect(north.y < 300)
        #expect(east.x > 200)
    }

    @Test func horizonAndFarSide() {
        let p = projection(latitude: 0, longitude: 0)
        // 90° away sits on the rim; the antipode is directly behind.
        let rim = GlobeProjection.unitVector(latitude: 0, longitude: 90)
        #expect(isClose(p.depth(rim), 0, within: 1e-12))
        #expect(isClose(Double(p.screen(rim).x), 350, within: 1e-9))
        #expect(isClose(p.depth(GlobeProjection.unitVector(latitude: 0, longitude: 180)), -1, within: 1e-12))
        #expect(p.screen(GeoPoint(latitude: 0, longitude: 120)) == nil)
    }

    @Test func horizonCrossingLiesOnTheRim() {
        let p = projection()
        let front = GlobeProjection.unitVector(latitude: 30, longitude: 10)
        let back = GlobeProjection.unitVector(latitude: -10, longitude: 150)
        let crossing = p.horizonCrossing(front, back)
        #expect(isClose(p.depth(crossing), 0, within: 1e-9))
        #expect(isClose(simd_length(crossing), 1, within: 1e-12))
    }

    @Test(arguments: [CGPoint(x: 200, y: 300), CGPoint(x: 260, y: 250), CGPoint(x: 120, y: 390)])
    func screenRoundTrip(point: CGPoint) throws {
        let p = projection()
        let geo = try #require(p.geoPoint(atScreen: point))
        let back = try #require(p.screen(geo))
        #expect(isClose(Double(back.x), Double(point.x), within: 1e-6))
        #expect(isClose(Double(back.y), Double(point.y), within: 1e-6))
        #expect(p.geoPoint(atScreen: CGPoint(x: 0, y: 0)) == nil) // off the disc
    }

    @Test func framingKeepsTheRouteOnTheVisibleSide() throws {
        let points = GeoMath.greatCirclePath(from: heathrow, to: kennedy)
        let camera = try #require(GeoCamera.framing(points, style: .globe, size: size, padding: EdgeInsets()))
        let p = GlobeProjection(camera: camera, size: size)
        for point in points {
            let s = try #require(p.screen(point), "route point hidden behind the globe")
            #expect(s.x >= -1 && s.x <= size.width + 1 && s.y >= -1 && s.y <= size.height + 1)
        }
    }

    @Test func globePanFollowsTheFinger() {
        // Dragging right by R·(10° in radians) rotates the globe 10° so the view moves west.
        let camera = GeoCamera(latitude: 0, longitude: 0, radius: 300)
        let moved = camera.panned(by: CGSize(width: 300 * GeoMath.radians(10), height: 0), style: .globe, size: size)
        #expect(isClose(moved.longitude, -10, within: 1e-9))
        let clamped = camera.panned(by: CGSize(width: 0, height: 10_000), style: .globe, size: size)
        #expect(clamped.latitude <= 88)
    }
}

@Suite("Globe filling")
struct GlobeFillTests {
    /// A 20°×20° square ring in lon/lat around (lat, lon).
    func square(latitude: Double, longitude: Double) -> WorldAtlas.GlobeRing {
        let corners = [(-10.0, -10.0), (-10, 10), (10, 10), (10, -10)].flatMap { (dLat, dLon) -> [SIMD2<Double>] in
            [SIMD2(longitude + dLon, latitude + dLat)]
        }
        // Densify edges so the ring follows lat/lon lines closely.
        var lonLat: [SIMD2<Double>] = []
        for i in corners.indices {
            let a = corners[i], b = corners[(i + 1) % corners.count]
            for t in stride(from: 0.0, to: 1.0, by: 0.1) { lonLat.append(a + (b - a) * t) }
        }
        let points = lonLat.map { GlobeProjection.unitVector(latitude: $0.y, longitude: $0.x) }
        return WorldAtlas.GlobeRing(points: points, lonLat: lonLat,
                                    bounds: CGRect(x: longitude - 10, y: latitude - 10, width: 20, height: 20),
                                    cap: SphericalCap(points: points), artificial: nil)
    }

    @Test func pointInRingUsesLongitudeLatitude() {
        let ring = square(latitude: 0, longitude: 0)
        #expect(GlobeRenderer.contains(ring, longitude: 0, latitude: 0))
        #expect(GlobeRenderer.contains(ring, longitude: 9, latitude: -9))
        #expect(!GlobeRenderer.contains(ring, longitude: 11, latitude: 0))
        #expect(!GlobeRenderer.contains(ring, longitude: 180, latitude: 0))
    }

    @Test func fullyVisibleShapeIsUnchanged() {
        let renderer = GlobeRenderer(atlas: try! WorldAtlas.loadBundled())
        let projection = GlobeProjection(camera: GeoCamera(latitude: 0, longitude: 0, radius: 200),
                                         size: CGSize(width: 400, height: 400))
        var path = Path()
        let hidden = renderer.appendFill(square(latitude: 0, longitude: 0).points, projection: projection, to: &path)
        #expect(!hidden)
        // The centre of the square is filled.
        #expect(path.contains(CGPoint(x: 200, y: 200)))
    }

    @Test func shapeOverTheHorizonIsClosedAlongTheRim() {
        let renderer = GlobeRenderer(atlas: try! WorldAtlas.loadBundled())
        let projection = GlobeProjection(camera: GeoCamera(latitude: 0, longitude: 0, radius: 200),
                                         size: CGSize(width: 400, height: 400))
        var path = Path()
        // Straddles the eastern limb (90°E).
        let hidden = renderer.appendFill(square(latitude: 0, longitude: 90).points, projection: projection, to: &path)
        #expect(hidden)
        let bounds = path.boundingRect
        // Nothing is drawn outside the globe's disc, and the visible part reaches the rim.
        #expect(bounds.maxX <= 400.5)
        #expect(bounds.maxX >= 399)
        #expect(path.contains(CGPoint(x: 396, y: 200)))
        #expect(!path.contains(CGPoint(x: 300, y: 200)))
    }
}
