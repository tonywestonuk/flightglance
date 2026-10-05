import simd
import SwiftUI

/// Draws the offline atlas as a shaded 3D globe (orthographic projection), plus the flight
/// overlay.
///
/// Unlike the flat map, an orthographic view can't reuse cached screen paths: every visible
/// vertex is re-projected each frame (two dot products per vertex — see `GlobeProjection`).
/// That stays cheap because geometry is grouped into buckets with bounding spherical caps,
/// and buckets/rings that are behind the globe or off screen are skipped before projecting.
///
/// Horizon handling:
/// * Lines (coastlines, borders, route, track) are cut where they pass over the horizon,
///   ending exactly on the globe's edge.
/// * Filled shapes (land, lakes) that are partly behind the globe are closed along the
///   horizon: each hidden vertex is pushed out to the edge of the disc in its own screen
///   direction, so the hidden part of the outline runs around the rim. That fills exactly
///   the visible part of the shape — *unless* the shape contains the point directly behind
///   the globe (the antipode of the view centre), in which case the outline winds the
///   other way round the rim. Those shapes are drawn together with the full disc using the
///   even-odd rule, which flips the result back to the correct region.
struct GlobeRenderer {
    let atlas: WorldAtlas
    var palette = MapPalette.standard
    var showsCityLabels = true
    var labelZoomBias: CGFloat = 1.3
    var detailZoomThreshold: CGFloat = 2.3

    func draw(in context: inout GraphicsContext, size: CGSize, camera: GeoCamera, overlay: MapOverlay, layer: MapLayer) {
        let projection = GlobeProjection(camera: camera, size: size)
        switch layer {
        case .base: drawBase(in: &context, size: size, camera: camera, projection: projection, markers: overlay.markers)
        case .flight: drawFlight(in: &context, size: size, projection: projection, overlay: overlay)
        }
    }

    private func drawBase(in context: inout GraphicsContext, size: CGSize, camera: GeoCamera,
                          projection: GlobeProjection, markers: [MapOverlay.AirportMarker]) {
        let radius = CGFloat(projection.radius)
        let origin = projection.origin
        let disc = CGRect(x: origin.x - radius, y: origin.y - radius, width: radius * 2, height: radius * 2)
        let discPath = Path(ellipseIn: disc)
        let viewRadius = projection.visibleAngularRadius(for: size)
        let detail: WorldAtlas.Detail = camera.webZoomLevel >= detailZoomThreshold ? .detailed : .coarse
        let showsLimb = radius < max(size.width, size.height) * 1.5

        // Space and a soft atmospheric glow around the limb.
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(palette.space))
        if showsLimb {
            let glow = disc.insetBy(dx: -radius * 0.09, dy: -radius * 0.09)
            context.fill(Path(ellipseIn: glow), with: .radialGradient(
                Gradient(stops: [.init(color: palette.atmosphere, location: 0),
                                 .init(color: palette.atmosphere.opacity(0), location: 1)]),
                center: origin, startRadius: radius * 0.97, endRadius: radius * 1.09))
        }

        // Ocean, lit from the upper left. Lakes reuse the same shading so they blend in.
        let water = GraphicsContext.Shading.radialGradient(
            Gradient(colors: [palette.oceanLit, palette.ocean]),
            center: CGPoint(x: origin.x - radius * 0.35, y: origin.y - radius * 0.4),
            startRadius: 0, endRadius: radius * 1.45)
        context.fill(discPath, with: water)

        var globe = context
        globe.clip(to: discPath)
        drawGraticule(in: &globe, projection: projection, camera: camera, viewRadius: viewRadius)

        let antipode = (latitude: -camera.latitude, longitude: GeoMath.normalizedLongitude(camera.longitude + 180))
        let land = atlas.globeLand[detail]?.buckets ?? []
        let lakes = atlas.globeLakes[detail]?.buckets ?? []
        let borders = atlas.globeBorders[detail]?.buckets ?? []
        let visibleLand = visibleRings(land, projection: projection, viewRadius: viewRadius)
        let visibleLakes = visibleRings(lakes, projection: projection, viewRadius: viewRadius)

