import SwiftUI

/// Compact table of the readings for the full-screen-map mode: 3 columns × 2 rows in
/// portrait, 6 × 1 in landscape.
///
///     ARRIVAL     SPEED       ALT
///     2h 30m      530 mph     38,000 ft
///     COURSE      FLOWN       TO GO
///     265° W      1,047 mi    1,944 mi
///
/// When there's no current GPS fix, the whole panel says so instead of showing stale numbers.
struct ReadingsSummary: View {
    let readings: FlightReadings
    let plan: FlightPlan
    let units: UnitSystem
    /// Columns in the table (3 in portrait, 6 in landscape).
    var columns = 3
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    struct Item {
        var label: String
        var value: String
        var spoken: String
    }

    var body: some View {
        let lines = rows
        ZStack {
            // The readings layout always reserves its height so the panel (and the map
            // buttons above it) don't jump when the signal comes and goes.
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                ForEach(lines.indices, id: \.self) { row in
                    GridRow {
                        ForEach(lines[row].indices, id: \.self) { column in
                            cell(lines[row][column])
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(statusMessage == nil ? 1 : 0)
            .accessibilityHidden(statusMessage != nil)

            if let statusMessage {
                Label(statusMessage.text, systemImage: statusMessage.symbol)
                    .font(.headline)
                    .foregroundStyle(statusMessage.tint)
                    .frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(statusMessage?.text ?? "Flight summary")
        .accessibilityValue(statusMessage == nil ? items.map { "\($0.label) \($0.spoken)" }.joined(separator: ", ") : "")
    }

    private func cell(_ item: Item) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(item.label)
                .font(.caption2.weight(.medium))
                .textCase(.uppercase)
                .foregroundStyle(Theme.secondaryText)
            Text(item.value)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Rows of the table. At accessibility text sizes, fewer columns so values aren't squeezed.
    private var rows: [[Item]] {
        let perRow = dynamicTypeSize.isAccessibilitySize ? max(2, columns / 2) : columns
        return stride(from: 0, to: items.count, by: perRow).map { Array(items[$0..<min($0 + perRow, items.count)]) }
    }

    private var statusMessage: (text: String, symbol: String, tint: Color)? {
        switch readings.signal {
        case .acquiring, .lost:
            ("Searching for GPS…", "location.magnifyingglass", Theme.secondaryText)
        case .permissionNeeded, .denied, .restricted, .servicesOff:
            ("Location is off", "location.slash.fill", Theme.problem)
        case .good, .weak, .simulated:
            nil
        }
    }

    private var items: [Item] {
        let fix = readings.liveFix
        let dash = Item(label: "", value: "—", spoken: "unavailable")
        func item(_ label: String, _ value: FormattedValue?) -> Item {
            guard let value else { return Item(label: label, value: dash.value, spoken: dash.spoken) }
            return Item(label: label, value: value.joined, spoken: value.spoken)
        }

        let arrival: FormattedValue? = switch readings.eta {
        case .estimate(let eta): ReadingFormatter.duration(eta.timeRemaining)
        case .arriving: FormattedValue(value: "Arriving", unit: "", spoken: "arriving")
        case .unavailable: nil
        }
        return [
            item("Arrival", arrival),
            item("Speed", fix?.speed.map { ReadingFormatter.speed($0, units: units) }),
            item("Alt", fix?.altitude.map { ReadingFormatter.altitude($0, units: units) }),
            item("Course", fix?.usableCourse.map(ReadingFormatter.course)),
            item("Flown", ReadingFormatter.distance(readings.distanceTraveled, units: units)),
            item("To go", readings.remainingDistance.map { ReadingFormatter.distance($0, units: units) }),
        ]
    }
}
