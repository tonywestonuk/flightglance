import SwiftUI
import UIKit

/// Decides which place names (countries, oceans, seas, islands, cities) are shown at each zoom
/// step — independently of where the map is pointing — so labels never pop in and out while
/// panning or rotating the globe.
///
/// For every half step of web zoom level, candidates are considered in importance order
/// (Natural Earth's minimum label zoom; at equal zoom: countries, oceans, seas, islands, then
/// cities) and a label is kept only if it doesn't overlap one already kept. Area names may
/// shift a little from their exact point to find room (ITALY slides down the peninsula).
/// Overlap is tested on the ground: offsets between two places are measured in a local
/// east/north plane at true scale, which is the most compact any of the app's projections draws
/// them, so kept labels don't collide on screen. Results are cached per zoom step, text size
/// and route.
final class MapLabelPlanner: @unchecked Sendable {
    // @unchecked: the caches are only touched while holding `lock`.

    enum Kind: Int, Sendable {
        // Raw value orders ties: lower wins at equal minimum zoom.
        case country = 0, ocean, sea, island, city
    }

    struct Placement: Sendable {
        let kind: Kind
        /// Index into `WorldAtlas.countries`, `.regions` or `.cities`, depending on `kind`.
        let index: Int
        /// The label's rectangle relative to the place's screen point (y down).
        let rect: CGRect
    }

    private struct Key: Hashable {
        let step: Int
        let textSize: DynamicTypeSize
        let airports: [String]
    }

    private struct Candidate {
        let kind: Kind
        let index: Int
        let name: String
        var isCapital = false
        let minZoom: Double
        let latitude: Double
        let longitude: Double
    }

    static let stepsPerZoomLevel: CGFloat = 2
    /// Gap between a city label and its dot.
    static let dotGap: CGFloat = 6
    static let margin = CGSize(width: 3, height: 2)

    private let lock = NSLock()
    private var cache: [Key: [Placement]] = [:]
    private var sizes: [DynamicTypeSize: [String: CGSize]] = [:]

    /// Labels for the given camera zoom. `bias` is added to the zoom when testing Natural
    /// Earth's label zoom ranges (phone screens are small, so a bias shows more names).
    func placements(atlas: WorldAtlas, webZoom: CGFloat, bias: CGFloat, textSize: DynamicTypeSize,
                    airports: [MapOverlay.AirportMarker]) -> [Placement] {
        // Use the bottom of the zoom step: zooming in only spreads places further apart, so
        // labels chosen for the step stay clear of each other anywhere within it.
        let step = Int((webZoom * Self.stepsPerZoomLevel).rounded(.down))
        let key = Key(step: step, textSize: textSize, airports: airports.map(\.code))
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[key] { return cached }

        let zoom = CGFloat(step) / Self.stepsPerZoomLevel
        let scale = Double(256 * pow(2, zoom) / (2 * .pi)) // points per radian
        let result = plan(atlas: atlas, textSize: textSize, scale: scale, labelZoom: Double(zoom + bias),
                          airports: airports)
        if cache.count > 64 { cache.removeAll() }
        cache[key] = result
        return result
    }

    private struct Occupied {
        let latitude: Double
        let longitude: Double
        let rect: CGRect
    }

    private func candidates(atlas: WorldAtlas, labelZoom: Double) -> [Candidate] {
        var all: [Candidate] = []
        for (index, country) in atlas.countries.enumerated() {
            all.append(Candidate(kind: .country, index: index, name: country.name, minZoom: country.minZoom,
                                 latitude: country.latitude, longitude: country.longitude))
        }
        for (index, region) in atlas.regions.enumerated() {
            all.append(Candidate(kind: region.kind, index: index, name: region.name, minZoom: region.minZoom,
                                 latitude: region.latitude, longitude: region.longitude))
        }
        for (index, city) in atlas.cities.enumerated() {
            all.append(Candidate(kind: .city, index: index, name: city.name, isCapital: city.isCapital,
                                 minZoom: city.minZoom, latitude: city.latitude, longitude: city.longitude))
        }
        // Names appear once zoomed in far enough and then stay. (Natural Earth also gives a
        // maximum zoom, meant for web maps that switch to state/province names up close; this
        // map has none of those, so hiding a country's name there would just lose it.)
        return all
            .enumerated()
            .filter { $0.element.minZoom <= labelZoom }
            .sorted { ($0.element.minZoom, $0.element.kind.rawValue, $0.offset)
                    < ($1.element.minZoom, $1.element.kind.rawValue, $1.offset) }
            .map(\.element)
    }

