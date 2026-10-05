import CoreGraphics
import SwiftUI

/// A viewport onto the projected (Miller) world.
///
/// `center` is in world units (radians, +y north) and `scale` is screen points per world
/// unit. Screen space has its origin at the top-left with +y down, so the transform flips y:
///
///     screen.x = (world.x − center.x) · scale + width / 2
///     screen.y = (center.y − world.y) · scale + height / 2
///
/// `center.x` is deliberately left unbounded: the renderer draws whichever 2π-wide copies of
/// the world are visible, so panning across the date line never jumps.
struct MapCamera: Equatable, Sendable {
    var center: CGPoint
    var scale: CGFloat

    /// Narrowest span (degrees of longitude) the shorter screen side may show. The bundled
    /// 1:50m data looks good down to roughly this level.
    static let minimumVisibleDegrees: CGFloat = 4

    func worldToScreen(_ world: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: (world.x - center.x) * scale + size.width / 2,
                y: (center.y - world.y) * scale + size.height / 2)
    }

    func screenToWorld(_ screen: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: center.x + (screen.x - size.width / 2) / scale,
                y: center.y - (screen.y - size.height / 2) / scale)
    }

    /// Affine transform mapping world units to screen points, optionally for the world copy
    /// shifted by `worldOffset` (a multiple of 2π).
    func transform(in size: CGSize, worldOffset: CGFloat = 0) -> CGAffineTransform {
        CGAffineTransform(a: scale, b: 0, c: 0, d: -scale,
                          tx: (worldOffset - center.x) * scale + size.width / 2,
                          ty: center.y * scale + size.height / 2)
    }

    /// The region of world space currently on screen.
    func visibleWorldRect(in size: CGSize) -> CGRect {
        let width = size.width / scale, height = size.height / scale
        return CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
    }

    /// Multiples of 2π by which world-space content spanning `bounds` must be shifted to be
    /// visible. Usually one value; two or three near the date line or when zoomed far out.
    func worldCopyOffsets(for bounds: CGRect, in size: CGSize) -> [CGFloat] {
        let visible = visibleWorldRect(in: size)
        guard !bounds.isNull, bounds.height >= 0 else { return [] }
        let w = MillerProjection.worldWidth
        let first = Int(((visible.minX - bounds.maxX) / w).rounded(.up))
        let last = Int(((visible.maxX - bounds.minX) / w).rounded(.down))
        guard first <= last else { return [] }
        return (first...last).map { CGFloat($0) * w }
    }

    // MARK: Limits

    /// Smallest scale: the whole world width fits the view (more would just repeat it).
    static func minimumScale(for size: CGSize) -> CGFloat {
        max(1, size.width / MillerProjection.worldWidth)
    }

    static func maximumScale(for size: CGSize) -> CGFloat {
        let span = GeoMath.radians(Double(minimumVisibleDegrees))
        return max(minimumScale(for: size), min(size.width, size.height) / CGFloat(span))
    }

    /// Clamps zoom to the allowed range and keeps the view from scrolling past the poles.
    /// When the world is shorter than the view it is centred vertically.
    func clamped(to size: CGSize) -> MapCamera {
        guard size.width > 0, size.height > 0 else { return self }
        var result = self
        result.scale = min(Self.maximumScale(for: size), max(Self.minimumScale(for: size), scale))
        let halfHeight = size.height / 2 / result.scale
        let maxY = MillerProjection.maxY
        if halfHeight >= maxY {
            result.center.y = 0
        } else {
            result.center.y = min(maxY - halfHeight, max(-maxY + halfHeight, center.y))
        }
        return result
    }

    /// Moves `center.x` into [-π, π) without changing what is displayed.
    func normalized() -> MapCamera {
        var result = self
        let w = MillerProjection.worldWidth
        result.center.x -= w * ((center.x + .pi) / w).rounded(.down)
        return result
    }

    // MARK: Interaction

    func panned(byScreen delta: CGSize) -> MapCamera {
        var result = self
        result.center.x -= delta.width / scale
        result.center.y += delta.height / scale
        return result
    }

    /// Zooms by `factor` keeping the world point under `anchor` (screen) fixed.
    func zoomed(by factor: CGFloat, anchor: CGPoint, in size: CGSize) -> MapCamera {
        let anchorWorld = screenToWorld(anchor, in: size)
        var result = self
        result.scale = scale * factor
        result = result.clamped(to: size)
        result.center = CGPoint(x: anchorWorld.x - (anchor.x - size.width / 2) / result.scale,
                                y: anchorWorld.y + (anchor.y - size.height / 2) / result.scale)
        return result.clamped(to: size)
    }

    /// A camera showing `rect` (world units) inside the view, inset by `padding` points.
    static func fitting(_ rect: CGRect, in size: CGSize, padding: EdgeInsets) -> MapCamera {
        let available = CGSize(width: max(40, size.width - padding.leading - padding.trailing),
                               height: max(40, size.height - padding.top - padding.bottom))
        let width = max(rect.width, 0.02), height = max(rect.height, 0.02)
        let scale = min(available.width / width, available.height / height)
        // Shift the centre so the rect sits in the middle of the *padded* area.
        let dx = (padding.trailing - padding.leading) / 2
        let dy = (padding.bottom - padding.top) / 2
        let camera = MapCamera(center: CGPoint(x: rect.midX, y: rect.midY), scale: scale).clamped(to: size)
        return MapCamera(center: CGPoint(x: rect.midX + dx / camera.scale, y: rect.midY - dy / camera.scale),
                         scale: camera.scale).clamped(to: size)
    }

    /// Web-map style zoom level (world width = 256 · 2^z points), used to decide which
    /// cities are important enough to label.
    var webZoomLevel: CGFloat {
        log2(max(1, MillerProjection.worldWidth * scale) / 256)
    }
}

extension MapCamera: Animatable {
    /// Interpolates the centre linearly and the scale logarithmically, so animated zooms
    /// feel uniform rather than rushing through the zoomed-out end.
    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get { AnimatablePair(AnimatablePair(center.x, center.y), log(scale)) }
        set {
            center = CGPoint(x: newValue.first.first, y: newValue.first.second)
            scale = exp(newValue.second)
        }
    }
}
