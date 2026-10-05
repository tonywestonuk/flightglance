import ActivityKit
import Foundation

/// The Lock Screen / Dynamic Island Live Activity for a flight in progress.
/// Shared between the app (which starts and updates it) and the widget extension (which draws it).
struct FlightActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        /// "Over France", "Over the North Atlantic Ocean", or a status such as "Searching for GPS…".
        var region: String
        /// "35 km SW of Lyon".
        var nearestTown: String?
        /// "1,944 nm".
        var distanceToGo: String?
        /// Estimated arrival (GPS-based estimate), if available.
        var arrival: Date?
        /// Fraction of the great-circle route completed.
        var progress: Double?
        /// Time of the GPS fix this content is based on.
        var updated: Date
        /// No current position: the views show a searching state.
        var isSearching: Bool
    }

    /// IATA codes, e.g. "LHR" and "JFK".
    var origin: String
    var destination: String
    /// Destination's time zone, so the landing time can be shown in local time.
    var destinationTimeZone: String?
}
