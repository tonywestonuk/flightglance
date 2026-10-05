import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import FlightGlance

@Suite("Miller projection")
struct MillerProjectionTests {
    @Test func equatorAndPrimeMeridianAreTheOrigin() {
        let origin = MillerProjection.project(latitude: 0, longitude: 0)
        #expect(abs(origin.x) < 1e-12 && abs(origin.y) < 1e-12)
        #expect(isClose(Double(MillerProjection.project(latitude: 0, longitude: 180).x), .pi, within: 1e-12))
        #expect(isClose(Double(MillerProjection.project(latitude: 0, longitude: -90).x), -.pi / 2, within: 1e-12))
    }

    @Test func matchesTheMillerFormula() {
        // y = 1.25 · ln(tan(π/4 + 0.4φ)); at 45° that is ≈ 0.8427.
        #expect(isClose(Double(MillerProjection.forwardY(latitude: 45)), 0.842_7, within: 1e-3))
        #expect(isClose(Double(MillerProjection.forwardY(latitude: -45)), -0.842_7, within: 1e-3))
    }

    @Test func polesAreFinite() {
        #expect(MillerProjection.maxY.isFinite)
        #expect(isClose(Double(MillerProjection.maxY), 2.303_4, within: 1e-3))
        #expect(MillerProjection.forwardY(latitude: 90) == MillerProjection.maxY)
        #expect(isClose(Double(MillerProjection.forwardY(latitude: -90)), -Double(MillerProjection.maxY), within: 1e-12))
    }

    @Test(arguments: [(-89.0, -179.0), (-45.5, 12.25), (0.0, 0.0), (37.6, -122.4), (51.47, -0.46), (89.9, 179.9)])
    func roundTrips(latitude: Double, longitude: Double) {
        let back = MillerProjection.unproject(MillerProjection.project(latitude: latitude, longitude: longitude))
        #expect(isClose(back.latitude, latitude, within: 1e-9))
        #expect(isClose(back.longitude, longitude, within: 1e-9))
    }

    @Test func latitudeIsMonotonic() {
        var previous = -CGFloat.infinity
        for latitude in stride(from: -90.0, through: 90.0, by: 0.5) {
            let y = MillerProjection.forwardY(latitude: latitude)
            #expect(y > previous)
            previous = y
        }
    }

    @Test func unwrappedLongitudesStayContinuousInWorldSpace() {
        let route = GeoMath.greatCirclePath(from: sanFrancisco, to: narita).map(MillerProjection.project)
        for (a, b) in zip(route, route.dropFirst()) {
            #expect(abs(b.x - a.x) < 0.2)
        }
    }
}

@Suite("Map camera")
struct MapCameraTests {
    let size = CGSize(width: 390, height: 500)

    @Test func screenAndWorldRoundTrip() {
        let camera = MapCamera(center: CGPoint(x: 1.2, y: 0.7), scale: 300)
        let world = CGPoint(x: 1.0, y: 0.9)
        let back = camera.screenToWorld(camera.worldToScreen(world, in: size), in: size)
        #expect(isClose(Double(back.x), 1.0, within: 1e-9))
        #expect(isClose(Double(back.y), 0.9, within: 1e-9))
        let center = camera.worldToScreen(camera.center, in: size)
        #expect(center == CGPoint(x: 195, y: 250))
        // North is up: a larger world y is higher on screen.
        #expect(camera.worldToScreen(CGPoint(x: 1.2, y: 1.0), in: size).y < 250)
    }

    @Test func transformMatchesWorldToScreen() {
        let camera = MapCamera(center: CGPoint(x: -2.5, y: 0.3), scale: 180)
        let world = CGPoint(x: -2.4, y: 0.1)
        let viaTransform = world.applying(camera.transform(in: size))
        let direct = camera.worldToScreen(world, in: size)
        #expect(isClose(Double(viaTransform.x), Double(direct.x), within: 1e-9))
        #expect(isClose(Double(viaTransform.y), Double(direct.y), within: 1e-9))
        // A world copy one revolution east is drawn 2π·scale points to the right.
        let shifted = world.applying(camera.transform(in: size, worldOffset: MillerProjection.worldWidth))
        #expect(isClose(Double(shifted.x - direct.x), Double(MillerProjection.worldWidth * camera.scale), within: 1e-6))
    }

