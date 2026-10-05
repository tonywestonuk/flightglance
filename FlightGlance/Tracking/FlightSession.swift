import Foundation
import Observation

/// An active flight: the plan, the recorded track, and map geometry derived from them.
@MainActor
@Observable
final class FlightSession {
    let plan: FlightPlan
    let startedAt: Date
    /// Non-nil when this flight is driven by the development simulator.
    let simulation: FlightSimulation?
    private(set) var recorder: TrackRecorder
    /// The most recent position report of any quality.
    private(set) var latestFix: GPSFix?

    /// Dashed reference line: the great circle from the latest position (or the origin before
    /// the first fix) to the destination, longitudes unwrapped to sit next to the track.
    private(set) var route: [GeoPoint] = []
    /// Observed track, longitudes unwrapped to stay continuous, split at signal gaps.
    private(set) var track: [[GeoPoint]] = []
    /// Connectors drawn across signal gaps.
    private(set) var gaps: [[GeoPoint]] = []
    /// Unwrapped longitude of the newest track point, to keep the track continuous.
    @ObservationIgnored private var lastUnwrappedLongitude: Double

    init(plan: FlightPlan, startedAt: Date = Date(), recorder: TrackRecorder = TrackRecorder(),
         simulation: FlightSimulation? = nil, latestFix: GPSFix? = nil) {
        self.plan = plan
        self.startedAt = startedAt
        self.recorder = recorder
        self.simulation = simulation
        self.latestFix = latestFix
        lastUnwrappedLongitude = plan.origin.longitude
        for point in recorder.points { appendTrack(point) }
        updateRoute()
    }

    convenience init(saved: SavedFlight) {
        self.init(plan: saved.plan, startedAt: saved.startedAt, recorder: saved.recorder, simulation: saved.simulation)
    }

    var saved: SavedFlight {
        SavedFlight(plan: plan, startedAt: startedAt, recorder: recorder, simulation: simulation)
    }

    /// Feeds a GPS fix into the session. Returns true if a breadcrumb was added.
    @discardableResult
    func ingest(_ fix: GPSFix) -> Bool {
        let isNewest = latestFix.map { fix.timestamp > $0.timestamp } ?? true
        if isNewest { latestFix = fix }
        var added = false
        if recorder.ingest(fix) == .added, let point = recorder.points.last {
            appendTrack(point)
            added = true
        }
        if isNewest || added { updateRoute() }
        return added
    }

    private func updateRoute() {
        route = GeoMath.greatCirclePath(from: aircraftPosition ?? plan.origin.coordinate,
                                        to: plan.destination.coordinate)
    }

    private func appendTrack(_ point: TrackPoint) {
        let unwrapped = GeoPoint(latitude: point.latitude,
                                 longitude: GeoMath.unwrap(point.longitude, near: lastUnwrappedLongitude))
        if point.startsNewSegment, let previous = track.last?.last {
            gaps.append([previous, unwrapped])
            track.append([unwrapped])
        } else if track.isEmpty {
            track.append([unwrapped])
        } else {
            track[track.count - 1].append(unwrapped)
        }
        lastUnwrappedLongitude = unwrapped.longitude
    }

    // MARK: Map overlay

    /// A coordinate with its longitude unwrapped to sit next to the recorded track.
    func unwrapped(_ coordinate: GeoPoint) -> GeoPoint {
        GeoPoint(latitude: coordinate.latitude, longitude: GeoMath.unwrap(coordinate.longitude, near: lastUnwrappedLongitude))
    }

    var aircraftPosition: GeoPoint? {
        latestFix.map { unwrapped($0.coordinate) }
    }

    func overlay(isLive: Bool) -> MapOverlay {
        var overlay = MapOverlay()
        overlay.route = route
        overlay.track = track
        overlay.gaps = gaps
        // The origin's longitude is the unwrapping reference, so it needs no adjustment.
        if let destination = route.last {
            overlay.markers = [
                .init(code: plan.origin.iata, coordinate: plan.origin.coordinate, role: .origin),
                .init(code: plan.destination.iata, coordinate: destination, role: .destination),
            ]
        }
        if let fix = latestFix {
            overlay.aircraft = .init(coordinate: unwrapped(fix.coordinate), course: fix.usableCourse,
                                     isLive: isLive, accuracy: fix.horizontalAccuracy)
        }
        return overlay
    }

    /// Everything worth framing: the route, the track, both airports and the aircraft.
    var framingPoints: [GeoPoint] {
        overlay(isLive: true).framingPoints
    }
}

/// A snapshot of every dashboard reading at one instant. Computed once per second from the
/// session and GPS state so all tiles agree with each other and with the status indicator.
struct FlightReadings: Equatable {
    var signal: GPSSignalState
    /// The fix to show as live readings; nil when the signal is lost or unavailable.
    var liveFix: GPSFix?
    var lastFixTime: Date?
    var distanceTraveled: Double
    /// Great-circle distance from the latest known position to the destination.
    var remainingDistance: Double?
    /// Fraction of the reference route completed (along-track).
    var progress: Double?
    var eta: ETAEstimator.Result

    static func make(plan: FlightPlan, recorder: TrackRecorder, latestFix: GPSFix?,
                     signal: GPSSignalState, now: Date, sampleInterval: TimeInterval = 30) -> FlightReadings {
        let position = latestFix?.coordinate
        let destination = plan.destination.coordinate
        return FlightReadings(
            signal: signal,
            liveFix: signal.isLive ? latestFix : nil,
            lastFixTime: latestFix?.timestamp,
            distanceTraveled: recorder.distanceTraveled,
            remainingDistance: position.map { GeoMath.distance($0, destination) },
            progress: position.map { GeoMath.routeProgress(of: $0, from: plan.origin.coordinate, to: destination) },
            eta: ETAEstimator.estimate(position: position, fixTime: latestFix?.timestamp, destination: destination,
                                       speedSamples: recorder.speedSamples, track: recorder.points, now: now,
                                       configuration: .forSampling(every: sampleInterval))
        )
    }
}