    private func plan(atlas: WorldAtlas, textSize: DynamicTypeSize, scale: Double, labelZoom: Double,
                      airports: [MapOverlay.AirportMarker]) -> [Placement] {
        // Airport markers and their code tags are always drawn, so treat them as taken.
        var occupied = airports.map { airport in
            Occupied(latitude: GeoMath.radians(airport.coordinate.latitude),
                     longitude: GeoMath.radians(airport.coordinate.longitude),
                     rect: CGRect(x: -12, y: -15, width: 80, height: 30))
        }
        var result: [Placement] = []

        for candidate in candidates(atlas: atlas, labelZoom: labelZoom) {
            let size = labelSize(candidate, textSize: textSize)
            let options: [CGRect]
            var extra: CGRect?
            if candidate.kind == .city {
                let right = CGRect(x: Self.dotGap, y: -size.height / 2, width: size.width, height: size.height)
                options = [right, right.offsetBy(dx: -size.width - Self.dotGap * 2, dy: 0)]
                extra = CGRect(x: -3, y: -3, width: 6, height: 6) // the dot
            } else {
                // Area names: centred, or nudged a little if that spot is taken.
                let centred = CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)
                // Small enough that a name never drifts off its own country.
                let dy = size.height * 0.6, dx = size.width * 0.25
                options = [centred, centred.offsetBy(dx: 0, dy: dy), centred.offsetBy(dx: 0, dy: -dy),
                           centred.offsetBy(dx: dx, dy: 0), centred.offsetBy(dx: -dx, dy: 0)]
            }
            for rect in options {
                let footprint = extra.map { rect.union($0) } ?? rect
                guard !collides(footprint, at: candidate, with: occupied, scale: scale) else { continue }
                occupied.append(Occupied(latitude: candidate.latitude, longitude: candidate.longitude, rect: rect))
                if let extra {
                    occupied.append(Occupied(latitude: candidate.latitude, longitude: candidate.longitude, rect: extra))
                }
                result.append(Placement(kind: candidate.kind, index: candidate.index, rect: rect))
                break
            }
        }
        return result
    }

    private func collides(_ rect: CGRect, at place: Candidate, with occupied: [Occupied], scale: Double) -> Bool {
        let padded = rect.insetBy(dx: -Self.margin.width, dy: -Self.margin.height)
        let reach = Double(max(abs(padded.minX), abs(padded.maxX), abs(padded.minY), abs(padded.maxY)) + 400) / scale
        for other in occupied {
            let dLat = place.latitude - other.latitude
            guard abs(dLat) < reach else { continue }
            let dLon = remainder(place.longitude - other.longitude, 2 * .pi)
            let dx = dLon * cos((place.latitude + other.latitude) / 2) * scale
            guard abs(dx) < reach * scale else { continue }
            if padded.offsetBy(dx: CGFloat(dx), dy: CGFloat(-dLat * scale)).intersects(other.rect) { return true }
        }
        return false
    }

    /// Label size at the given text size, measured once per name and kind.
    private func labelSize(_ candidate: Candidate, textSize: DynamicTypeSize) -> CGSize {
        let key = "\(candidate.kind.rawValue)|\(candidate.name)"
        if let size = sizes[textSize]?[key] { return size }
        let style = MapLabelStyle(candidate.kind, isCapital: candidate.isCapital)
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(textSize))
        let pointSize = UIFont.preferredFont(forTextStyle: .caption2, compatibleWith: traits).pointSize
        var font = UIFont.systemFont(ofSize: pointSize, weight: style.uiWeight)
        if style.italic, let descriptor = font.fontDescriptor.withSymbolicTraits(.traitItalic) {
            font = UIFont(descriptor: descriptor, size: pointSize)
        }
        let measured = (style.display(candidate.name) as NSString)
            .size(withAttributes: [.font: font, .kern: style.tracking])
        let size = CGSize(width: ceil(measured.width), height: ceil(measured.height))
        sizes[textSize, default: [:]][key] = size
        return size
    }
}

/// How each kind of place name is drawn. Kept next to the planner because label sizes
/// (for spacing) must be measured with exactly the same styling.
struct MapLabelStyle {
    let uppercase: Bool
    let italic: Bool
    let tracking: CGFloat
    let weight: Font.Weight
    let uiWeight: UIFont.Weight

    init(_ kind: MapLabelPlanner.Kind, isCapital: Bool = false) {
        switch kind {
        case .country:
            (uppercase, italic, tracking, weight, uiWeight) = (true, false, 1.0, .semibold, .semibold)
        case .ocean:
            (uppercase, italic, tracking, weight, uiWeight) = (true, true, 2.0, .regular, .regular)
        case .sea:
            (uppercase, italic, tracking, weight, uiWeight) = (false, true, 0.3, .regular, .regular)
        case .island:
            (uppercase, italic, tracking, weight, uiWeight) = (false, false, 0.2, .medium, .medium)
        case .city:
            (uppercase, italic, tracking) = (false, false, 0)
            (weight, uiWeight) = isCapital ? (.semibold, .semibold) : (.regular, .regular)
        }
    }

    func display(_ name: String) -> String { uppercase ? name.uppercased() : name }

    func text(_ name: String, color: Color) -> Text {
        var text = Text(display(name)).font(.caption2.weight(weight)).tracking(tracking)
        if italic { text = text.italic() }
        return text.foregroundStyle(color)
    }
}
