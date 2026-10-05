import CoreGraphics
import Foundation
import simd

/// Orthographic projection of the earth as seen from far away: a 3D globe.
///
/// Every map vertex is stored as a unit vector on the sphere. For a view centred on
/// (φ₀, λ₀) we build an orthonormal camera basis
///
///     c = view direction (the point at the centre of the globe)
///     e = local east at c,  n = local north at c
///
/// and project a unit vector v to the screen with two dot products:
///
///     screen.x = origin.x + R · (v·e)
///     screen.y = origin.y − R · (v·n)
///     depth    = v·c        (> 0 faces the viewer, < 0 is behind the globe)
///
/// This is the classic orthographic map projection; it looks like a photographed globe and,
/// zoomed in, like an ordinary local map. North always stays up because the basis has no roll.
struct GlobeProjection {
    let center: SIMD3<Double>
    let east: SIMD3<Double>
    let north: SIMD3<Double>
    /// Globe radius in points.
    let radius: Double
    /// Screen position of the globe's centre.
    let origin: CGPoint

    init(camera: GeoCamera, size: CGSize) {
        let phi = GeoMath.radians(camera.latitude), lambda = GeoMath.radians(camera.longitude)
        center = SIMD3(cos(phi) * cos(lambda), cos(phi) * sin(lambda), sin(phi))
        east = SIMD3(-sin(lambda), cos(lambda), 0)
        north = SIMD3(-sin(phi) * cos(lambda), -sin(phi) * sin(lambda), cos(phi))
        radius = Double(camera.radius)
        origin = CGPoint(x: size.width / 2, y: size.height / 2)
    }

    static func unitVector(latitude: Double, longitude: Double) -> SIMD3<Double> {
        let phi = GeoMath.radians(latitude), lambda = GeoMath.radians(longitude)
        return SIMD3(cos(phi) * cos(lambda), cos(phi) * sin(lambda), sin(phi))
    }

    static func unitVector(_ point: GeoPoint) -> SIMD3<Double> {
        unitVector(latitude: point.latitude, longitude: point.longitude)
    }

    static func geoPoint(_ v: SIMD3<Double>) -> GeoPoint {
        GeoPoint(latitude: GeoMath.degrees(atan2(v.z, sqrt(v.x * v.x + v.y * v.y))),
                 longitude: GeoMath.degrees(atan2(v.y, v.x)))
    }

    @inline(__always) func depth(_ v: SIMD3<Double>) -> Double { simd_dot(v, center) }

    @inline(__always) func screen(_ v: SIMD3<Double>) -> CGPoint {
        CGPoint(x: origin.x + radius * simd_dot(v, east), y: origin.y - radius * simd_dot(v, north))
    }

    func screen(_ point: GeoPoint) -> CGPoint? {
        let v = Self.unitVector(point)
        return depth(v) >= 0 ? screen(v) : nil
    }

    /// Where the chord from `a` to `b` crosses the horizon plane (depth 0), back on the sphere.
    @inline(__always) func horizonCrossing(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
        let za = depth(a), zb = depth(b)
        let t = za / (za - zb)
        return simd_normalize(a + (b - a) * t)
    }

    /// Pushes a point on the far side out to the horizon circle along its screen direction.
    /// Used to close filled shapes that are partly behind the globe (see `GlobeRenderer`).
    @inline(__always) func horizonPoint(towards v: SIMD3<Double>) -> CGPoint {
        let x = simd_dot(v, east), y = simd_dot(v, north)
        let length = (x * x + y * y).squareRoot()
        guard length > 1e-12 else { return CGPoint(x: origin.x + radius, y: origin.y) }
        return CGPoint(x: origin.x + radius * x / length, y: origin.y - radius * y / length)
    }

    /// Inverse projection. Nil for points off the globe's disc.
    func geoPoint(atScreen point: CGPoint) -> GeoPoint? {
        let x = Double(point.x - origin.x) / radius, y = -Double(point.y - origin.y) / radius
        let r2 = x * x + y * y
        guard r2 <= 1 else { return nil }
        return Self.geoPoint(east * x + north * y + center * (1 - r2).squareRoot())
    }

    /// Angular radius (radians) of the part of the globe that can be on screen.
    func visibleAngularRadius(for size: CGSize) -> Double {
        let halfDiagonal = Double(hypot(size.width, size.height)) / 2
        return halfDiagonal >= radius ? .pi / 2 : asin(halfDiagonal / radius)
    }

    /// Screen angle (radians, 0 = right, clockwise positive in screen space) of travel along
    /// `course` from `point`. Derived from a projected point 20 km ahead, so it is correct
    /// anywhere on the globe, including near the limb.
    func headingAngle(at point: GeoPoint, course: Double) -> Double {
        let ahead = GeoMath.destination(from: point, bearing: course, distance: 20_000)
        let a = screen(Self.unitVector(point)), b = screen(Self.unitVector(ahead))
        return atan2(Double(b.y - a.y), Double(b.x - a.x))
    }
}

/// Angle between two unit vectors, robust for tiny and near-180° angles.
@inline(__always) func angleBetween(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
    atan2(simd_length(simd_cross(a, b)), simd_dot(a, b))
}

/// A spherical cap (centre + angular radius) bounding a set of points, for fast culling.
struct SphericalCap: Sendable {
    var center: SIMD3<Double>
    var radius: Double

    init(center: SIMD3<Double>, radius: Double) {
        self.center = center
        self.radius = radius
    }

    init(points: [SIMD3<Double>]) {
        let sum = points.reduce(SIMD3<Double>(repeating: 0), +)
        center = simd_length(sum) > 1e-9 ? simd_normalize(sum) : (points.first ?? SIMD3(1, 0, 0))
        let c = center
        radius = points.reduce(0) { max($0, angleBetween(c, $1)) }
    }

    /// True if any part of the cap could be within `angularRadius` of `direction`.
    func intersects(direction: SIMD3<Double>, angularRadius: Double) -> Bool {
        angleBetween(center, direction) <= angularRadius + radius
    }
}
