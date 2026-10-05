import ActivityKit
import SwiftUI
import WidgetKit

@main
struct FlightGlanceWidgets: WidgetBundle {
    var body: some Widget {
        FlightLiveActivity()
    }
}

/// Lock Screen and Dynamic Island presentation of a flight in progress.
///
/// Everything shown comes from the app's last GPS fix (taken every 5 minutes while the phone is
/// locked), carried forward every 30 seconds in between using its speed and course. The
/// arrival countdown is drawn by the system with a relative date, so it keeps counting between
/// updates without waking the app.
struct FlightLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FlightActivityAttributes.self) { context in
            LockScreenView(attributes: context.attributes, state: context.state, isStale: context.isStale)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.route, systemImage: "airplane")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let arrival = context.state.arrival {
                        Text(arrival, style: .relative)
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                            .multilineTextAlignment(.trailing)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(context.state.region)
                            .font(.headline)
                            .lineLimit(1)
                        if let town = context.state.nearestTown {
                            Text(town)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        RouteBar(attributes: context.attributes, state: context.state)
                    }
                }
            } compactLeading: {
                HStack(spacing: 4) {
                    Image(systemName: "airplane")
                    if let progress = context.state.progress {
                        Text(progress, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit()
                    }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.flightAccent)
            } compactTrailing: {
                // How much longer, counting down without waking the app.
                if let arrival = context.state.arrival, arrival > .now {
                    Text(timerInterval: Date.now...arrival, countsDown: true, showsHours: true)
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .frame(maxWidth: 64)
                } else {
                    Text(context.state.distanceToGo ?? "—")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                }
            } minimal: {
                Image(systemName: "airplane")
                    .foregroundStyle(Color.flightAccent)
            }
            .keylineTint(Color.flightAccent)
        }
    }
}

/// Built to be read at a glance without unlocking: how far along, where you are, and how
/// much longer.
private struct LockScreenView: View {
    let attributes: FlightActivityAttributes
    let state: FlightActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RouteLine(attributes: attributes, progress: state.progress)
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                // Where
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.region)
                        .font(.title3.weight(.bold))
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                    if let town = state.nearestTown, !state.isSearching {
                        Text(town)
                            .font(.subheadline)
                            .foregroundStyle(Color.white.opacity(0.8))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                // How much longer
                VStack(alignment: .trailing, spacing: 2) {
                    if let arrival = state.arrival {
                        Text(arrival, style: .relative)
                            .font(.title3.weight(.bold))
                            .monospacedDigit()
                            .multilineTextAlignment(.trailing)
                            .lineLimit(2)
                            .minimumScaleFactor(0.7)
                        Text("Lands ≈ \(attributes.landingTime(arrival))")
                            .font(.footnote)
                            .foregroundStyle(Color.white.opacity(0.8))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    } else {
                        Text("—").font(.title3.weight(.bold))
                        Text("estimating")
                            .font(.subheadline)
                            .foregroundStyle(Color.white.opacity(0.8))
                    }
                }
                // A self-updating relative date reserves room for its longest possible text,
                // so give the column a fixed width or it pushes everything else off the card.
                .frame(width: 118, alignment: .trailing)
            }
            HStack {
                if let distance = state.distanceToGo, !state.isSearching {
                    Text("\(distance) to go")
                        .foregroundStyle(Color.white.opacity(0.8))
                }
                Spacer()
                // Stale means no update for 12+ minutes: the app isn't running (or has no GPS),
                // so say so rather than look live.
                Text(isStale ? "Not updating — open FlightGlance" : updatedText)
                    .foregroundStyle(isStale ? Color.orange : Color.white.opacity(0.7))
            }
            .font(.caption)
        }
        .foregroundStyle(.white)
        .padding(16)
    }

    private var updatedText: String {
        let fixTime = "GPS \(state.updated.formatted(date: .omitted, time: .shortened))"
        return state.estimatedAt == nil ? fixTime : "Estimated from \(fixTime)"
    }
}

/// Origin code on the left, destination on the right, joined by a line with the aircraft at
/// the fraction of the journey completed (0 % at the origin, 100 % at the destination).
private struct RouteLine: View {
    let attributes: FlightActivityAttributes
    let progress: Double?

    var body: some View {
        HStack(spacing: 8) {
            Text(attributes.origin)
            GeometryReader { geometry in
                let width = geometry.size.width
                let fraction = min(1, max(0, progress ?? 0))
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.3)).frame(height: 2)
                    Capsule().fill(Color.flightAccent).frame(width: width * fraction, height: 2)
                }
                .frame(width: width, height: geometry.size.height)
                if progress != nil {
                    // Kept inside the line's ends so it never overlaps the airport codes.
                    Image(systemName: "airplane")
                        .font(.system(size: 15, weight: .semibold))
                        .position(x: min(max(width * fraction, 9), width - 9), y: geometry.size.height / 2)
                }
            }
            .frame(height: 18)
            Text(attributes.destination)
        }
        .font(.subheadline.weight(.bold).monospaced())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(attributes.origin) to \(attributes.destination)")
        .accessibilityValue(progress.map { "\($0.formatted(.percent.precision(.fractionLength(0)))) of the way" } ?? "")
    }
}

/// Route line, distance to go and the local landing time (Dynamic Island).
private struct RouteBar: View {
    let attributes: FlightActivityAttributes
    let state: FlightActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            RouteLine(attributes: attributes, progress: state.progress)
            HStack {
                if let distance = state.distanceToGo {
                    Text("\(distance) to go")
                }
                Spacer()
                if let arrival = state.arrival {
                    Text("Lands ≈ \(attributes.landingTime(arrival))")
                }
            }
            .font(.caption)
            .foregroundStyle(Color.white.opacity(0.8))
        }
    }
}

private extension FlightActivityAttributes {
    var route: String { "\(origin) → \(destination)" }

    /// "07:41 local" in the destination's time zone, or the phone's time if unknown.
    func landingTime(_ date: Date) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        if let id = destinationTimeZone, let zone = TimeZone(identifier: id) {
            style.timeZone = zone
            return date.formatted(style) + " local"
        }
        return date.formatted(style)
    }
}

private extension Color {
    static let flightAccent = Color(red: 0.36, green: 0.81, blue: 0.77)
}
