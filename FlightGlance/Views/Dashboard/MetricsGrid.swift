import SwiftUI

/// The six key readings. Every tile says where its number comes from, and shows a dash with
/// a reason instead of a value whenever there is no trustworthy current reading.
struct MetricsGrid: View {
    let readings: FlightReadings
    let plan: FlightPlan
    let units: UnitSystem
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top),
                            count: dynamicTypeSize.isAccessibilitySize ? 1 : 2)
        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
            etaTile
            speedTile
            altitudeTile
            courseTile
            MetricTile(title: "Flown", source: "GPS",
                       value: ReadingFormatter.distance(readings.distanceTraveled, units: units),
                       caption: "Along your recorded track")
            remainingTile
        }
    }

    private var noLiveCaption: String {
        switch readings.signal {
        case .acquiring: "Waiting for GPS"
        case .lost: "No current GPS fix"
        case .denied, .restricted, .servicesOff, .permissionNeeded: "Location is off"
        default: "Unavailable"
        }
    }

    private var etaTile: some View {
        let value: FormattedValue?
        let caption: String
        var tone = MetricTile.Tone.secondary
        switch readings.eta {
        case .estimate(let estimate):
            value = ReadingFormatter.duration(estimate.timeRemaining)
            let clock = ReadingFormatter.clockTime(estimate.arrival, in: plan.destination.timeZone)
            caption = plan.destination.timeZone == nil
                ? "Arrive ≈ \(clock) (this iPhone's time)"
                : "Arrive ≈ \(clock) \(plan.destination.iata) time"
        case .arriving:
            value = FormattedValue(value: "Arriving", unit: "", spoken: "Arriving")
            caption = "Within 5 km of \(plan.destination.iata)"
        case .unavailable(let reason):
            value = nil
            tone = .caution
            caption = switch reason {
            case .noPosition: "Needs a GPS position"
            case .noSpeed: "Waiting for GPS ground speed"
            case .speedTooLow: "Not moving fast enough to estimate"
            case .fixTooOld: "GPS signal lost for too long"
            case .notCredible: "Can't estimate at current speed"
            }
        }
        return MetricTile(title: "Arrival in", source: "Estimate", value: value, caption: caption,
                          captionTone: tone, isProminent: true)
    }

    private var speedTile: some View {
        guard let fix = readings.liveFix, let speed = fix.speed else {
            return MetricTile(title: "Ground speed", source: "GPS", value: nil,
                              caption: readings.liveFix == nil ? noLiveCaption : "No GPS speed in this fix",
                              captionTone: .caution)
        }
        let accuracy = fix.speedAccuracy.map { ReadingFormatter.speedAccuracy($0, units: units) }
        return MetricTile(title: "Ground speed", source: "GPS",
                          value: ReadingFormatter.speed(speed, units: units),
                          caption: ["Over the ground", accuracy].compactMap { $0 }.joined(separator: " · "))
    }

    private var altitudeTile: some View {
        guard let fix = readings.liveFix, let altitude = fix.altitude else {
            return MetricTile(title: "Altitude", source: "GPS", value: nil,
                              caption: readings.liveFix == nil ? noLiveCaption : "No GPS altitude in this fix",
                              captionTone: .caution)
        }
        let accuracy = fix.verticalAccuracy.map { ReadingFormatter.accuracy($0, units: units) }
        return MetricTile(title: "Altitude", source: "GPS",
                          value: ReadingFormatter.altitude(altitude, units: units),
                          caption: ["Above sea level", accuracy].compactMap { $0 }.joined(separator: " · "))
    }

    private var courseTile: some View {
        guard let fix = readings.liveFix, let course = fix.usableCourse else {
            return MetricTile(title: "Course", source: "GPS", value: nil,
                              caption: readings.liveFix == nil ? noLiveCaption : "Needs steady movement",
                              captionTone: .caution)
        }
        return MetricTile(title: "Course", source: "GPS", value: ReadingFormatter.course(course),
                          caption: "Track over the ground")
    }

    private var remainingTile: some View {
        guard let remaining = readings.remainingDistance else {
            return MetricTile(title: "To go", source: "Direct", value: nil,
                              caption: "Needs a GPS position", captionTone: .caution)
        }
        var caption = "Distance to \(plan.destination.iata)"
        if !readings.signal.isLive, let time = readings.lastFixTime {
            caption = "From last fix, \(time.formatted(.relative(presentation: .named)))"
        }
        return MetricTile(title: "To go", source: "Direct",
                          value: ReadingFormatter.distance(remaining, units: units), caption: caption)
    }
}

struct MetricTile: View {
    enum Tone { case secondary, caution }

    let title: String
    let source: String
    let value: FormattedValue?
    let caption: String
    var captionTone: Tone = .secondary
    var isProminent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // Title and source badge sit side by side, or stack when space is tight
            // (narrow tiles, large Dynamic Type) rather than truncating either.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { titleText; badge }
                VStack(alignment: .leading, spacing: 3) { titleText; badge }
            }
            Group {
                if let value {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(value.value)
                            .font(.title2.weight(.semibold))
                            .monospacedDigit()
                        if !value.unit.isEmpty {
                            Text(value.unit)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Theme.secondaryText)
                        }
                    }
                } else {
                    Text("—")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            Text(caption)
                .font(.caption)
                .foregroundStyle(captionTone == .caution ? Theme.caution : Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(isProminent ? Theme.accent.opacity(0.45) : Theme.cardBorder))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(source)")
        .accessibilityValue(value.map { "\($0.spoken). \(caption)" } ?? "Unavailable. \(caption)")
    }

    private var titleText: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .textCase(.uppercase)
            .foregroundStyle(Theme.secondaryText)
            .fixedSize()
    }

    private var badge: some View {
        Text(source)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(isProminent ? Theme.accent : Theme.secondaryText)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(Capsule().strokeBorder(isProminent ? Theme.accent : Theme.secondaryText.opacity(0.5), lineWidth: 1))
            .fixedSize()
    }
}
