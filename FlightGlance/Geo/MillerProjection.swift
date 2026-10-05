import CoreGraphics
import Foundation

/// Miller cylindrical projection, used for every map in the app.
///
///     x = λ                                (longitude, radians)
///     y = 1.25 · ln(tan(π/4 + 0.4·φ))      (latitude φ, radians; north is +y)
///
/// Why Miller:
/// * It is *cylindrical*: meridians are vertical and parallels horizontal, so the world
///   repeats seamlessly left-to-right. The map can pan forever east/west and a route that
///   crosses the antimeridian is just a line drawn across two adjacent world copies.
/// * Mid-latitudes look much like the familiar Web Mercator, but the poles are at a finite
///   y (±2.3034), so polar and high-latitude flights can still be drawn, which Mercator
///   (infinite at the poles) cannot do.
/// * Like any cylindrical projection, great circles appear as curves. That is expected: the
///   curved reference line *is* the shortest path on the globe.
///
/// World units are radians, so the full world is `2π` wide and `2 · maxY` tall.
enum MillerProjection {
    /// Projected y of the poles.
    static let maxY: CGFloat = forwardY(latitude: 90)
    static let worldWidth: CGFloat = 2 * .pi
    static var worldHeight: CGFloat { 2 * maxY }

    /// The projected world for longitudes -180°...180°.
    static var worldRect: CGRect {
        CGRect(x: -.pi, y: -maxY, width: worldWidth, height: worldHeight)
    }

    static func forwardY(latitude: Double) -> CGFloat {
        let phi = GeoMath.radians(min(90, max(-90, latitude)))
        return CGFloat(1.25 * log(tan(.pi / 4 + 0.4 * phi)))
    }

    /// Projects a coordinate. Longitudes outside ±180° (from unwrapping) are preserved, which
    /// keeps unwrapped lines continuous in world space.
    static func project(_ point: GeoPoint) -> CGPoint {
        CGPoint(x: CGFloat(GeoMath.radians(point.longitude)), y: forwardY(latitude: point.latitude))
    }

    static func project(latitude: Double, longitude: Double) -> CGPoint {
        project(GeoPoint(latitude: latitude, longitude: longitude))
    }

    /// Inverse projection: φ = 2.5 · atan(e^(0.8·y)) − 0.625π.
    static func unproject(_ point: CGPoint) -> GeoPoint {
        let y = Double(min(maxY, max(-maxY, point.y)))
        let latitude = GeoMath.degrees(2.5 * atan(exp(0.8 * y)) - 0.625 * .pi)
        return GeoPoint(latitude: latitude, longitude: GeoMath.degrees(Double(point.x)))
    }
}
