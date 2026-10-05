import CoreGraphics
import SwiftUI

/// How the world is drawn.
enum MapStyle: String, CaseIterable, Identifiable, Sendable {
    /// Orthographic 3D globe (default).
    case globe
    /// Flat Miller cylindrical map.
    case flat

    var id: String { rawValue }

    var title: String {
        switch self {
        case .globe: "Globe"
        case .flat: "Flat Map"
        }
    }

    var symbol: String {
        switch self {
        case .globe: "globe.americas.fill"
        case .flat: "map"
        }
    }
}

/// A map viewpoint shared by both styles: what is in the middle and how far zoomed in.
///
/// `radius` is screen points per radian at the centre of the view, which is literally the
/// globe's radius on screen, and equals the flat map's `MapCamera.scale`. Keeping one camera
/// lets the user switch styles without losing their place, and lets SwiftUI animate camera
/// moves the same way for both.
struct GeoCamera: Equatable, Sendable {
    var latitude: Double
    /// Unbounded (not wrapped to ±180°) so animations take the short way round.
    var longitude: Double
    var radius: CGFloat

    var center: GeoPoint { GeoPoint(latitude: latitude, longitude: longitude) }

    /// Web-map style zoom level (world circumference = 256 · 2^z points), for label density.
    var webZoomLevel: CGFloat {
        log2(max(1, 2 * .pi * radius) / 256)
    }

    // MARK: Flat bridge

    var flatCamera: MapCamera {
        MapCamera(center: MillerProjection.project(latitude: latitude, longitude: longitude), scale: radius)
    }

    init(latitude: Double, longitude: Double, radius: CGFloat) {
        self.latitude = latitude
        self.longitude = longitude
        self.radius = radius
    }

    init(flat camera: MapCamera) {
        let center = MillerProjection.unproject(camera.center)
        self.init(latitude: center.latitude, longitude: center.longitude, radius: camera.scale)
    }

    // MARK: Limits

    static func minimumRadius(style: MapStyle, size: CGSize) -> CGFloat {
        switch style {
        case .globe: max(40, min(size.width, size.height) * 0.42)
        case .flat: MapCamera.minimumScale(for: size)
        }
    }

    static func maximumRadius(style: MapStyle, size: CGSize) -> CGFloat {
        max(minimumRadius(style: style, size: size), MapCamera.maximumScale(for: size))
    }

    func clamped(style: MapStyle, size: CGSize) -> GeoCamera {
        guard size.width > 1, size.height > 1 else { return self }
        switch style {
        case .flat:
            var result = GeoCamera(flat: flatCamera.clamped(to: size))
            result.longitude = longitude
            return result
        case .globe:
            var result = self
            result.radius = min(Self.maximumRadius(style: .globe, size: size),
                                max(Self.minimumRadius(style: .globe, size: size), radius))
            // Keep north up: stop just short of the poles rather than flipping over them.
            result.latitude = min(88, max(-88, latitude))
            return result
        }
    }

    /// Where `point` currently appears on screen, or nil if it's on the far side of the globe.
    func screenPoint(of point: GeoPoint, style: MapStyle, size: CGSize) -> CGPoint? {
        switch style {
        case .globe:
            return GlobeProjection(camera: self, size: size).screen(point)
        case .flat:
            let world = MillerProjection.project(latitude: point.latitude,
                                                 longitude: GeoMath.unwrap(point.longitude, near: longitude))
            return flatCamera.worldToScreen(world, in: size)
        }
    }

    // MARK: Interaction

    /// Drag: the flat map slides; the globe rotates so the point under the finger follows it.
    func panned(by delta: CGSize, style: MapStyle, size: CGSize) -> GeoCamera {
        switch style {
        case .flat:
            var result = GeoCamera(flat: flatCamera.panned(byScreen: delta).clamped(to: size))
            result.longitude = longitude - GeoMath.degrees(Double(delta.width / radius))
            return result
        case .globe:
            var result = self
            let cosLat = max(0.05, cos(GeoMath.radians(latitude)))
            result.longitude -= GeoMath.degrees(Double(delta.width / radius) / cosLat)
            result.latitude += GeoMath.degrees(Double(delta.height / radius))
            return result.clamped(style: .globe, size: size)
        }
    }

