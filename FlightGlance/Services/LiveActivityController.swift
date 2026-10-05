import ActivityKit
import Foundation

/// Starts, updates and ends the flight's Lock Screen Live Activity.
@MainActor
final class LiveActivityController {
    private var activity: Activity<FlightActivityAttributes>?
    private var lastState: FlightActivityAttributes.ContentState?
    private var lastPush = Date.distantPast

    /// Content older than this is shown as stale ("No recent GPS") by the system.
    private let staleAfter: TimeInterval = 12 * 60

    var isAvailable: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    var isRunning: Bool {
        guard let activity else { return false }
        return activity.activityState == .active || activity.activityState == .stale
    }

    /// Starts an activity for the flight, or re-attaches to one already running (e.g. after
    /// the app was relaunched). iOS only allows starting while the app is in the foreground,
    /// and ends activities after 8 hours, so this is called again whenever the app is opened.
    func start(plan: FlightPlan, state: FlightActivityAttributes.ContentState) {
        guard isAvailable, !isRunning else { return }
        let attributes = FlightActivityAttributes(origin: plan.origin.iata, destination: plan.destination.iata,
                                                  destinationTimeZone: plan.destination.timeZoneIdentifier)
        if let existing = Activity<FlightActivityAttributes>.activities.first(where: {
            $0.attributes.origin == attributes.origin && $0.attributes.destination == attributes.destination
                && ($0.activityState == .active || $0.activityState == .stale)
        }) {
            activity = existing
            return
        }
        let previous = Activity<FlightActivityAttributes>.activities.map(\.id)
        Self.end(ids: previous)
        activity = try? Activity.request(
            attributes: attributes,
            content: ActivityContent(state: state, staleDate: state.updated.addingTimeInterval(staleAfter)),
            pushType: nil)
        lastState = state
        lastPush = Date()
    }

    /// Pushes new content. Skips updates that wouldn't change what's shown, and in the
    /// foreground (fixes every 30 s) limits updates to one a minute.
    func update(_ state: FlightActivityAttributes.ContentState, inForeground: Bool) {
        guard let activity, isRunning else { return }
        var comparable = state
        comparable.updated = lastState?.updated ?? state.updated
        let changed = comparable != lastState
        let due = Date().timeIntervalSince(lastPush) >= (inForeground ? 60 : 0)
        guard changed || due, due || !inForeground else { return }
        lastState = state
        lastPush = Date()
        let content = ActivityContent(state: state, staleDate: state.updated.addingTimeInterval(staleAfter))
        let id = activity.id
        // `Activity` isn't Sendable, so look it up by id inside the task rather than passing it in.
        Task.detached {
            for activity in Activity<FlightActivityAttributes>.activities where activity.id == id {
                await activity.update(content)
            }
        }
    }

    func end() {
        activity = nil
        lastState = nil
        Self.end(ids: Activity<FlightActivityAttributes>.activities.map(\.id))
    }

    /// Ends all activities and waits (briefly) for it to happen, because the process is about
    /// to exit and an asynchronous end would never run.
    func endBeforeExit(timeout: TimeInterval = 2) {
        activity = nil
        lastState = nil
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            for activity in Activity<FlightActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            done.signal()
        }
        _ = done.wait(timeout: .now() + timeout)
    }

    private static func end(ids: [String]) {
        guard !ids.isEmpty else { return }
        Task.detached {
            for activity in Activity<FlightActivityAttributes>.activities where ids.contains(activity.id) {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}
