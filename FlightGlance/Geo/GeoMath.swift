import Foundation

/// A geographic position in degrees (WGS-84). Kept independent of Core Location so the
/// geometry code is a plain, `Sendable`, easily tested value type.
struct GeoPoint: Hashable, Codable, Sendable {
    var latitude: Double
    var longitude: Double

    init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// Spherical-earth great-circle helpers.
///
/// A spherical model (mean radius 6,371 km) is accurate to roughly 0.5 % against the WGS-84
/// ellipsoid, which is well inside the uncertainty of an arrival *estimate* and far simpler
/// than Vincenty's formulae.
enum GeoMath {
    static let earthRadius: Double = 6_371_008.8

    static func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }
    static func degrees(_ radians: Double) -> Double { radians * 180 / .pi }

    /// Wraps any longitude into [-180, 180).
    static func normalizedLongitude(_ longitude: Double) -> Double {
        var value = (longitude + 180).truncatingRemainder(dividingBy: 360)
        if value < 0 { value += 360 }
        return value - 180
    }

    /// Great-circle distance in metres (haversine form, numerically stable for short hops).
    static func distance(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        let phi1 = radians(a.latitude), phi2 = radians(b.latitude)
        let dPhi = phi2 - phi1
        let dLambda = radians(b.longitude - a.longitude)
        let h = sin(dPhi / 2) * sin(dPhi / 2) + cos(phi1) * cos(phi2) * sin(dLambda / 2) * sin(dLambda / 2)
        return 2 * earthRadius * atan2(sqrt(h), sqrt(max(0, 1 - h)))
    }

    /// Initial true bearing (degrees, 0..<360) of the great circle from `a` towards `b`.
    static func initialBearing(from a: GeoPoint, to b: GeoPoint) -> Double {
        let phi1 = radians(a.latitude), phi2 = radians(b.latitude)
        let dLambda = radians(b.longitude - a.longitude)
        let y = sin(dLambda) * cos(phi2)
        let x = cos(phi1) * sin(phi2) - sin(phi1) * cos(phi2) * cos(dLambda)
        let bearing = degrees(atan2(y, x))
        return (bearing + 360).truncatingRemainder(dividingBy: 360)
    }

    /// The point reached by travelling `distance` metres from `start` on initial `bearing`.
    static func destination(from start: GeoPoint, bearing: Double, distance: Double) -> GeoPoint {
        let delta = distance / earthRadius
        let theta = radians(bearing)
        let phi1 = radians(start.latitude), lambda1 = radians(start.longitude)
        let sinPhi2 = sin(phi1) * cos(delta) + cos(phi1) * sin(delta) * cos(theta)
        let phi2 = asin(min(1, max(-1, sinPhi2)))
        let y = sin(theta) * sin(delta) * cos(phi1)
        let x = cos(delta) - sin(phi1) * sinPhi2
        let lambda2 = lambda1 + atan2(y, x)
        return GeoPoint(latitude: degrees(phi2), longitude: normalizedLongitude(degrees(lambda2)))
    }

    /// Point at `fraction` (0...1) of the way along the great circle from `a` to `b`.
    ///
    /// Uses spherical linear interpolation of the two unit vectors, which stays on the
    /// great circle (unlike interpolating latitude/longitude, which would trace a rhumb-ish
    /// path that looks plausible on a map but is not the shortest route).
    static func interpolate(from a: GeoPoint, to b: GeoPoint, fraction: Double) -> GeoPoint {
        let delta = distance(a, b) / earthRadius
        guard delta > 1e-12 else { return a }
        let phi1 = radians(a.latitude), lambda1 = radians(a.longitude)
        let phi2 = radians(b.latitude), lambda2 = radians(b.longitude)
        let wa = sin((1 - fraction) * delta) / sin(delta)
        let wb = sin(fraction * delta) / sin(delta)
        let x = wa * cos(phi1) * cos(lambda1) + wb * cos(phi2) * cos(lambda2)
        let y = wa * cos(phi1) * sin(lambda1) + wb * cos(phi2) * sin(lambda2)
        let z = wa * sin(phi1) + wb * sin(phi2)
        return GeoPoint(latitude: degrees(atan2(z, sqrt(x * x + y * y))), longitude: degrees(atan2(y, x)))
    }

    /// Samples the great circle between two airports.
    ///
    /// The segment count scales with distance (about one vertex per 50 km, at least 16) so
    /// the curve looks smooth at any zoom without wasting vertices on short hops.
    /// Longitudes in the result are *unwrapped* (see `unwrapLongitudes`), so a route that
    /// crosses the antimeridian is one continuous line rather than two pieces at ±180°.
    static func greatCirclePath(from a: GeoPoint, to b: GeoPoint, maxSegmentLength: Double = 50_000) -> [GeoPoint] {
        let total = distance(a, b)
        let segments = max(16, min(1024, Int((total / maxSegmentLength).rounded(.up))))
        let points = (0...segments).map { interpolate(from: a, to: b, fraction: Double($0) / Double(segments)) }
        return unwrapLongitudes(points, startingNear: a.longitude)
    }

    /// Rewrites longitudes so consecutive points never jump by more than 180°.
    ///
    /// e.g. 179°, -179° becomes 179°, 181°. Drawing the unwrapped sequence on a horizontally
    /// repeating (cylindrical) map produces a continuous line across the date line.
    /// `reference` chooses which 360° "copy" the first point lands in.
    static func unwrapLongitudes(_ points: [GeoPoint], startingNear reference: Double? = nil) -> [GeoPoint] {
        guard let first = points.first else { return [] }
        var result: [GeoPoint] = []
        result.reserveCapacity(points.count)
        var previous = unwrap(first.longitude, near: reference ?? first.longitude)
        result.append(GeoPoint(latitude: first.latitude, longitude: previous))
        for point in points.dropFirst() {
            previous = unwrap(point.longitude, near: previous)
            result.append(GeoPoint(latitude: point.latitude, longitude: previous))
        }
        return result
    }

    /// Returns the equivalent of `longitude` (± k·360°) closest to `reference`.
    static func unwrap(_ longitude: Double, near reference: Double) -> Double {
        longitude + 360 * ((reference - longitude) / 360).rounded()
    }

    /// Signed along-track distance (metres) of `point` projected onto the great circle from
    /// `origin` towards `destination`. Negative means "behind" the origin.
    static func alongTrackDistance(of point: GeoPoint, from origin: GeoPoint, to destination: GeoPoint) -> Double {
        let delta13 = distance(origin, point) / earthRadius
        guard delta13 > 1e-12 else { return 0 }
        let theta13 = radians(initialBearing(from: origin, to: point))
        let theta12 = radians(initialBearing(from: origin, to: destination))
        let crossTrack = asin(min(1, max(-1, sin(delta13) * sin(theta13 - theta12))))
        let ratio = cos(delta13) / max(cos(crossTrack), 1e-12)
        let along = acos(min(1, max(-1, ratio)))
        return (cos(theta13 - theta12) < 0 ? -along : along) * earthRadius
    }

    /// Fraction (0...1) of the reference great-circle route completed at `point`.
    static func routeProgress(of point: GeoPoint, from origin: GeoPoint, to destination: GeoPoint) -> Double {
        let total = distance(origin, destination)
        guard total > 1 else { return 1 }
        return min(1, max(0, alongTrackDistance(of: point, from: origin, to: destination) / total))
    }
}
