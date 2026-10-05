import Foundation

/// Display units. All values are stored in SI (metres, m/s) and converted only for display.
enum UnitSystem: String, CaseIterable, Identifiable, Sendable {
    case aviation, metric, imperial

    var id: String { rawValue }

    var title: String {
        switch self {
        case .aviation: "Aviation (kt, ft, nm)"
        case .metric: "Metric (km/h, m, km)"
        case .imperial: "Imperial (mph, ft, mi)"
        }
    }

    var speedUnit: UnitSpeed {
        switch self {
        case .aviation: .knots
        case .metric: .kilometersPerHour
        case .imperial: .milesPerHour
        }
    }

    var altitudeUnit: UnitLength {
        self == .metric ? .meters : .feet
    }

    var distanceUnit: UnitLength {
        switch self {
        case .aviation: .nauticalMiles
        case .metric: .kilometers
        case .imperial: .miles
        }
    }
}

/// A formatted reading split into number and unit so the number can be styled larger.
struct FormattedValue: Equatable {
    var value: String
    var unit: String
    /// Full spoken form for VoiceOver, e.g. "472 knots".
    var spoken: String
}

/// Formatting for readings. Uses Foundation's locale-aware number and measurement formatting.
enum ReadingFormatter {
    static func speed(_ metersPerSecond: Double, units: UnitSystem) -> FormattedValue {
        let value = Measurement(value: metersPerSecond, unit: UnitSpeed.metersPerSecond).converted(to: units.speedUnit).value
        return format(value, fractionDigits: 0, unit: units.speedUnit)
    }

    static func altitude(_ meters: Double, units: UnitSystem) -> FormattedValue {
        let converted = Measurement(value: meters, unit: UnitLength.meters).converted(to: units.altitudeUnit).value
        // GPS altitude is only good to tens of metres; round so we don't imply more precision.
        let step: Double = units == .metric ? 10 : 50
        return format((converted / step).rounded() * step, fractionDigits: 0, unit: units.altitudeUnit)
    }

    static func distance(_ meters: Double, units: UnitSystem) -> FormattedValue {
        let converted = Measurement(value: meters, unit: UnitLength.meters).converted(to: units.distanceUnit).value
        return format(converted, fractionDigits: converted < 10 ? 1 : 0, unit: units.distanceUnit)
    }

    /// Short accuracy caption such as "±12 m" or "±40 ft".
    static func accuracy(_ meters: Double, units: UnitSystem) -> String {
        let unit = units.altitudeUnit
        let converted = Measurement(value: meters, unit: UnitLength.meters).converted(to: unit).value
        return "±" + format(converted, fractionDigits: 0, unit: unit).joined
    }

    static func speedAccuracy(_ metersPerSecond: Double, units: UnitSystem) -> String {
        "±" + speed(metersPerSecond, units: units).joined
    }

    /// "274°" plus a cardinal direction ("W") for the course over ground.
    static func course(_ degrees: Double) -> FormattedValue {
        let rounded = Int(degrees.rounded()) % 360
        let names = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let spokenNames = ["north", "northeast", "east", "southeast", "south", "southwest", "west", "northwest"]
        let index = Int((Double(rounded) / 45).rounded()) % 8
        return FormattedValue(value: String(format: "%03d°", rounded), unit: names[index],
                              spoken: "\(rounded) degrees, \(spokenNames[index])")
    }

    /// "2h 14m", "14 min", "< 1 min".
    static func duration(_ seconds: TimeInterval) -> FormattedValue {
        let totalMinutes = Int((max(0, seconds) / 60).rounded())
        if totalMinutes < 1 {
            return FormattedValue(value: "< 1", unit: "min", spoken: "less than a minute")
        }
        let hours = totalMinutes / 60, minutes = totalMinutes % 60
        let spoken = Duration.seconds(totalMinutes * 60)
            .formatted(.units(allowed: [.hours, .minutes], width: .wide))
        if hours == 0 {
            return FormattedValue(value: "\(minutes)", unit: "min", spoken: spoken)
        }
        return FormattedValue(value: "\(hours)h \(String(format: "%02d", minutes))m", unit: "", spoken: spoken)
    }

    /// Clock time in a given time zone, e.g. "16:42" / "4:42 PM".
    static func clockTime(_ date: Date, in timeZone: TimeZone?) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        if let timeZone { style.timeZone = timeZone }
        return date.formatted(style)
    }

    private static func format(_ value: Double, fractionDigits: Int, unit: Dimension) -> FormattedValue {
        let number = value.formatted(.number.precision(.fractionLength(fractionDigits)))
        let symbol = MeasurementFormatter.shortSymbol(for: unit)
        let spoken = Measurement(value: value, unit: unit)
            .formatted(.measurement(width: .wide, usage: .asProvided,
                                    numberFormatStyle: .number.precision(.fractionLength(fractionDigits))))
        return FormattedValue(value: number, unit: symbol, spoken: spoken)
    }
}

extension FormattedValue {
    var joined: String { unit.isEmpty ? value : "\(value) \(unit)" }
}

private extension MeasurementFormatter {
    static func shortSymbol(for unit: Dimension) -> String {
        switch unit {
        case UnitSpeed.knots: "kt"
        case UnitSpeed.kilometersPerHour: "km/h"
        case UnitSpeed.milesPerHour: "mph"
        case UnitLength.feet: "ft"
        case UnitLength.meters: "m"
        case UnitLength.nauticalMiles: "nm"
        case UnitLength.kilometers: "km"
        case UnitLength.miles: "mi"
        default: unit.symbol
        }
    }
}
