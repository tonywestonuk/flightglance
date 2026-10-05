import SwiftUI

/// Draws the offline atlas as a flat Miller map, plus the flight overlay.
///
/// Atlas layers are drawn in *world* space: the context's transform is set to the camera's
/// world→screen mapping, so cached paths are reused every frame without re-projecting a
/// single vertex. Line widths are divided by the scale to stay constant on screen.
/// Labels and markers are drawn in *screen* space so text never scales.
struct AtlasRenderer {
    let atlas: WorldAtlas
    var palette = MapPalette.standard
    var showsCityLabels = true
    /// Added to the camera's web zoom level when testing a city's `minZoom`. Phone screens
    /// are small, so a modest bias shows a sensible handful of cities at world scale.
    var labelZoomBias: CGFloat = 1.3
    /// Switch from 1:110m to 1:50m geometry beyond this web zoom level.
    var detailZoomThreshold: CGFloat = 2.3

    func draw(in context: inout GraphicsContext, size: CGSize, camera: MapCamera, overlay: MapOverlay, layer: MapLayer) {
        let unit = 1 / camera.scale // one screen point, in world units
        let annotations = MapAnnotations(palette: palette)
        guard layer == .base else {
            drawOverlay(in: &context, size: size, camera: camera, overlay: overlay, unit: unit, annotations: annotations)
            return
        }

        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(palette.background))
        let visible = camera.visibleWorldRect(in: size)
        let detail: WorldAtlas.Detail = camera.webZoomLevel >= detailZoomThreshold ? .detailed : .coarse
        let offsets = camera.worldCopyOffsets(for: MillerProjection.worldRect, in: size)
        for offset in offsets {
            var world = context
            world.concatenate(camera.transform(in: size, worldOffset: offset))
            drawBaseMap(in: &world, visible: visible.offsetBy(dx: -offset, dy: 0), detail: detail, unit: unit)
        }

