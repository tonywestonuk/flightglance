import Foundation

/// Development-only GPS source that "flies" the reference great circle.
///
/// Used in the Simulator and for demos so the in-flight dashboard can be exercised without
/// boarding a plane. Every reading it produces is flagged as simulated and the UI says so
/// prominently; it is never mixed with real GPS data.
struct FlightSimulation: Codable, Equatable, Sendable {
    var origin: GeoPoint
    var destination: GeoPoint
    /// Wall-clock time at which the simulated aircraft is at `startProgress`.
    var anchorDate: Date
    /// Fraction of the route already flown at `anchorDate`, so a demo starts mid-flight.
    var startProgress: Double = 0.35
    /// ≈ 476 kt ground speed.
    var cruiseSpeed: Double = 245
    var cruiseAltitude: Double = 11_000

    var routeDistance: Double { GeoMath.distance(origin, destination) }

    #if DEBUG
    /// Sample routes for the `-FGDemo` / `-FGDraft` launch arguments: transatlantic, across
    /// the date line (both hemispheres), near-polar, long-haul, and domestic.
    static let demoRoutes: [String: (origin: String, destination: String)] = [
        "DEMO1": ("LHR", "JFK"),
        "DEMO2": ("SFO", "NRT"),
        "DEMO3": ("SYD", "LAX"),
        "DEMO4": ("DXB", "LAX"),
        "DEMO5": ("SIN", "LHR"),
        "DEMO6": ("JFK", "SFO"),
    ]
    #endif

    /// When the simulated aircraft left the origin.
    var departureDate: Date {
        anchorDate.addingTimeInterval(-startProgress * routeDistance / cruiseSpeed)
    }

    func fix(at date: Date) -> GPSFix {
        let total = max(routeDistance, 1)
        let flown = min(total, max(0, startProgress * total + cruiseSpeed * date.timeIntervalSince(anchorDate)))
        let fraction = flown / total
        let position = GeoMath.interpolate(from: origin, to: destination, fraction: fraction)
        let arrived = flown >= total
        // Simple climb / descent profile so altitude looks plausible near the ends.
        let toGo = total - flown
        let profile = min(1, flown / 180_000, toGo / 220_000)
        // Small deterministic wobble so the readings visibly update.
        let t = date.timeIntervalSince1970
        let wobble = sin(t / 7) * 2.5
        let course: Double? = arrived ? nil : GeoMath.initialBearing(from: position, to: destination)
        let altitude: Double = max(0, cruiseAltitude * profile + sin(t / 13) * 6)
        let accelerating: Double = 0.55 + 0.45 * min(1, flown / 60_000)
        let speed: Double = arrived ? 0 : cruiseSpeed * accelerating + wobble
        let accuracy: Double = 8 + abs(sin(t / 11)) * 6
        return GPSFix(timestamp: date, coordinate: position, horizontalAccuracy: accuracy,
                      altitude: altitude, verticalAccuracy: 12,
                      speed: speed, speedAccuracy: 0.6,
                      course: course, courseAccuracy: course == nil ? nil : 1.5)
    }

    /// Fixes from departure up to `date`, used to backfill the breadcrumb when a demo starts.
    func history(until date: Date, interval: TimeInterval = 20) -> [GPSFix] {
        var fixes: [GPSFix] = []
        var time = departureDate
        while time < date {
            fixes.append(fix(at: time))
            time.addTimeInterval(interval)
        }
        return fixes
    }
}
