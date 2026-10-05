import CoreLocation
import Foundation
import Observation

/// Owns Core Location and publishes validated GPS fixes.
///
/// GPS is a receive-only radio, so it keeps working in Airplane Mode; nothing here touches
/// the network.
///
/// **Power.** Following a flight doesn't need satnav-style continuous tracking, so the GPS is
/// duty-cycled: every `sampleInterval` seconds it is switched on until it produces one good
/// fix (usually a few seconds — the receiver keeps its satellite data warm between samples),
/// then switched off again.
///
/// **Getting a lock.** That only works once the receiver has a lock. Starting cold (no recent
/// satellite data, which in Airplane Mode it can't download) a first fix can take minutes of
/// continuous listening, and switching the GPS off every sample would throw that work away.
/// So without a recent good fix the GPS stays on until it gets one (in the low-power mode,
/// for up to 2 minutes per sample), and the duty cycle starts from there.
///
/// Off screen there are two options, chosen by the app:
/// * `pause()`: the GPS stops and iOS suspends the app.
/// * `enterLowPowerBackground()`: for the Lock Screen Live Activity. The GPS is sampled only
///   every `backgroundInterval` (5 min), aiming for a looser ~100 m fix and giving up after
///   30 s. iOS suspends apps that stop location updates, so between samples the manager is
///   left running with a coarse request (3 km, huge distance filter) that keeps the app
///   alive without needing the GPS receiver. No map is drawn; the app only refreshes the
///   Live Activity every 30 s from a position estimated off the last fix.
/// `resume()` returns to normal and takes a fresh fix straight away.
@MainActor
@Observable
final class LocationService {
    private(set) var authorization: LocationAuthorization
    /// False when the user has turned off "Precise Location" for the app (fixes ~1–10 km).
    private(set) var isPrecise = true
    private(set) var latestFix: GPSFix?
    private(set) var isUpdating = false
    private(set) var updatesStarted: Date?
    private(set) var simulation: FlightSimulation?

    /// Seconds between position samples.
    var sampleInterval: TimeInterval = 30 {
        didSet { if oldValue != sampleInterval { rescheduleAfterIntervalChange() } }
    }
    /// Seconds between samples in the low-power background mode.
    let backgroundInterval: TimeInterval = 5 * 60
    /// True while running off screen in the low-power background mode.
    private(set) var isLowPower = false

    /// The sampling interval currently in force.
    var effectiveInterval: TimeInterval { isLowPower ? backgroundInterval : sampleInterval }
    /// Longest the GPS stays on hunting for a fix in each sample. On screen, a sample that ends
    /// without a lock goes straight into the next one (see `isAcquiring`).
    var acquisitionTimeout: TimeInterval { isLowPower ? (isAcquiring ? 120 : 30) : 45 }
    /// A fix at least this accurate ends the sample straight away.
    var goodEnoughAccuracy: Double { isLowPower ? 1_000 : 100 }

    var isSimulated: Bool { simulation != nil }

    /// Called for every accepted fix (real or simulated).
    @ObservationIgnored var onFix: ((GPSFix) -> Void)?

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var delegateProxy: DelegateProxy?
    @ObservationIgnored private var cycleTask: Task<Void, Never>?
    @ObservationIgnored private var wantsUpdates = false
    @ObservationIgnored private var isPaused = false
    @ObservationIgnored private var isSampling = false
    @ObservationIgnored private var sampleStarted: Date?
    @ObservationIgnored private var bestInSample: GPSFix?
    /// When the receiver last produced a fix accurate enough to count as a GPS lock.
    @ObservationIgnored private var lastLockTime: Date?

    /// No lock recently, so the receiver may be starting cold and needs to listen for longer.
    private var isAcquiring: Bool {
        guard let lastLockTime else { return true }
        return Date().timeIntervalSince(lastLockTime) > 2 * effectiveInterval
    }

    /// Fixes older than this on arrival are cached positions, not live ones.
    private let maximumFixAgeOnArrival: TimeInterval = 30