    /// Pinch / double-tap zoom that keeps the point under `anchor` (screen) in place.
    func zoomed(by factor: CGFloat, anchor: CGPoint, style: MapStyle, size: CGSize) -> GeoCamera {
        switch style {
        case .flat:
            var result = GeoCamera(flat: flatCamera.zoomed(by: factor, anchor: anchor, in: size))
            result.longitude = GeoMath.unwrap(result.longitude, near: longitude)
            return result
        case .globe:
            var result = self
            result.radius = radius * factor
            result = result.clamped(style: .globe, size: size)
            // Rotate towards the anchor by the angle it would otherwise drift. Exact at the
            // centre and a close approximation elsewhere, which is all a pinch needs.
            let k = Double(1 - radius / result.radius)
            let dx = Double(anchor.x - size.width / 2) / Double(radius)
            let dy = Double(anchor.y - size.height / 2) / Double(radius)
            let cosLat = max(0.05, cos(GeoMath.radians(latitude)))
            result.longitude += GeoMath.degrees(dx * k / cosLat)
            result.latitude -= GeoMath.degrees(dy * k)
            return result.clamped(style: .globe, size: size)
        }
    }

    /// The camera that puts `point` at `focusOffset` from the view centre, keeping the zoom.
    func centered(on point: GeoPoint, focusOffset: CGSize, style: MapStyle, size: CGSize) -> GeoCamera {
        var result = self
        let longitude = GeoMath.unwrap(point.longitude, near: self.longitude)
        switch style {
        case .flat:
            let world = MillerProjection.project(latitude: point.latitude, longitude: longitude)
            let flat = MapCamera(center: CGPoint(x: world.x - focusOffset.width / radius,
                                                 y: world.y + focusOffset.height / radius), scale: radius)
            result = GeoCamera(flat: flat.clamped(to: size))
            result.longitude = longitude - GeoMath.degrees(Double(focusOffset.width / radius))
        case .globe:
            result.latitude = point.latitude + GeoMath.degrees(Double(focusOffset.height / radius))
            let cosLat = max(0.05, cos(GeoMath.radians(point.latitude)))
            result.longitude = longitude - GeoMath.degrees(Double(focusOffset.width / radius) / cosLat)
            result = result.clamped(style: .globe, size: size)
        }
        return result
    }

    /// Frames `points` (route, track, aircraft). With `around`, that point is kept at the
    /// centre and the zoom chosen so everything else still fits.
    static func framing(_ points: [GeoPoint], around: GeoPoint? = nil, style: MapStyle,
                        size: CGSize, padding: EdgeInsets) -> GeoCamera? {
        guard !points.isEmpty, size.width > 1, size.height > 1 else { return nil }
        let halfWidth = max(20, (size.width - padding.leading - padding.trailing) / 2)
        let halfHeight = max(20, (size.height - padding.top - padding.bottom) / 2)
        let offset = CGSize(width: (padding.leading - padding.trailing) / 2, height: (padding.top - padding.bottom) / 2)

        switch style {
        case .flat:
            var bounds = CGRect.null
            let reference = around?.longitude ?? points[0].longitude
            for point in points {
                let p = MillerProjection.project(latitude: point.latitude,
                                                 longitude: GeoMath.unwrap(point.longitude, near: reference))
                bounds = bounds.union(CGRect(origin: p, size: .zero))
            }
            if let around {
                let c = MillerProjection.project(around)
                let w = max(c.x - bounds.minX, bounds.maxX - c.x), h = max(c.y - bounds.minY, bounds.maxY - c.y)
                let scale = min(halfWidth / max(w, 0.01), halfHeight / max(h, 0.01))
                let camera = GeoCamera(latitude: around.latitude, longitude: around.longitude, radius: scale)
                    .clamped(style: .flat, size: size)
                return camera.centered(on: around, focusOffset: offset, style: .flat, size: size)
            }
            let fit = MapCamera.fitting(bounds, in: size, padding: padding)
            return GeoCamera(flat: fit)

        case .globe:
            let vectors = points.map(GlobeProjection.unitVector)
            let centerVector = around.map(GlobeProjection.unitVector) ?? SphericalCap(points: vectors).center
            let spread = vectors.reduce(0) { max($0, angleBetween(centerVector, $1)) }
            // A point at angle θ from the centre lands R·sin θ from the middle of the globe.
            let limit = min(halfWidth, halfHeight)
            let radius = spread >= GeoMath.radians(80) ? 0 : limit / CGFloat(max(sin(spread), 1e-3))
            let center = GlobeProjection.geoPoint(centerVector)
            let camera = GeoCamera(latitude: center.latitude, longitude: center.longitude, radius: radius)
                .clamped(style: .globe, size: size)
            return camera.centered(on: center, focusOffset: offset, style: .globe, size: size)
        }
    }
}

extension GeoCamera: Animatable {
    /// Interpolates position linearly and zoom logarithmically.
    var animatableData: AnimatablePair<AnimatablePair<Double, Double>, CGFloat> {
        get { AnimatablePair(AnimatablePair(latitude, longitude), log(radius)) }
        set {
            latitude = newValue.first.first
            longitude = newValue.first.second
            radius = exp(newValue.second)
        }
    }
}
