import simd
import SwiftUI

/// Flight-specific content drawn on top of the atlas, in geographic coordinates.
///
/// Longitudes are unwrapped relative to the origin airport (see `GeoMath.unwrapLongitudes`)
/// so the route and track are continuous across the date line. Each renderer projects them.
struct MapOverlay: Equatable, Sendable {
    struct AirportMarker: Equatable, Sendable {
        enum Role: Sendable { case origin, destination }
        var code: String
        var coordinate: GeoPoint
        var role: Role
    }

    struct Aircraft: Equatable, Sendable {
        var coordinate: GeoPoint
        /// GPS course over ground. Nil when unknown, in which case a plain position dot is
        /// drawn rather than guessing a direction.
        var course: Double?
        /// False when the fix is stale; drawn greyed as "last known position".
        var isLive: Bool
        /// GPS horizontal accuracy in metres.
        var accuracy: Double
    }

    /// Dashed reference line to the destination: from the aircraft in flight, from the origin
    /// in the setup preview.
    var route: [GeoPoint] = []
    /// Observed GPS breadcrumb, split into continuously observed segments.
    var track: [[GeoPoint]] = []
    /// Straight connectors across signal gaps (not observed).
    var gaps: [[GeoPoint]] = []
    var markers: [AirportMarker] = []
    var aircraft: Aircraft?

    /// Everything worth framing: route, track, airports and aircraft.
    var framingPoints: [GeoPoint] {
        var points = route
        for segment in track { points.append(contentsOf: segment) }
        points.append(contentsOf: markers.map(\.coordinate))
        if let aircraft { points.append(aircraft.coordinate) }
        return points
    }
}

/// The map is drawn as two stacked layers so the expensive one is redrawn rarely:
/// * `base`: space/ocean, land, coastlines, borders, graticule, shading and city labels.
///   Depends only on the camera, so in follow mode it is redrawn only when the view moves.
/// * `flight`: route, GPS track, airport markers and the aircraft. Cheap; redrawn per fix.
enum MapLayer: Sendable {
    case base
    case flight
}

/// Screen-space drawing shared by the globe and flat renderers: airport markers, the
/// aircraft symbol and decluttered city labels. Text and symbols are never scaled or rotated
/// with the map, so they stay crisp and readable at every zoom.
struct MapAnnotations {
    var palette: MapPalette

    /// Draws an airport marker with its code. Returns the area city labels must avoid.
    func drawAirport(_ marker: MapOverlay.AirportMarker, at point: CGPoint,
                     in context: inout GraphicsContext, size: CGSize) -> CGRect {
        let outer = CGRect(x: point.x - 6, y: point.y - 6, width: 12, height: 12)
        context.fill(Path(ellipseIn: outer.insetBy(dx: -2, dy: -2)), with: .color(palette.halo))
        context.stroke(Path(ellipseIn: outer), with: .color(palette.marker), lineWidth: 2.5)
        if marker.role == .destination {
            context.fill(Path(ellipseIn: outer.insetBy(dx: 3.5, dy: 3.5)), with: .color(palette.marker))
        }

        let (text, labelRect) = airportLabel(marker, at: point, in: context, size: size)
        context.fill(Path(roundedRect: labelRect, cornerRadius: 5), with: .color(palette.markerLabelBackground))
        context.draw(text, at: CGPoint(x: labelRect.midX, y: labelRect.midY), anchor: .center)
        return labelRect.union(outer).insetBy(dx: -4, dy: -4)
    }

    /// The area an airport marker and its label occupy, without drawing it. The base layer
    /// uses this to keep city labels clear of markers drawn by the flight layer.
    func airportFootprint(_ marker: MapOverlay.AirportMarker, at point: CGPoint,
                          in context: GraphicsContext, size: CGSize) -> CGRect {
        let outer = CGRect(x: point.x - 8, y: point.y - 8, width: 16, height: 16)
        return airportLabel(marker, at: point, in: context, size: size).rect.union(outer).insetBy(dx: -4, dy: -4)
    }

    private func airportLabel(_ marker: MapOverlay.AirportMarker, at point: CGPoint, in context: GraphicsContext,
                              size: CGSize) -> (text: GraphicsContext.ResolvedText, rect: CGRect) {
        let text = context.resolve(Text(marker.code)
            .font(.caption.weight(.bold))
            .monospaced()
            .foregroundStyle(palette.markerLabelText))
        let textSize = text.measure(in: CGSize(width: 200, height: 60))
        // Put the label on whichever side has room.
        let placeRight = point.x + 12 + textSize.width + 10 < size.width
        let rect = CGRect(x: placeRight ? point.x + 11 : point.x - 11 - textSize.width - 10,
                          y: point.y - textSize.height / 2 - 3,
                          width: textSize.width + 10, height: textSize.height + 6)
        return (text, rect)
    }