    @Test func zoomKeepsTheAnchorFixed() {
        let camera = MapCamera(center: CGPoint(x: 0.3, y: 0.4), scale: 200)
        let anchor = CGPoint(x: 80, y: 120)
        let before = camera.screenToWorld(anchor, in: size)
        let zoomed = camera.zoomed(by: 2.5, anchor: anchor, in: size)
        let after = zoomed.screenToWorld(anchor, in: size)
        #expect(isClose(Double(zoomed.scale), 500, within: 1e-9))
        #expect(isClose(Double(before.x), Double(after.x), within: 1e-9))
        #expect(isClose(Double(before.y), Double(after.y), within: 1e-9))
    }

    @Test func clampingLimitsZoomAndPoles() {
        let tooFar = MapCamera(center: .zero, scale: 1).clamped(to: size)
        #expect(tooFar.scale == MapCamera.minimumScale(for: size))
        let tooClose = MapCamera(center: .zero, scale: 1_000_000).clamped(to: size)
        #expect(tooClose.scale == MapCamera.maximumScale(for: size))

        // Can't scroll past the north pole.
        let north = MapCamera(center: CGPoint(x: 0, y: 10), scale: 400).clamped(to: size)
        let top = north.visibleWorldRect(in: size).maxY
        #expect(isClose(Double(top), Double(MillerProjection.maxY), within: 1e-9))

        // When the whole world is shorter than the view it is centred vertically.
        let wide = MapCamera(center: CGPoint(x: 0, y: 1), scale: MapCamera.minimumScale(for: size)).clamped(to: size)
        #expect(wide.center.y == 0)
    }

    @Test func worldCopiesCoverTheDateLine() {
        // Centred on the antimeridian: both the copy at 0 and the one shifted east are needed.
        let camera = MapCamera(center: CGPoint(x: CGFloat.pi, y: 0), scale: 150)
        let offsets = camera.worldCopyOffsets(for: MillerProjection.worldRect, in: size)
        #expect(offsets.contains(0))
        #expect(offsets.contains(MillerProjection.worldWidth))
        // Far from it, one copy suffices.
        let europe = MapCamera(center: CGPoint(x: 0.2, y: 0.8), scale: 800)
        #expect(europe.worldCopyOffsets(for: MillerProjection.worldRect, in: size) == [0])
    }

    @Test func fittingShowsTheWholeRect() {
        let rect = CGRect(x: -1.3, y: 0.5, width: 1.2, height: 0.4)
        let padding = EdgeInsets(top: 80, leading: 20, bottom: 30, trailing: 60)
        let camera = MapCamera.fitting(rect, in: size, padding: padding)
        let topLeft = camera.worldToScreen(CGPoint(x: rect.minX, y: rect.maxY), in: size)
        let bottomRight = camera.worldToScreen(CGPoint(x: rect.maxX, y: rect.minY), in: size)
        #expect(topLeft.x >= padding.leading - 0.5)
        #expect(topLeft.y >= padding.top - 0.5)
        #expect(bottomRight.x <= size.width - padding.trailing + 0.5)
        #expect(bottomRight.y <= size.height - padding.bottom + 0.5)
    }

    @Test func normalizingDoesNotMoveTheMap() {
        let camera = MapCamera(center: CGPoint(x: 9.0, y: 0.2), scale: 300)
        let normalized = camera.normalized()
        #expect(normalized.center.x >= -.pi && normalized.center.x < .pi)
        let delta = (camera.center.x - normalized.center.x) / MillerProjection.worldWidth
        #expect(isClose(Double(delta), Double(delta.rounded()), within: 1e-9))
    }
}
