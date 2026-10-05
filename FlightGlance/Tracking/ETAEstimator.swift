import Foundation

/// Estimates time of arrival from GPS data alone.
///
/// Method (shown to the user in "About these readings"):
///
///     time remaining = remaining great-circle distance ÷ average recent GPS ground speed
///
/// * Remaining distance is measured from the latest GPS position to the destination airport
///   along the great circle. Real flights rarely fly exactly that line and add an approach
///   pattern, so the estimate tends to be a little early.
/// * Speed is the mean of the GPS receiver's ground-speed readings over the last five minutes,
///   which smooths turns and noise. If the receiver reports no speed, the average speed along
///   the recorded track over the same window is used instead.
/// * The estimate is anchored to the time of the last fix: arrival = fix time + remaining
///   time. During a short signal loss it therefore keeps counting down sensibly instead of
///   freezing, and it is withdrawn once the last fix is too old to be trusted.
/// * No estimate is made when speed is unknown or too low (taxiing, holding at the gate),
///   which would otherwise produce meaningless multi-day arrival times.
enum ETAEstimator {
    struct Configuration: Equatable, Sendable {
        /// Speed averaging window.
        var averagingWindow: TimeInterval = 5 * 60
        /// Readings needed inside the window before trusting the average.
        var minimumSamples = 3
        /// Below this ground speed (m/s, ≈ 49 kt) the aircraft is assumed not to be en route.
        var minimumGroundSpeed: Double = 25
        /// Withdraw the estimate when the last fix is older than this.
        var maximumFixAge: TimeInterval = 15 * 60
        /// Within this distance of the destination we report "arriving" instead of a time.
        var arrivalRadius: Double = 5_000
        /// Longer than any scheduled flight; anything above this is not credible.
        var maximumDuration: TimeInterval = 24 * 3600

        /// The averaging window must hold a few fixes, so it stretches when the GPS is
        /// sampled less often (every 5 minutes on the Lock Screen gives a ~16-minute window).
        static func forSampling(every interval: TimeInterval) -> Configuration {
            var configuration = Configuration()
            configuration.averagingWindow = max(5 * 60, interval * 3.2)
            return configuration
        }
    }

    enum Method: Equatable, Sendable {
        case gpsGroundSpeed
        case trackAverage
    }

    struct Estimate: Equatable, Sendable {
        var remainingDistance: Double
        var groundSpeed: Double
        var arrival: Date
        var method: Method
        /// Time remaining measured from `now`.
        var timeRemaining: TimeInterval
    }

    enum Unavailable: Equatable, Sendable {
        case noPosition
        case noSpeed
        case speedTooLow
        case fixTooOld
        case notCredible
    }

    enum Result: Equatable, Sendable {
        case estimate(Estimate)
        case arriving
        case unavailable(Unavailable)
    }

    static func estimate(position: GeoPoint?,
                         fixTime: Date?,
                         destination: GeoPoint,
                         speedSamples: [SpeedSample],
                         track: [TrackPoint],
                         now: Date,
                         configuration: Configuration = Configuration()) -> Result {
        guard let position, let fixTime else { return .unavailable(.noPosition) }
        guard now.timeIntervalSince(fixTime) <= configuration.maximumFixAge else {
            return .unavailable(.fixTooOld)
        }

        let remaining = GeoMath.distance(position, destination)
        if remaining <= configuration.arrivalRadius { return .arriving }

        let speed: Double
        let method: Method
        if let gps = averageSpeed(of: speedSamples, endingAt: fixTime, configuration: configuration) {
            speed = gps
            method = .gpsGroundSpeed
        } else if let derived = trackSpeed(of: track, endingAt: fixTime, window: configuration.averagingWindow) {
            speed = derived
            method = .trackAverage
        } else {
            return .unavailable(.noSpeed)
        }

        guard speed.isFinite, speed >= configuration.minimumGroundSpeed else {
            return .unavailable(.speedTooLow)
        }

        let duration = remaining / speed
        guard duration.isFinite, duration <= configuration.maximumDuration else {
            return .unavailable(.notCredible)
        }

        let arrival = fixTime.addingTimeInterval(duration)
        return .estimate(Estimate(remainingDistance: remaining, groundSpeed: speed, arrival: arrival,
                                  method: method, timeRemaining: max(0, arrival.timeIntervalSince(now))))
    }

    /// Mean GPS ground speed over the window ending at `end`, or nil with too few readings.
    static func averageSpeed(of samples: [SpeedSample], endingAt end: Date,
                             configuration: Configuration = Configuration()) -> Double? {
        let start = end.addingTimeInterval(-configuration.averagingWindow)
        let window = samples.filter { $0.timestamp >= start && $0.timestamp <= end && $0.speed.isFinite && $0.speed >= 0 }
        guard window.count >= configuration.minimumSamples else { return nil }
        return window.reduce(0) { $0 + $1.speed } / Double(window.count)
    }

    /// Average speed along the recorded breadcrumbs inside the window (distance ÷ time).
    /// Ignores stretches across signal gaps, whose path was not observed.
    static func trackSpeed(of track: [TrackPoint], endingAt end: Date, window: TimeInterval) -> Double? {
        let start = end.addingTimeInterval(-window)
        let recent = track.filter { $0.timestamp >= start && $0.timestamp <= end }
        guard recent.count >= 2 else { return nil }
        var distance = 0.0, time = 0.0
        for (a, b) in zip(recent, recent.dropFirst()) where !b.startsNewSegment {
            distance += GeoMath.distance(a.coordinate, b.coordinate)
            time += b.timestamp.timeIntervalSince(a.timestamp)
        }
        guard time >= 30 else { return nil }
        return distance / time
    }
}