    /// Draws the aircraft. `angle` is the on-screen direction of travel (radians, screen
    /// coordinates); nil draws a position dot because the course is unknown.
    func drawAircraft(at point: CGPoint, angle: Double?, isLive: Bool, accuracyRadius: CGFloat,
                      in context: inout GraphicsContext) -> CGRect {
        if isLive && accuracyRadius > 14 {
            let circle = CGRect(x: point.x - accuracyRadius, y: point.y - accuracyRadius,
                                width: accuracyRadius * 2, height: accuracyRadius * 2)
            context.fill(Path(ellipseIn: circle), with: .color(palette.accuracy))
        }
        let color = isLive ? palette.aircraft : palette.staleAircraft
        let reserved = CGRect(x: point.x - 18, y: point.y - 18, width: 36, height: 36)

        guard let angle, isLive else {
            let dot = CGRect(x: point.x - 7, y: point.y - 7, width: 14, height: 14)
            context.fill(Path(ellipseIn: dot.insetBy(dx: -3, dy: -3)), with: .color(palette.aircraftOutline))
            context.fill(Path(ellipseIn: dot), with: .color(color))
            if !isLive {
                context.stroke(Path(ellipseIn: dot.insetBy(dx: -7, dy: -7)), with: .color(color),
                               style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
            }
            return reserved
        }

        var plane = context
        plane.translateBy(x: point.x, y: point.y)
        plane.rotate(by: .radians(angle))
        let shape = Self.aircraftShape.applying(CGAffineTransform(scaleX: 15, y: 15))
        plane.stroke(shape, with: .color(palette.aircraftOutline), style: StrokeStyle(lineWidth: 3, lineJoin: .round))
        plane.fill(shape, with: .color(color))
        return reserved
    }

    /// A simple airliner silhouette in unit space, nose pointing along +x.
    static let aircraftShape: Path = {
        let upper: [CGPoint] = [
            CGPoint(x: 1.0, y: 0), CGPoint(x: 0.86, y: 0.09), CGPoint(x: 0.22, y: 0.11),
            CGPoint(x: -0.28, y: 0.92), CGPoint(x: -0.44, y: 0.92), CGPoint(x: -0.16, y: 0.11),
            CGPoint(x: -0.64, y: 0.10), CGPoint(x: -0.86, y: 0.40), CGPoint(x: -0.98, y: 0.40),
            CGPoint(x: -0.88, y: 0.05), CGPoint(x: -1.0, y: 0),
        ]
        let lower = upper.dropFirst().dropLast().reversed().map { CGPoint(x: $0.x, y: -$0.y) }
        var path = Path()
        path.addLines(upper + lower)
        path.closeSubpath()
        return path
    }()

    /// Draws the planned country and city labels (see `MapLabelPlanner`). The *set* of labels
    /// depends only on zoom; `position` just says where a place is on screen right now
    /// (several places for the flat map's repeated world, none if hidden) and how opaque to
    /// draw it. Country names are muted, spaced capitals; oceans and seas are blue italics;
    /// cities get a dot.
    ///
    /// The plan guarantees no overlaps at true scale, which holds everywhere on the flat map
    /// and in the middle of the globe. Towards the globe's rim the sphere squashes places
    /// together, so there a label that would overlap a more important one is skipped.
    func drawPlaceLabels(_ placements: [MapLabelPlanner.Placement], atlas: WorldAtlas,
                         in context: inout GraphicsContext,
                         position: (_ unit: SIMD3<Double>, _ world: CGPoint) -> [(point: CGPoint, opacity: Double)]) {
        struct Label {
            var text: GraphicsContext.ResolvedText
            var origin: CGPoint
            var dot: CGPoint?
            var capital: Bool
            var opacity: Double
        }
        var labels: [Label] = []
        var drawn: [CGRect] = []
        func isClear(_ rect: CGRect) -> Bool {
            let padded = rect.insetBy(dx: -2, dy: -1)
            guard !drawn.contains(where: { $0.intersects(padded) }) else { return false }
            drawn.append(rect)
            return true
        }
        for placement in placements {
            let place = atlas.labelPoint(placement.kind, placement.index)
            let isCity = placement.kind == .city
            let isCapital = isCity && atlas.cities[placement.index].isCapital
            let color: Color = switch placement.kind {
            case .country: palette.countryText
            case .ocean, .sea: palette.waterText
            case .island, .city: palette.cityText
            }
            for (point, opacity) in position(place.unit, place.world) where opacity > 0.01 {
                var footprint = placement.rect.offsetBy(dx: point.x, dy: point.y)
                if isCity { footprint = footprint.union(CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)) }
                guard isClear(footprint) else { continue }
                let text = context.resolve(MapLabelStyle(placement.kind, isCapital: isCapital).text(place.name, color: color))
                labels.append(Label(text: text,
                                    origin: CGPoint(x: point.x + placement.rect.minX, y: point.y + placement.rect.minY),
                                    dot: isCity ? point : nil, capital: isCapital, opacity: opacity))
            }
        }

        for label in labels {
            guard let point = label.dot else { continue }
            var dotContext = context
            dotContext.opacity = label.opacity
            let r: CGFloat = label.capital ? 2.6 : 2
            let dot = CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2)
            dotContext.fill(Path(ellipseIn: dot.insetBy(dx: -1, dy: -1)), with: .color(palette.halo))
            dotContext.fill(Path(ellipseIn: dot), with: .color(palette.cityDot))
        }
        // Text halo: a soft shadow in the map background colour keeps labels legible over
        // coastlines and borders without heavy boxes.
        context.drawLayer { layer in
            layer.addFilter(.shadow(color: palette.halo, radius: 1.5))
            for label in labels {
                layer.opacity = label.opacity
                layer.draw(label.text, at: label.origin, anchor: .topLeading)
            }
        }
    }
}
