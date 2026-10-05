import CoreGraphics
import Foundation
import Testing
@testable import FlightGlance

let heathrow = GeoPoint(latitude: 51.4707, longitude: -0.4599)
let kennedy = GeoPoint(latitude: 40.6413, longitude: -73.7781)
let sanFrancisco = GeoPoint(latitude: 37.6190, longitude: -122.3750)
let narita = GeoPoint(latitude: 35.7647, longitude: 140.3864)
let sydney = GeoPoint(latitude: -33.9461, longitude: 151.1772)
let losAngeles = GeoPoint(latitude: 33.9425, longitude: -118.4081)

func isClose(_ a: Double, _ b: Double, within tolerance: Double) -> Bool { abs(a - b) <= tolerance }

@Suite("Great-circle math")
struct GeoMathTests {
    @Test func distanceMatchesKnownRoute() {
        // LHR–JFK is about 5,540 km on a spherical earth.
        let km = GeoMath.distance(heathrow, kennedy) / 1000
        #expect(isClose(km, 5_540, within: 20))
        #expect(GeoMath.distance(heathrow, heathrow) == 0)
        #expect(isClose(GeoMath.distance(heathrow, kennedy), GeoMath.distance(kennedy, heathrow), within: 1e-6))
    }

    @Test func initialBearingHeadsNorthWestFromLondonToNewYork() {
        let bearing = GeoMath.initialBearing(from: heathrow, to: kennedy)
        #expect(isClose(bearing, 288.5, within: 1.5))
        #expect(isClose(GeoMath.initialBearing(from: GeoPoint(latitude: 0, longitude: 0),
                                               to: GeoPoint(latitude: 10, longitude: 0)), 0, within: 1e-9))
    }

    @Test func destinationRoundTripsWithDistanceAndBearing() {
        let target = GeoMath.destination(from: heathrow, bearing: 123, distance: 750_000)
        #expect(isClose(GeoMath.distance(heathrow, target), 750_000, within: 1))
        #expect(isClose(GeoMath.initialBearing(from: heathrow, to: target), 123, within: 0.01))
    }

    @Test func interpolationStaysOnTheGreatCircle() {
        let start = GeoMath.interpolate(from: heathrow, to: kennedy, fraction: 0)
        let end = GeoMath.interpolate(from: heathrow, to: kennedy, fraction: 1)
        let mid = GeoMath.interpolate(from: heathrow, to: kennedy, fraction: 0.5)
        #expect(GeoMath.distance(start, heathrow) < 1)
        #expect(GeoMath.distance(end, kennedy) < 1)
        #expect(isClose(GeoMath.distance(heathrow, mid), GeoMath.distance(mid, kennedy), within: 1))
        // The great circle bulges north of both endpoints' latitudes.
        #expect(mid.latitude > heathrow.latitude)
    }

    @Test func longitudeHelpers() {
        #expect(GeoMath.normalizedLongitude(190) == -170)
        #expect(GeoMath.normalizedLongitude(-190) == 170)
        #expect(GeoMath.normalizedLongitude(180) == -180)
        #expect(GeoMath.unwrap(-179, near: 179) == 181)
        #expect(GeoMath.unwrap(179, near: -179) == -181)
        #expect(GeoMath.unwrap(10, near: 0) == 10)
    }

    @Test func pathAcrossTheDateLineIsContinuous() {
        let path = GeoMath.greatCirclePath(from: sanFrancisco, to: narita)
        #expect(path.count > 16)
        for (a, b) in zip(path, path.dropFirst()) {
            #expect(abs(b.longitude - a.longitude) < 10, "consecutive points must not jump across ±180°")
        }
        // Unwrapped westward from -122°, Narita lands at 140.4° − 360°.
        #expect(isClose(path.last!.longitude, narita.longitude - 360, within: 1e-6))
        #expect(isClose(path.first!.longitude, sanFrancisco.longitude, within: 1e-9))
    }

    @Test func pathAcrossTheDateLineSouthernHemisphere() {
        let path = GeoMath.greatCirclePath(from: sydney, to: losAngeles)
        for (a, b) in zip(path, path.dropFirst()) {
            #expect(abs(b.longitude - a.longitude) < 10)
        }
        #expect(isClose(path.last!.longitude, losAngeles.longitude + 360, within: 1e-6))
    }

    @Test func shortRoutesStillGetASmoothPath() {
        let nearby = GeoMath.destination(from: heathrow, bearing: 90, distance: 5_000)
        #expect(GeoMath.greatCirclePath(from: heathrow, to: nearby).count == 17)
    }

    @Test func routeProgressAlongTrack() {
        #expect(isClose(GeoMath.routeProgress(of: heathrow, from: heathrow, to: kennedy), 0, within: 1e-9))
        #expect(isClose(GeoMath.routeProgress(of: kennedy, from: heathrow, to: kennedy), 1, within: 1e-6))
        let mid = GeoMath.interpolate(from: heathrow, to: kennedy, fraction: 0.4)
        #expect(isClose(GeoMath.routeProgress(of: mid, from: heathrow, to: kennedy), 0.4, within: 1e-6))
        // 100 km off to the side of the 40 % point is still about 40 % along.
        let offTrack = GeoMath.destination(from: mid, bearing: GeoMath.initialBearing(from: mid, to: kennedy) + 90,
                                           distance: 100_000)
        #expect(isClose(GeoMath.routeProgress(of: offTrack, from: heathrow, to: kennedy), 0.4, within: 0.01))
        // Behind the origin clamps to zero.
        let behind = GeoMath.destination(from: heathrow, bearing: 108, distance: 200_000)
        #expect(GeoMath.routeProgress(of: behind, from: heathrow, to: kennedy) == 0)
    }
}