        fillRings(visibleLand, with: .color(palette.land), in: &globe, projection: projection, disc: disc, antipode: antipode)
        fillRings(visibleLakes, with: water, in: &globe, projection: projection, disc: disc, antipode: antipode)

        var borderPath = Path()
        for ring in visibleRings(borders, projection: projection, viewRadius: viewRadius) {
            appendLine(ring.points, closed: false, artificial: nil, projection: projection, to: &borderPath)
        }
        globe.stroke(borderPath, with: .color(palette.border), style: StrokeStyle(lineWidth: 0.7, lineCap: .round, lineJoin: .round))

        var coastPath = Path()
        for ring in visibleLand + visibleLakes {
            appendLine(ring.points, closed: true, artificial: ring.artificial, projection: projection, to: &coastPath)
        }
        globe.stroke(coastPath, with: .color(palette.coast), style: StrokeStyle(lineWidth: 0.8, lineCap: .round, lineJoin: .round))

        // Darken towards the limb so the disc reads as a sphere.
        if showsLimb {
            globe.fill(discPath, with: .radialGradient(
                Gradient(stops: [.init(color: palette.limbShade.opacity(0), location: 0.55),
                                 .init(color: palette.limbShade, location: 1)]),
                center: origin, startRadius: 0, endRadius: radius))
        }

        if showsLimb {
            context.stroke(discPath, with: .color(palette.rim), lineWidth: 1)
        }

