import SwiftUI

/// Compact GPS indicator for the top bar. Uses icon + text (never colour alone).
struct GPSStatusPill: View {
    let signal: GPSSignalState
    let now: Date

    var body: some View {
        let style = Self.style(for: signal, now: now)
        Label {
            Text(style.text)
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        } icon: {
            Image(systemName: style.symbol)
                .font(.footnote.weight(.bold))
        }
        .foregroundStyle(style.tint)
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .floatingChrome(in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("GPS status")
        .accessibilityValue(style.spoken)
    }

    struct Style {
        var symbol: String
        var text: String
        var tint: Color
        var spoken: String
    }

    static func style(for signal: GPSSignalState, now: Date) -> Style {
        switch signal {
        case .simulated:
            Style(symbol: "testtube.2", text: "Simulated", tint: Theme.simulated, spoken: "Simulated GPS, not real")
        case .permissionNeeded:
            Style(symbol: "location", text: "Location off", tint: Theme.caution, spoken: "Location permission needed")
        case .denied, .restricted:
            Style(symbol: "location.slash.fill", text: "No access", tint: Theme.problem, spoken: "Location access denied")
        case .servicesOff:
            Style(symbol: "location.slash.fill", text: "Location off", tint: Theme.problem, spoken: "Location Services are off")
        case .acquiring:
            Style(symbol: "location.magnifyingglass", text: "Finding GPS", tint: Theme.secondaryText,
                  spoken: "Searching for GPS signal")
        case .good(let accuracy):
            Style(symbol: "location.fill", text: "GPS ±\(Int(accuracy.rounded())) m", tint: Theme.good,
                  spoken: "Good GPS signal, accurate to \(Int(accuracy.rounded())) meters")
        case .weak(let accuracy):
            Style(symbol: "exclamationmark.triangle.fill", text: "Weak GPS", tint: Theme.caution,
                  spoken: "Weak GPS signal, accurate to about \(Int(accuracy.rounded())) meters")
        case .lost:
            Style(symbol: "location.slash.fill", text: "No GPS", tint: Theme.problem, spoken: "GPS signal lost")
        }
    }
}

/// Explanatory banner shown over the map when something needs the user's attention.
struct SignalBanner: View {
    let signal: GPSSignalState
    let isPrecise: Bool
    let requestPermission: () -> Void
    let requestPrecise: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let content, content.isCompact {
            Label {
                Text("\(content.title) · ").font(.caption.weight(.semibold))
                    + Text(content.detail).font(.caption)
            } icon: {
                Image(systemName: content.symbol).foregroundStyle(content.tint)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .floatingChrome(in: Capsule())
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        } else if let content {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: content.symbol)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(content.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(content.title).font(.subheadline.weight(.semibold))
                    Text(content.detail)
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if let action = content.action {
                    Button(action.title, action: action.perform)
                        .font(.subheadline.weight(.semibold))
                        .buttonStyle(.bordered)
                }
            }
            .padding(12)
            .frame(maxWidth: 520)
            .floatingChrome(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityElement(children: .combine)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private struct Content {
        var symbol: String
        var tint: Color
        var title: String
        var detail: String
        var action: (title: String, perform: () -> Void)?
        var isCompact = false
    }

    private var content: Content? {
        switch signal {
        case .simulated:
            return Content(symbol: "testtube.2", tint: Theme.simulated, title: "Simulated flight",
                           detail: "Demo data, not real GPS.", isCompact: true)
        case .permissionNeeded:
            return Content(symbol: "location", tint: Theme.caution, title: "Location needed",
                           detail: "Allow location to see your position and readings.",
                           action: ("Allow", requestPermission))
        case .denied, .restricted, .servicesOff:
            return Content(symbol: "location.slash.fill", tint: Theme.problem, title: "Location is off",
                           detail: "The map and route still work. Turn on location in Settings to track the flight.",
                           action: ("Settings", openSettings))
        case .lost(let last):
            let detail = last.map { "Last fix \($0.formatted(.relative(presentation: .named))). " } ?? ""
            return Content(symbol: "location.slash.fill", tint: Theme.problem, title: "GPS signal lost",
                           detail: detail + "Try holding your iPhone near a window. Readings resume automatically.")
        case .acquiring:
            return Content(symbol: "location.magnifyingglass", tint: Theme.secondaryText, title: "Finding GPS…",
                           detail: "This can take a minute or two in a cabin. A window seat helps.")
        case .weak, .good:
            guard !isPrecise else { return nil }
            return Content(symbol: "scope", tint: Theme.caution, title: "Precise Location is off",
                           detail: "Your position may be off by several kilometres.",
                           action: ("Turn On", requestPrecise))
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
    }
}

/// Origin → destination bar showing progress along the reference great circle.
struct RouteProgressView: View {
    let plan: FlightPlan
    let progress: Double?
    let remaining: Double?
    let units: UnitSystem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(plan.origin.iata).font(.subheadline.weight(.bold).monospaced())
                GeometryReader { geometry in
                    let width = geometry.size.width
                    let fraction = CGFloat(progress ?? 0)
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.secondaryText.opacity(0.25)).frame(height: 4)
                        Capsule().fill(Theme.accent).frame(width: max(4, width * fraction), height: 4)
                        if progress != nil {
                            Image(systemName: "airplane")
                                .font(.footnote.weight(.bold))
                                .foregroundStyle(Theme.accent)
                                .padding(3)
                                .background(Theme.panel, in: Circle())
                                .position(x: min(max(10, width * fraction), width - 10), y: geometry.size.height / 2)
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
                .frame(height: 24)
                Text(plan.destination.iata).font(.subheadline.weight(.bold).monospaced())
            }
            Text(summary)
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Route progress, \(plan.origin.iata) to \(plan.destination.iata)")
        .accessibilityValue(summary)
    }

    private var summary: String {
        guard let progress else { return "Waiting for a GPS position to show progress" }
        let percent = (progress).formatted(.percent.precision(.fractionLength(0)))
        if let remaining {
            return "\(percent) of the route · \(ReadingFormatter.distance(remaining, units: units).joined) to go"
        }
        return "\(percent) of the route"
    }
}

/// Floating map buttons. Zoom buttons are dropped when the map is too short for them.
struct MapControls: View {
    let isFollowing: Bool
    let canFollow: Bool
    let follow: () -> Void
    let fitRoute: () -> Void
    let zoomIn: () -> Void
    let zoomOut: () -> Void

    var body: some View {
        ViewThatFits(in: .vertical) {
            VStack(spacing: 10) {
                zoomButtons
                navigationButtons
            }
            navigationButtons
        }
    }

    private var navigationButtons: some View {
        VStack(spacing: 10) {
            MapButton(symbol: isFollowing ? "location.fill" : "location", label: "Center on aircraft",
                      isActive: isFollowing, action: follow)
                .disabled(!canFollow)
            MapButton(symbol: "arrow.up.left.and.arrow.down.right", label: "Show whole route", action: fitRoute)
        }
    }

    private var zoomButtons: some View {
        VStack(spacing: 0) {
            MapButton(symbol: "plus", label: "Zoom in", plain: true, action: zoomIn)
            Divider().frame(width: 28)
            MapButton(symbol: "minus", label: "Zoom out", plain: true, action: zoomOut)
        }
        .floatingChrome(in: Capsule())
    }
}

private struct MapButton: View {
    let symbol: String
    let label: String
    var isActive = false
    var plain = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(isActive ? Theme.accent : Color.primary)
                .frame(width: 44, height: 44)
                .modifier(ChromeIfNeeded(plain: plain))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

private struct ChromeIfNeeded: ViewModifier {
    let plain: Bool

    func body(content: Content) -> some View {
        if plain {
            content
        } else {
            content.floatingChrome(in: Circle())
        }
    }
}