    init() {
        authorization = Self.map(manager.authorizationStatus)
        isPrecise = manager.accuracyAuthorization == .fullAccuracy
        manager.activityType = .airborne
        manager.pausesLocationUpdatesAutomatically = false
        let proxy = DelegateProxy(owner: self)
        delegateProxy = proxy
        manager.delegate = proxy
        refreshServicesEnabled()
    }

    // MARK: Permission

    func requestPermission() {
        manager.requestWhenInUseAuthorization()
    }

    /// Asks for precise location for this session when the user has it switched off.
    func requestTemporaryPreciseLocation() {
        manager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: "FlightTracking")
    }

    // MARK: Updates

    /// Starts sampling the GPS. If permission hasn't been granted yet, sampling starts as
    /// soon as it is.
    func start() {
        guard simulation == nil else { return }
        wantsUpdates = true
        guard authorization == .authorized, !isPaused, !isUpdating else { return }
        updatesStarted = Date()
        isUpdating = true
        beginSample()
    }

    func stop() {
        cycleTask?.cancel()
        cycleTask = nil
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        isLowPower = false
        wantsUpdates = false
        isSampling = false
        bestInSample = nil
        simulation = nil
        isUpdating = false
        updatesStarted = nil
        latestFix = nil
        lastLockTime = nil
    }

    /// The app is leaving the screen: switch the GPS off and let iOS suspend the app.
    func pause() {
        guard !isPaused else { return }
        isPaused = true
        cycleTask?.cancel()
        cycleTask = nil
        manager.stopUpdatingLocation()
        isSampling = false
        bestInSample = nil
        isUpdating = false
    }

    /// Back on screen: take a fresh fix straight away, then continue the normal cycle.
    func resume() {
        if isLowPower {
            isLowPower = false
            manager.allowsBackgroundLocationUpdates = false
            manager.stopUpdatingLocation()
            updatesStarted = Date()
            if let simulation {
                startSimulation(simulation)
            } else {
                beginSample()
            }
            return
        }
        guard isPaused else { return }
        isPaused = false
        if let simulation {
            startSimulation(simulation)
        } else if wantsUpdates {
            start()
        }
    }

    /// Off screen with a Lock Screen Live Activity to keep up to date. Must be called while
    /// the app is still active or just becoming inactive: with "While Using" permission, iOS
    /// only lets location updates *continue* into the background, not start there.
    func enterLowPowerBackground() {
        if isLowPower { return }
        guard authorization == .authorized, wantsUpdates || simulation != nil else {
            pause()
            return
        }
        isPaused = false
        isLowPower = true
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        if let simulation {
            keepAlive()
            startSimulation(simulation)
        } else if isSampling {
            // The sample in progress finishes, then rests in keep-alive mode.
        } else {
            keepAlive()
            scheduleSample(at: max(Date(), (sampleStarted ?? Date()).addingTimeInterval(backgroundInterval)))
        }
    }

    /// Keeps the location session (and so the app) alive without needing the GPS receiver.
    private func keepAlive() {
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.distanceFilter = CLLocationDistanceMax
        manager.startUpdatingLocation()
    }

    /// Replaces live GPS with a simulated flight (development builds only). It reports at the
    /// same interval as the real GPS would.
    func startSimulation(_ simulation: FlightSimulation) {
        cycleTask?.cancel()
        if !isLowPower { manager.stopUpdatingLocation() }
        isSampling = false
        self.simulation = simulation
        guard !isPaused else { return }
        isUpdating = true
        updatesStarted = Date()
        cycleTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let simulation = self.simulation else { return }
                self.deliver(simulation.fix(at: Date()))
                try? await Task.sleep(for: .seconds(self.effectiveInterval))
            }
        }
    }

    // MARK: Sampling cycle

    private func beginSample() {
        cycleTask?.cancel()
        isSampling = true
        sampleStarted = Date()
        bestInSample = nil
        // Low power: a looser fix is plenty for "35 km SW of Lyon" and comes sooner.
        manager.desiredAccuracy = isLowPower ? kCLLocationAccuracyHundredMeters : kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        manager.startUpdatingLocation()
        let timeout = acquisitionTimeout
        cycleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            self?.endSample()
        }
    }

    private func endSample() {
        guard isSampling else { return }
        isSampling = false
        // No good fix in time: a weaker one still beats nothing (the UI flags it as weak).
        if let best = bestInSample { deliver(best) }
        bestInSample = nil
        if !isLowPower, isAcquiring {
            // Still no lock: keep the GPS listening rather than restart its search later.
            beginSample()
            return
        }
        if isLowPower { keepAlive() } else { manager.stopUpdatingLocation() }
        let next = max(Date().addingTimeInterval(2), (sampleStarted ?? Date()).addingTimeInterval(effectiveInterval))
        scheduleSample(at: next)
    }

    private func scheduleSample(at date: Date) {
        cycleTask?.cancel()
        cycleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, date.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            self?.beginSample()
        }
    }

    private func rescheduleAfterIntervalChange() {
        if let simulation {
            startSimulation(simulation)
        } else if isUpdating, !isSampling {
            scheduleSample(at: max(Date(), (sampleStarted ?? Date()).addingTimeInterval(effectiveInterval)))
        }
    }

    // MARK: Delegate handling

    fileprivate func handle(locations: [CLLocation]) {
        // Late deliveries after a sample has ended are ignored.
        guard simulation == nil, isSampling, let sampleStarted else { return }
        for location in locations {
            // Drop cached positions that Core Location replays when updates start.
            guard -location.timestamp.timeIntervalSinceNow <= maximumFixAgeOnArrival,
                  location.timestamp >= sampleStarted.addingTimeInterval(-1) else { continue }
            let fix = GPSFix(location: location)
            guard fix.hasValidPosition else { continue }
            if let last = latestFix, fix.timestamp <= last.timestamp { continue }
            if fix.horizontalAccuracy <= goodEnoughAccuracy {
                bestInSample = nil
                deliver(fix)
                endSample()
                return
            }
            if bestInSample.map({ fix.horizontalAccuracy < $0.horizontalAccuracy }) ?? true {
                bestInSample = fix
            }
        }
    }

    private func deliver(_ fix: GPSFix) {
        if fix.horizontalAccuracy <= 100 { lastLockTime = fix.timestamp }
        latestFix = fix
        onFix?(fix)
    }

    fileprivate func handle(error: Error) {
        guard let error = error as? CLError else { return }
        switch error.code {
        case .denied:
            // Permission was revoked while running.
            cycleTask?.cancel()
            manager.stopUpdatingLocation()
            isSampling = false
            isUpdating = false
            authorization = .denied
            refreshServicesEnabled()
        default:
            // .locationUnknown and friends are transient: the sample keeps trying until its
            // timeout, and the signal indicator reports "lost" if fixes stop arriving.
            break
        }
    }

    fileprivate func handleAuthorizationChange() {
        authorization = Self.map(manager.authorizationStatus)
        isPrecise = manager.accuracyAuthorization == .fullAccuracy
        refreshServicesEnabled()
        if authorization == .authorized, wantsUpdates, simulation == nil {
            start()
        }
    }

    /// When Location Services are off for the whole device, apps just see `.denied`. This
    /// tells the two apart so the app can give the right instructions.
    /// `locationServicesEnabled()` can block, so it is queried off the main thread.
    private func refreshServicesEnabled() {
        Task.detached(priority: .utility) {
            let enabled = CLLocationManager.locationServicesEnabled()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.authorization = enabled ? Self.map(self.manager.authorizationStatus) : .servicesOff
            }
        }
    }

    private static func map(_ status: CLAuthorizationStatus) -> LocationAuthorization {
        switch status {
        case .notDetermined: .notDetermined
        case .authorizedAlways, .authorizedWhenInUse: .authorized
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .denied
        }
    }

    /// Core Location calls its delegate on the thread that created the manager (main), so
    /// the proxy can safely hop straight onto the main actor.
    private final class DelegateProxy: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
        weak var owner: LocationService?

        init(owner: LocationService) {
            self.owner = owner
        }

        func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
            MainActor.assumeIsolated { owner?.handle(locations: locations) }
        }

        func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
            MainActor.assumeIsolated { owner?.handle(error: error) }
        }

        func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
            MainActor.assumeIsolated { owner?.handleAuthorizationChange() }
        }
    }
}
