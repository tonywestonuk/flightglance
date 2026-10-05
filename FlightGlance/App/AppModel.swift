import Foundation
import Observation
import SwiftUI
import UIKit

/// Route details being entered on the setup screen.
struct FlightDraft: Equatable {
    var origin: Airport?
    var destination: Airport?

    var plan: FlightPlan? {
        guard let origin, let destination, origin != destination else { return nil }
        return FlightPlan(origin: origin, destination: destination)
    }
}

/// Root state: bundled resources, GPS, and the active flight (if any).
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case loading
        case setup
        case inFlight
        case failed(String)
    }

    let location = LocationService()
    let cellular = CellularMonitor()
    private(set) var atlas: WorldAtlas?
    private(set) var airports: AirportDatabase?
    private(set) var places: PlaceFinder?
    private(set) var session: FlightSession?
    /// True while the setup screen is shown to edit a flight that is still recording.
    private(set) var isEditingFlight = false
    private(set) var loadError: String?
    var draft = FlightDraft()
    /// Development only: drive the dashboard from a simulated flight instead of GPS.
    var simulateGPS = false
    /// Seconds between GPS position samples (see `LocationService`).
    var gpsInterval: Int {
        didSet {
            UserDefaults.standard.set(gpsInterval, forKey: Self.gpsIntervalKey)
            location.sampleInterval = TimeInterval(gpsInterval)
        }
    }
    static let gpsIntervalChoices = [15, 30, 60]
    /// Show the flight on the Lock Screen (Live Activity). While locked the GPS is sampled every
    /// 5 minutes and the position is estimated forward from it every 30 seconds.
    var lockScreenUpdates: Bool {
        didSet {
            UserDefaults.standard.set(lockScreenUpdates, forKey: Self.lockScreenKey)
            if lockScreenUpdates { refreshLiveActivity() } else { liveActivity.end() }
        }
    }
    @ObservationIgnored private let liveActivity = LiveActivityController()
    /// Seconds between estimated Lock Screen updates while locked.
    private static let lockScreenEstimateInterval: TimeInterval = 30
    @ObservationIgnored private var lockScreenEstimates: Task<Void, Never>?

    @ObservationIgnored private let store: FlightStore
    @ObservationIgnored private var lastSave = Date.distantPast
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    @ObservationIgnored private var terminationObserver: (any NSObjectProtocol)?

    static let unitsKey = "unitSystem"
    static let mapStyleKey = "mapStyle"
    static let gpsIntervalKey = "gpsInterval"
    static let lockScreenKey = "lockScreenUpdates"

    init(store: FlightStore = .standard) {
        self.store = store
        UserDefaults.standard.register(defaults: [Self.gpsIntervalKey: 30, Self.lockScreenKey: true])
        lockScreenUpdates = UserDefaults.standard.bool(forKey: Self.lockScreenKey)
        let interval = UserDefaults.standard.integer(forKey: Self.gpsIntervalKey)
        gpsInterval = Self.gpsIntervalChoices.contains(interval) ? interval : 30
        location.sampleInterval = TimeInterval(gpsInterval)
        location.onFix = { [weak self] fix in self?.handle(fix) }
        // Swiping the app away while it runs in the background (Lock Screen mode) makes iOS
        // terminate it; clean up so nothing appears to carry on without it.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applicationWillTerminate() }
        }
    }

    var phase: Phase {
        if let loadError { return .failed(loadError) }
        if atlas == nil || airports == nil { return .loading }
        return session == nil || isEditingFlight ? .setup : .inFlight
    }

    // MARK: Lifecycle

    /// Loads the bundled atlas and airport list off the main thread, then resumes any
    /// flight that was in progress when the app last quit.
    func loadResources() async {
        guard atlas == nil else { return }
        do {
            async let atlasTask = Task.detached(priority: .userInitiated) { try WorldAtlas.loadBundled() }.value
            async let airportsTask = Task.detached(priority: .userInitiated) { try AirportDatabase.loadBundled() }.value
            async let placesTask = Task.detached(priority: .utility) { try PlaceFinder.loadBundled() }.value
            let (loadedAtlas, loadedAirports, loadedPlaces) = try await (atlasTask, airportsTask, placesTask)
            atlas = loadedAtlas
            airports = loadedAirports
            places = loadedPlaces
        } catch {
            loadError = "The bundled map data could not be loaded. Please reinstall FlightGlance."
            return
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-FGResetState") { store.clear() }
        #endif
        if let saved = store.load() {
            resume(saved)
        }
        #if DEBUG
        startDemoFromLaunchArgumentsIfNeeded()
        #endif
    }

    /// Off screen, either nothing runs (the GPS stops and iOS suspends the app) or, with the
    /// Lock Screen Live Activity on, the low-power background mode takes a fix every 5 minutes
    /// and estimates the position in between. The switch happens at "inactive" because iOS only
    /// lets location updates continue into the background, not start there. Back on screen a
    /// fresh fix is taken.
    func scenePhaseChanged(to phase: ScenePhase) {
        let keepUpdating = session != nil && lockScreenUpdates && liveActivity.isRunning
        switch phase {
        case .inactive:
            if keepUpdating { enterLowPowerBackground() }
        case .background:
            persist(force: true)
            if keepUpdating { enterLowPowerBackground() } else { location.pause() }
        case .active:
            stopLockScreenEstimates()
            cellular.refresh()
            location.resume()
            refreshLiveActivity()
        @unknown default:
            break
        }
    }

    // MARK: Flight

    /// Starts tracking, or applies the edited details to the flight in progress.
    func startFlight() {
        guard let plan = draft.plan else { return }
        if let current = session, isEditingFlight {
            isEditingFlight = false
            if current.plan == plan && (current.simulation != nil) == simulateGPS { return }
            if current.simulation == nil && !simulateGPS {
                // Same real flight with corrected details: keep the recorded track.
                let updated = FlightSession(plan: plan, startedAt: current.startedAt, recorder: current.recorder,
                                            latestFix: current.latestFix)
                session = updated
                persist(force: true)
                liveActivity.end()
                refreshLiveActivity()
                return
            }
            // Switching to or from simulation (development only): start afresh.
            location.stop()
            session = nil
        }
        var simulation: FlightSimulation?
        #if DEBUG
        if simulateGPS {
            simulation = FlightSimulation(origin: plan.origin.coordinate, destination: plan.destination.coordinate,
                                          anchorDate: Date())
        }
        #endif
        let session = FlightSession(plan: plan, simulation: simulation)
        if let simulation {
            // Backfill the track from departure so the demo shows a breadcrumb immediately.
            for fix in simulation.history(until: Date()) { session.ingest(fix) }
        }
        self.session = session
        startLocation(for: session)
        persist(force: true)
        refreshLiveActivity()
    }

    /// Returns to the setup screen with the current flight filled in. GPS keeps recording.
    func editFlight() {
        guard let session else { return }
        draft = FlightDraft(origin: session.plan.origin, destination: session.plan.destination)
        simulateGPS = session.simulation != nil
        isEditingFlight = true
    }

    func returnToFlight() {
        isEditingFlight = false
    }

    /// The user force-quit the app (or iOS is terminating it). Save the flight so it resumes
    /// next time, stop the GPS, and remove the Lock Screen activity, which would otherwise stay
    /// up showing a frozen position. Must finish within the few seconds iOS allows.
    private func applicationWillTerminate() {
        stopLockScreenEstimates()
        if let session { try? store.save(session.saved) }
        location.stop()
        liveActivity.endBeforeExit()
    }

    func endFlight() {
        isEditingFlight = false
        stopLockScreenEstimates()
        liveActivity.end()
        pendingSave?.cancel()
        location.stop()
        store.clear()
        if let session {
            // Keep the route handy so a connecting or return flight is quick to set up.
            draft = FlightDraft(origin: session.plan.destination, destination: nil)
        }
        session = nil
        if location.authorization == .authorized {
            location.start()
        }
    }

    /// Lets the setup screen warm up GPS (a first fix can take a while inside a cabin).
    func warmUpLocationIfAuthorized() {
        guard session == nil, location.authorization == .authorized, !location.isUpdating else { return }
        location.start()
    }

    private func resume(_ saved: SavedFlight) {
        let session = FlightSession(saved: saved)
        self.session = session
        draft = FlightDraft(origin: saved.plan.origin, destination: saved.plan.destination)
        startLocation(for: session)
    }

    private func startLocation(for session: FlightSession) {
        if let simulation = session.simulation {
            // Simulated positions are a function of wall-clock time, so a resumed demo
            // continues from where the aircraft "would be" now.
            location.startSimulation(simulation)
        } else {
            if location.authorization == .notDetermined { location.requestPermission() }
            location.start()
        }
    }

    private func handle(_ fix: GPSFix) {
        guard let session else { return }
        if session.ingest(fix) { persist(force: false) }
        if lockScreenUpdates, let state = liveActivityState(now: Date()) {
            liveActivity.update(state, inForeground: !location.isLowPower)
        }
    }

    // MARK: Lock Screen

    private func enterLowPowerBackground() {
        location.enterLowPowerBackground()
        if location.isLowPower { startLockScreenEstimates() }
    }

    /// While locked, refreshes the Live Activity every 30 s from the last fix carried forward
    /// along its course and speed, so the country, nearest town and distance to go keep moving
    /// between the 5-minute GPS samples. The GPS stays off; each update is a few milliseconds
    /// of arithmetic. The location session that keeps the app alive also keeps this running.
    private func startLockScreenEstimates() {
        guard lockScreenEstimates == nil else { return }
        lockScreenEstimates = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.lockScreenEstimateInterval))
                guard !Task.isCancelled, let self else { return }
                if self.location.isLowPower, self.lockScreenUpdates,
                   let state = self.liveActivityState(now: Date(), estimated: true) {
                    self.liveActivity.update(state, inForeground: false)
                }
            }
        }
    }

    private func stopLockScreenEstimates() {
        lockScreenEstimates?.cancel()
        lockScreenEstimates = nil
    }

    /// Starts the Live Activity if it should be showing and isn't (first start, after a
    /// relaunch, or after iOS ended it at its 8-hour limit). Only possible in the foreground.
    private func refreshLiveActivity() {
        guard lockScreenUpdates, let session, !liveActivity.isRunning,
              let state = liveActivityState(now: Date()) else { return }
        liveActivity.start(plan: session.plan, state: state)
    }

    /// With `estimated`, the position is the last fix carried forward to `now` (nil when that
    /// isn't reliable, so nothing is pushed). The arrival estimate always comes from the fix.
    private func liveActivityState(now: Date, estimated: Bool = false) -> FlightActivityAttributes.ContentState? {
        guard let session else { return nil }
        guard let fix = session.latestFix else {
            return estimated ? nil : .init(region: "Searching for GPS…", updated: now, isSearching: true)
        }
        var position = fix.coordinate
        if estimated {
            guard let carried = fix.extrapolatedPosition(at: now) else { return nil }
            position = carried
        }
        let units = UnitSystem(rawValue: UserDefaults.standard.string(forKey: Self.unitsKey) ?? "") ?? .aviation
        let signal = GPSSignalState.evaluate(authorization: location.authorization, isSimulated: location.isSimulated,
                                             isUpdating: location.isUpdating, updatesStarted: location.updatesStarted,
                                             lastFix: fix, now: now, sampleInterval: location.effectiveInterval)
        let readings = FlightReadings.make(plan: session.plan, recorder: session.recorder, latestFix: fix,
                                           signal: signal, now: now, sampleInterval: location.effectiveInterval)
        let place = places?.describe(position, units: units)
        var arrival: Date?
        if case .estimate(let estimate) = readings.eta { arrival = estimate.arrival }
        var region = place?.region ?? "Position known"
        if session.simulation != nil { region = "Demo · " + region }
        let plan = session.plan
        let remaining = GeoMath.distance(position, plan.destination.coordinate)
        return .init(region: region, nearestTown: place?.nearestTown,
                     distanceToGo: ReadingFormatter.distance(remaining, units: units).joined, arrival: arrival,
                     progress: GeoMath.routeProgress(of: position, from: plan.origin.coordinate,
                                                     to: plan.destination.coordinate),
                     updated: fix.timestamp, isSearching: false)
    }

    /// Saves the track at most every 30 s (or immediately when forced) so a crash or
    /// relaunch mid-flight loses very little.
    private func persist(force: Bool) {
        guard let session else { return }
        guard force || Date().timeIntervalSince(lastSave) > 30 else { return }
        lastSave = Date()
        let snapshot = session.saved
        let store = self.store
        pendingSave?.cancel()
        pendingSave = Task.detached(priority: .utility) {
            try? store.save(snapshot)
        }
    }

    #if DEBUG
    /// Debug-only launch arguments for demos and screenshots:
    /// * `-FGDemo DEMO1`  start a flight on a sample route (simulated GPS)
    /// * `-FGLive YES`    with -FGDemo, use real Core Location instead of the simulator
    /// * `-FGDraft DEMO1` only pre-fill the setup screen with a sample route
    /// * `-FGEdit YES`    with -FGDemo, open the edit screen for the running flight
    private func startDemoFromLaunchArgumentsIfNeeded() {
        let defaults = UserDefaults.standard
        guard session == nil, let code = defaults.string(forKey: "FGDemo") ?? defaults.string(forKey: "FGDraft"),
              let route = FlightSimulation.demoRoutes[code.uppercased()],
              let airports,
              let origin = airports.airport(code: route.origin),
              let destination = airports.airport(code: route.destination) else { return }
        draft = FlightDraft(origin: origin, destination: destination)
        guard defaults.string(forKey: "FGDemo") != nil else { return }
        simulateGPS = !defaults.bool(forKey: "FGLive")
        startFlight()
        if defaults.bool(forKey: "FGEdit") { editFlight() }
    }
    #endif
}