        if showsCityLabels {
            let placements = atlas.labelPlanner.placements(
                atlas: atlas, webZoom: camera.webZoomLevel, bias: labelZoomBias,
                textSize: context.environment.dynamicTypeSize, airports: overlay.markers)
            let screen = CGRect(origin: .zero, size: size).insetBy(dx: -200, dy: -40)
            annotations.drawPlaceLabels(placements, atlas: atlas, in: &context) { _, world in
                offsets.compactMap { offset in
                    let point = camera.worldToScreen(CGPoint(x: world.x + offset, y: world.y), in: size)
                    return screen.contains(point) ? (point, 1) : nil
                }
            }
        }
    }

    // MARK: Base map

    private func drawBaseMap(in context: inout GraphicsContext, visible: CGRect, detail: WorldAtlas.Detail, unit: CGFloat) {
        context.fill(Path(MillerProjection.worldRect), with: .color(palette.ocean))
        drawGraticule(in: &context, visible: visible, unit: unit)

        let land = atlas.land[detail]?.buckets ?? []
        let lakes = atlas.lakes[detail]?.buckets ?? []
        let borders = atlas.borders[detail]?.buckets ?? []

        for bucket in land where bucket.bounds.intersects(visible) {
            context.fill(bucket.fill, with: .color(palette.land))
        }
        for bucket in lakes where bucket.bounds.intersects(visible) {
            context.fill(bucket.fill, with: .color(palette.ocean))
        }
        let borderStyle = StrokeStyle(lineWidth: 0.7 * unit, lineCap: .round, lineJoin: .round)
        for bucket in borders where bucket.bounds.intersects(visible) {
            context.stroke(bucket.stroke, with: .color(palette.border), style: borderStyle)
        }
        let coastStyle = StrokeStyle(lineWidth: 0.8 * unit, lineCap: .round, lineJoin: .round)
        for bucket in land + lakes where bucket.bounds.intersects(visible) {
            context.stroke(bucket.stroke, with: .color(palette.coast), style: coastStyle)
        }
    }

    /// Latitude/longitude lines. Spacing coarsens as you zoom out so the grid stays quiet.
    private func drawGraticule(in context: inout GraphicsContext, visible: CGRect, unit: CGFloat) {
        let spanDegrees = GeoMath.degrees(Double(visible.width))
        let step: Double = spanDegrees > 150 ? 30 : spanDegrees > 60 ? 15 : spanDegrees > 20 ? 5 : 1
        let clip = visible.intersection(MillerProjection.worldRect)
        guard !clip.isNull else { return }

        var path = Path()
        var longitude = (GeoMath.degrees(Double(clip.minX)) / step).rounded(.down) * step
        while GeoMath.radians(longitude) <= Double(clip.maxX) {
            let x = CGFloat(GeoMath.radians(longitude))
            path.move(to: CGPoint(x: x, y: clip.minY))
            path.addLine(to: CGPoint(x: x, y: clip.maxY))
            longitude += step
        }
        var latitude = -90 + step
        while latitude < 90 {
            let y = MillerProjection.forwardY(latitude: latitude)
            if y >= clip.minY && y <= clip.maxY {
                path.move(to: CGPoint(x: clip.minX, y: y))
                path.addLine(to: CGPoint(x: clip.maxX, y: y))
            }
            latitude += step
        }
        context.stroke(path, with: .color(palette.graticule), lineWidth: 0.6 * unit)
        if clip.minY <= 0 && clip.maxY >= 0 {
            var equator = Path()
            equator.move(to: CGPoint(x: clip.minX, y: 0))
            equator.addLine(to: CGPoint(x: clip.maxX, y: 0))
            context.stroke(equator, with: .color(palette.graticule), lineWidth: 1.2 * unit)
        }
    }

    // MARK: Flight overlay

    /// Projects a line, dropping vertices closer than about a point to the previous one so
    /// a long-haul track (thousands of breadcrumbs) stays cheap to draw when zoomed out.
    private func worldLine(_ points: [GeoPoint], minimumSpacing: CGFloat) -> [CGPoint] {
        var result: [CGPoint] = []
        result.reserveCapacity(points.count)
        for (index, point) in points.enumerated() {
            let p = MillerProjection.project(point)
            if let last = result.last, index != points.count - 1,
               abs(p.x - last.x) < minimumSpacing, abs(p.y - last.y) < minimumSpacing { continue }
            result.append(p)
        }
        return result
    }

    /// Draws route, track, airports and aircraft.
    private func drawOverlay(in context: inout GraphicsContext, size: CGSize, camera: MapCamera,
                             overlay: MapOverlay, unit: CGFloat, annotations: MapAnnotations) {
        let route = worldLine(overlay.route, minimumSpacing: 0)
        let track = overlay.track.map { worldLine($0, minimumSpacing: unit) }
        let gaps = overlay.gaps.map { worldLine($0, minimumSpacing: 0) }
        var bounds = CGRect.null
        for point in route + track.flatMap({ $0 }) { bounds = bounds.union(CGRect(origin: point, size: .zero)) }
        if let aircraft = overlay.aircraft {
            bounds = bounds.union(CGRect(origin: MillerProjection.project(aircraft.coordinate), size: .zero))
        }
        guard !bounds.isNull else { return }
        let offsets = camera.worldCopyOffsets(for: bounds.insetBy(dx: -0.05, dy: -0.05), in: size)

        // Lines, in world space.
        for offset in offsets {
            var world = context
            world.concatenate(camera.transform(in: size, worldOffset: offset))
            if route.count > 1 {
                let path = Path { $0.addLines(route) }
                world.stroke(path, with: .color(palette.trackHalo),
                             style: StrokeStyle(lineWidth: 3.5 * unit, lineCap: .round, lineJoin: .round))
                world.stroke(path, with: .color(palette.route),
                             style: StrokeStyle(lineWidth: 1.6 * unit, lineCap: .round, lineJoin: .round,
                                                dash: [6 * unit, 5 * unit]))
            }
            for gap in gaps where gap.count > 1 {
                world.stroke(Path { $0.addLines(gap) }, with: .color(palette.track.opacity(0.7)),
                             style: StrokeStyle(lineWidth: 2 * unit, lineCap: .round, dash: [0.1 * unit, 5 * unit]))
            }
            let trackPath = Path { path in
                for segment in track where segment.count > 1 { path.addLines(segment) }
            }
            world.stroke(trackPath, with: .color(palette.trackHalo),
                         style: StrokeStyle(lineWidth: 6 * unit, lineCap: .round, lineJoin: .round))
            world.stroke(trackPath, with: .color(palette.track),
                         style: StrokeStyle(lineWidth: 3 * unit, lineCap: .round, lineJoin: .round))
        }

        // Markers, in screen space.
        let screenBounds = CGRect(origin: .zero, size: size).insetBy(dx: -40, dy: -40)
        for offset in offsets {
            for marker in overlay.markers {
                let world = MillerProjection.project(marker.coordinate)
                let point = camera.worldToScreen(CGPoint(x: world.x + offset, y: world.y), in: size)
                guard screenBounds.contains(point) else { continue }
                _ = annotations.drawAirport(marker, at: point, in: &context, size: size)
            }
            if let aircraft = overlay.aircraft {
                let world = MillerProjection.project(aircraft.coordinate)
                let point = camera.worldToScreen(CGPoint(x: world.x + offset, y: world.y), in: size)
                guard screenBounds.contains(point) else { continue }
                let angle = aircraft.course.map { Self.headingAngle(at: aircraft.coordinate, course: $0) }
                let latitude = GeoMath.radians(aircraft.coordinate.latitude)
                let accuracy = CGFloat(aircraft.accuracy / GeoMath.earthRadius / max(0.05, cos(latitude))) * camera.scale
                _ = annotations.drawAircraft(at: point, angle: angle, isLive: aircraft.isLive,
                                             accuracyRadius: accuracy, in: &context)
            }
        }
    }

    /// On-screen direction (radians, screen coordinates) of travel along `course`. Miller is
    /// not conformal, so this comes from a projected point ahead rather than the raw bearing.
    static func headingAngle(at point: GeoPoint, course: Double) -> Double {
        let ahead = GeoMath.destination(from: point, bearing: course, distance: 20_000)
        let a = MillerProjection.project(point)
        let b = MillerProjection.project(latitude: ahead.latitude,
                                         longitude: GeoMath.unwrap(ahead.longitude, near: point.longitude))
        // Screen y points down, so negate the world y difference.
        return atan2(-Double(b.y - a.y), Double(b.x - a.x))
    }
}
