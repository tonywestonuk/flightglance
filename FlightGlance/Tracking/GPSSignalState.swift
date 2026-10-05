import Foundation

/// Location permission, simplified for the UI.
enum LocationAuthorization: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
    case restricted
    /// Location Services are switched off for the whole device.
    case servicesOff
}

/// What the GPS status indicator shows. Derived purely from inputs so it can be re-evaluated
/// every second (to notice signal loss) and unit tested.
enum GPSSignalState: Equatable, Sendable {
    case simulated
    case permissionNeeded
    case denied
    case restricted
    case servicesOff
    /// Authorised, waiting for a first fix.
    case acquiring
    case good(accuracy: Double)
    case weak(accuracy: Double)
    /// No fix for a while. `lastFix` is nil if there never was one.
    case lost(lastFix: Date?)

    struct Thresholds: Sendable {
        /// Fixes better than this are "good". Phones at a cabin window are typically 5–50 m.
        var goodAccuracy: Double = 100
        /// No new fix for this long means the signal is lost.
        var lostAfter: TimeInterval
        /// Give up "acquiring" and say "no signal" after this long without any fix.
        var acquiringTimeout: TimeInterval

        /// The GPS is sampled every `sampleInterval` seconds and may hunt for up to
        /// `acquisitionTimeout` seconds, so only call the signal lost once a whole cycle has
        /// passed with no fix, plus some slack.
        init(sampleInterval: TimeInterval, acquisitionTimeout: TimeInterval = 45) {
            lostAfter = max(20, sampleInterval + acquisitionTimeout + 15)
            acquiringTimeout = max(90, acquisitionTimeout + 45)
        }
    }

    static func evaluate(authorization: LocationAuthorization,
                         isSimulated: Bool,
                         isUpdating: Bool,
                         updatesStarted: Date?,
                         lastFix: GPSFix?,
                         now: Date,
                         sampleInterval: TimeInterval = 30) -> GPSSignalState {
        let thresholds = Thresholds(sampleInterval: sampleInterval)
        if isSimulated { return .simulated }
        switch authorization {
        case .notDetermined: return .permissionNeeded
        case .denied: return .denied
        case .restricted: return .restricted
        case .servicesOff: return .servicesOff
        case .authorized: break
        }
        // No fix yet since the GPS was (re)started, e.g. just after unlocking the phone.
        guard let lastFix, lastFix.timestamp >= updatesStarted ?? .distantPast else {
            if let updatesStarted, now.timeIntervalSince(updatesStarted) > thresholds.acquiringTimeout {
                return .lost(lastFix: lastFix?.timestamp)
            }
            return .acquiring
        }
        if !isUpdating || now.timeIntervalSince(lastFix.timestamp) > thresholds.lostAfter {
            return .lost(lastFix: lastFix.timestamp)
        }
        return lastFix.horizontalAccuracy <= thresholds.goodAccuracy
            ? .good(accuracy: lastFix.horizontalAccuracy)
            : .weak(accuracy: lastFix.horizontalAccuracy)
    }

    /// True when the latest fix may be shown as a live reading.
    var isLive: Bool {
        switch self {
        case .good, .weak, .simulated: true
        default: false
        }
    }
}