        if showsCityLabels {
            let placements = atlas.labelPlanner.placements(
                atlas: atlas, webZoom: camera.webZoomLevel, bias: labelZoomBias,
                textSize: context.environment.dynamicTypeSize, airports: markers)
            // Fade labels out towards the horizon instead of popping them.
            MapAnnotations(palette: palette).drawPlaceLabels(placements, atlas: atlas, in: &context) { unit, _ in
                let depth = projection.depth(unit)
                guard depth > 0.4 else { return [] }
                return [(projection.screen(unit), min(1, (depth - 0.4) / 0.2))]
            }
        }
    }

    private func drawFlight(in context: inout GraphicsContext, size: CGSize, projection: GlobeProjection,
                            overlay: MapOverlay) {
        let radius = CGFloat(projection.radius)
        let origin = projection.origin
        let disc = CGRect(x: origin.x - radius, y: origin.y - radius, width: radius * 2, height: radius * 2)
        var globe = context
        globe.clip(to: Path(ellipseIn: disc))
        drawOverlayLines(overlay, in: &globe, projection: projection)

        let annotations = MapAnnotations(palette: palette)
        for marker in overlay.markers {
            guard let point = projection.screen(marker.coordinate) else { continue }
            _ = annotations.drawAirport(marker, at: point, in: &context, size: size)
        }
        if let aircraft = overlay.aircraft {
            let v = GlobeProjection.unitVector(aircraft.coordinate)
            if projection.depth(v) >= 0 {
                let angle = aircraft.course.map { projection.headingAngle(at: aircraft.coordinate, course: $0) }
                let accuracy = CGFloat(aircraft.accuracy / GeoMath.earthRadius) * radius
                _ = annotations.drawAircraft(at: projection.screen(v), angle: angle, isLive: aircraft.isLive,
                                             accuracyRadius: accuracy, in: &context)
            }
        }
    }

    // MARK: Culling

    private func visibleRings(_ buckets: [WorldAtlas.GlobeBucket], projection: GlobeProjection,
                              viewRadius: Double) -> [WorldAtlas.GlobeRing] {
        var rings: [WorldAtlas.GlobeRing] = []
        for bucket in buckets where bucket.cap.intersects(direction: projection.center, angularRadius: viewRadius) {
            for ring in bucket.rings where ring.cap.intersects(direction: projection.center, angularRadius: viewRadius) {
                rings.append(ring)
            }
        }
        return rings
    }

    // MARK: Fills

    private func fillRings(_ rings: [WorldAtlas.GlobeRing], with shading: GraphicsContext.Shading,
                           in context: inout GraphicsContext, projection: GlobeProjection, disc: CGRect,
                           antipode: (latitude: Double, longitude: Double)) {
        var path = Path()
        for ring in rings {
            var ringPath = Path()
            let partlyHidden = appendFill(ring.points, projection: projection, to: &ringPath)
            if partlyHidden, Self.contains(ring, longitude: antipode.longitude, latitude: antipode.latitude) {
                // See the type comment: flip the inside/outside of this shape.
                ringPath.addEllipse(in: disc)
                context.fill(ringPath, with: shading, style: FillStyle(eoFill: true))
            } else {
                path.addPath(ringPath)
            }
        }
        context.fill(path, with: shading)
    }

    /// Appends a closed ring, routing hidden stretches around the horizon. Returns true if
    /// any vertex was behind the globe.
    @discardableResult
    func appendFill(_ points: [SIMD3<Double>], projection: GlobeProjection, to path: inout Path) -> Bool {
        let count = points.count
        guard count >= 3 else { return false }
        let radius = projection.radius, origin = projection.origin
        var started = false
        var lastRimAngle: Double?
        var anyHidden = false

        func add(_ point: CGPoint) {
            if started { path.addLine(to: point) } else { path.move(to: point); started = true }
        }
        // Points on the rim are joined along the circle, not by a chord through the disc.
        func addOnRim(_ point: CGPoint) {
            let angle = atan2(Double(point.y - origin.y), Double(point.x - origin.x))
            if let last = lastRimAngle {
                let delta = remainder(angle - last, 2 * .pi)
                let steps = Int(abs(delta) / 0.08)
                if steps > 1 {
                    for step in 1..<steps {
                        let a = last + delta * Double(step) / Double(steps)
                        add(CGPoint(x: origin.x + radius * cos(a), y: origin.y + radius * sin(a)))
                    }
                }
            }
            add(point)
            lastRimAngle = angle
        }

        var previous = points[count - 1]
        var previousDepth = projection.depth(previous)
        for current in points {
            let depth = projection.depth(current)
            if (previousDepth >= 0) != (depth >= 0) {
                addOnRim(projection.screen(projection.horizonCrossing(previous, current)))
            }
            if depth >= 0 {
                add(projection.screen(current))
                lastRimAngle = nil
            } else {
                anyHidden = true
                addOnRim(projection.horizonPoint(towards: current))
            }
            previous = current
            previousDepth = depth
        }
        path.closeSubpath()
        return anyHidden
    }

    /// Point-in-polygon in longitude/latitude, the space in which Natural Earth defines its
    /// polygons (so "inside" is unambiguous, even for Antarctica).
    static func contains(_ ring: WorldAtlas.GlobeRing, longitude: Double, latitude: Double) -> Bool {
        let b = ring.bounds
        guard longitude >= Double(b.minX), longitude <= Double(b.maxX),
              latitude >= Double(b.minY), latitude <= Double(b.maxY) else { return false }
        var inside = false
        var j = ring.lonLat.count - 1
        for i in ring.lonLat.indices {
            let a = ring.lonLat[i], c = ring.lonLat[j]
            if (a.y > latitude) != (c.y > latitude) {
                let x = (c.x - a.x) * (latitude - a.y) / (c.y - a.y) + a.x
                if longitude < x { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    // MARK: Lines

    /// Appends the visible parts of a polyline, cutting it exactly at the horizon.
    /// `minimumSpacing` drops vertices closer than that many points (for long GPS tracks).
    func appendLine(_ points: [SIMD3<Double>], closed: Bool, artificial: [Bool]?, projection: GlobeProjection,
                    minimumSpacing: CGFloat = 0, to path: inout Path) {
        let count = points.count
        guard count >= 2 else { return }
        let segments = closed ? count : count - 1
        var penDown = false
        var lastDrawn = CGPoint.zero
        var depthA = projection.depth(points[0])
        for i in 0..<segments {
            let a = points[i], b = points[(i + 1) % count]
            let depthB = projection.depth(b)
            defer { depthA = depthB }
            if artificial?[i] == true {
                penDown = false
                continue
            }
            if depthA >= 0 && depthB >= 0 {
                if !penDown {
                    lastDrawn = projection.screen(a)
                    path.move(to: lastDrawn)
                    penDown = true
                }
                let pb = projection.screen(b)
                if minimumSpacing > 0, i < segments - 1,
                   abs(pb.x - lastDrawn.x) < minimumSpacing, abs(pb.y - lastDrawn.y) < minimumSpacing { continue }
                path.addLine(to: pb)
                lastDrawn = pb
            } else if depthA >= 0 {
                if !penDown { path.move(to: projection.screen(a)) }
                path.addLine(to: projection.screen(projection.horizonCrossing(a, b)))
                penDown = false
            } else if depthB >= 0 {
                path.move(to: projection.screen(projection.horizonCrossing(a, b)))
                lastDrawn = projection.screen(b)
                path.addLine(to: lastDrawn)
                penDown = true
            } else {
                penDown = false
            }
        }
    }

    // MARK: Graticule

    private func drawGraticule(in context: inout GraphicsContext, projection: GlobeProjection,
                               camera: GeoCamera, viewRadius: Double) {
        let viewDegrees = GeoMath.degrees(viewRadius)
        let step: Double = viewDegrees >= 60 ? 30 : viewDegrees > 25 ? 15 : viewDegrees > 8 ? 5 : 1
        let sample = min(2, step / 5)
        let latMin = max(-90, camera.latitude - viewDegrees - step)
        let latMax = min(90, camera.latitude + viewDegrees + step)
        let polar = abs(camera.latitude) + viewDegrees >= 80
        let lonSpan = viewDegrees >= 60 || polar ? 180
            : viewDegrees / cos(GeoMath.radians(abs(camera.latitude) + viewDegrees)) + step
        let lonMin = camera.longitude - lonSpan, lonMax = camera.longitude + lonSpan

        var path = Path()
        var equator = Path()
        var longitude = (lonMin / step).rounded(.up) * step
        while longitude <= lonMax {
            let line = stride(from: latMin, through: latMax, by: sample).map {
                GlobeProjection.unitVector(latitude: $0, longitude: longitude)
            }
            appendLine(line, closed: false, artificial: nil, projection: projection, to: &path)
            longitude += step
        }
        var latitude = (latMin / step).rounded(.up) * step
        while latitude <= latMax {
            if abs(latitude) < 90 {
                let line = stride(from: lonMin, through: lonMax, by: sample).map {
                    GlobeProjection.unitVector(latitude: latitude, longitude: $0)
                }
                if latitude == 0 {
                    appendLine(line, closed: false, artificial: nil, projection: projection, to: &equator)
                } else {
                    appendLine(line, closed: false, artificial: nil, projection: projection, to: &path)
                }
            }
            latitude += step
        }
        context.stroke(path, with: .color(palette.graticule), lineWidth: 0.6)
        context.stroke(equator, with: .color(palette.graticule), lineWidth: 1.2)
    }

    // MARK: Overlay

    private func drawOverlayLines(_ overlay: MapOverlay, in context: inout GraphicsContext, projection: GlobeProjection) {
        if overlay.route.count > 1 {
            var route = Path()
            appendLine(overlay.route.map(GlobeProjection.unitVector), closed: false, artificial: nil,
                       projection: projection, to: &route)
            context.stroke(route, with: .color(palette.trackHalo),
                           style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
            context.stroke(route, with: .color(palette.route),
                           style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round, dash: [6, 5]))
        }
        var gaps = Path()
        for gap in overlay.gaps where gap.count > 1 {
            appendLine(gap.map(GlobeProjection.unitVector), closed: false, artificial: nil, projection: projection, to: &gaps)
        }
        context.stroke(gaps, with: .color(palette.track.opacity(0.7)),
                       style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [0.1, 5]))
        var track = Path()
        for segment in overlay.track where segment.count > 1 {
            appendLine(segment.map(GlobeProjection.unitVector), closed: false, artificial: nil,
                       projection: projection, minimumSpacing: 1, to: &track)
        }
        context.stroke(track, with: .color(palette.trackHalo), style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
        context.stroke(track, with: .color(palette.track), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
    }
}
