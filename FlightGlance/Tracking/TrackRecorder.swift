import Foundation

/// Records the observed GPS breadcrumb and the distance travelled along it.
///
/// This is a plain value type with no Core Location dependency so its filtering rules can be
/// unit tested with synthetic fixes.
struct TrackRecorder: Codable, Equatable, Sendable {
    struct Configuration: Equatable, Sendable {
        /// Fixes less accurate than this are not added to the track (but may still be shown).
        var maximumHorizontalAccuracy: Double = 1_500
        /// Minimum spacing between stored breadcrumbs. Keeps a 15-hour flight to ~15k points.
        var minimumSpacing: Double = 800
        /// A gap longer than this between breadcrumbs is drawn as "not observed".
        var gapInterval: TimeInterval = 120
        /// Ground speeds above this between two fixes are treated as a GPS glitch.
        /// (Record airliner ground speeds in a jet stream are ~360 m/s.)
        var maximumPlausibleSpeed: Double = 450
        /// After this many consecutive outliers, assume the *previous* point was the bad
        /// one and restart the track from the new position.
        var outlierResetCount = 5
        /// How much speed history to keep for the arrival estimate (enough for the longest
        /// averaging window, used when sampling every 5 minutes).
        var speedHistoryWindow: TimeInterval = 20 * 60
    }

    enum IngestResult: Equatable {
        case added
        case tooClose
        case inaccurate
        case outlier
        case outOfOrder
    }

    private(set) var points: [TrackPoint] = []
    /// Sum of great-circle distances between consecutive breadcrumbs, in metres.
    private(set) var distanceTraveled: Double = 0
    /// Recent valid GPS ground-speed readings, used for the arrival estimate.
    private(set) var speedSamples: [SpeedSample] = []
    private var consecutiveOutliers = 0
    private var lastAccuracy: Double = 0
    /// Time of the last usable fix, stored or not. Signal gaps are measured from this so slow
    /// taxiing (few stored points) is not mistaken for signal loss.
    private var lastFixTime: Date?

    var configuration = Configuration()

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    enum CodingKeys: String, CodingKey {
        case points, distanceTraveled, speedSamples, lastAccuracy, lastFixTime
    }

    @discardableResult
    mutating func ingest(_ fix: GPSFix) -> IngestResult {
        guard fix.hasValidPosition, fix.horizontalAccuracy <= configuration.maximumHorizontalAccuracy else {
            return .inaccurate
        }
        if let lastFixTime, fix.timestamp <= lastFixTime {
            return .outOfOrder
        }
        let gapBefore = lastFixTime.map { fix.timestamp.timeIntervalSince($0) > configuration.gapInterval } ?? false
        lastFixTime = fix.timestamp

        recordSpeed(from: fix)

        guard let last = points.last else {
            append(fix, startsNewSegment: false)
            return .added
        }

        let distance = GeoMath.distance(last.coordinate, fix.coordinate)
        let elapsed = fix.timestamp.timeIntervalSince(last.timestamp)

        // Reject physically impossible jumps, allowing for the stated uncertainty of both fixes.
        let uncertainty = lastAccuracy + fix.horizontalAccuracy
        if elapsed > 0, (distance - uncertainty) / elapsed > configuration.maximumPlausibleSpeed {
            consecutiveOutliers += 1
            if consecutiveOutliers >= configuration.outlierResetCount {
                consecutiveOutliers = 0
                append(fix, startsNewSegment: true)
                return .added
            }
            return .outlier
        }
        consecutiveOutliers = 0

        // Ignore jitter: movement must exceed both the spacing and the combined uncertainty.
        guard distance >= max(configuration.minimumSpacing, uncertainty) else {
            return .tooClose
        }

        distanceTraveled += distance
        append(fix, startsNewSegment: gapBefore)
        return .added
    }

    private mutating func append(_ fix: GPSFix, startsNewSegment: Bool) {
        points.append(TrackPoint(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude,
                                 timestamp: fix.timestamp, startsNewSegment: startsNewSegment))
        lastAccuracy = fix.horizontalAccuracy
    }

    private mutating func recordSpeed(from fix: GPSFix) {
        guard let speed = fix.speed else { return }
        if let last = speedSamples.last, fix.timestamp <= last.timestamp { return }
        speedSamples.append(SpeedSample(timestamp: fix.timestamp, speed: speed))
        let cutoff = fix.timestamp.addingTimeInterval(-configuration.speedHistoryWindow)
        if let firstKept = speedSamples.firstIndex(where: { $0.timestamp >= cutoff }), firstKept > 0 {
            speedSamples.removeFirst(firstKept)
        }
    }
}

struct SpeedSample: Codable, Equatable, Sendable {
    var timestamp: Date
    /// Metres per second.
    var speed: Double

    enum CodingKeys: String, CodingKey { case timestamp = "t", speed = "v" }
}
