import CoreTelephony
import Foundation
import Observation

/// Whether the phone is connected to a mobile network, used to remind the user that Airplane
/// Mode is off.
///
/// iOS has no public API for the Airplane Mode switch itself. A connected cellular radio means
/// it is definitely off; no connection could mean Airplane Mode, no SIM or no coverage. So this
/// only ever errs towards *not* showing the reminder. It reads the radio's local state and makes
/// no network requests.
@MainActor
@Observable
final class CellularMonitor {
    private(set) var isConnected = false

    @ObservationIgnored private let networkInfo = CTTelephonyNetworkInfo()
    @ObservationIgnored private var observer: (any NSObjectProtocol)?

    init() {
        refresh()
        observer = NotificationCenter.default.addObserver(
            forName: .CTServiceRadioAccessTechnologyDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// Re-reads the radio state (also called when the app comes back on screen, e.g. after
    /// Airplane Mode was switched in Control Center).
    func refresh() {
        #if DEBUG
        // `-FGCellular YES` pretends to be connected, to see the reminder in the simulator.
        if UserDefaults.standard.bool(forKey: "FGCellular") {
            isConnected = true
            return
        }
        #endif
        let technologies = networkInfo.serviceCurrentRadioAccessTechnology ?? [:]
        isConnected = !technologies.isEmpty
    }
}
