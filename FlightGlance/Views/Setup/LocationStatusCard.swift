import SwiftUI

/// Explains why location is needed and shows the current permission / GPS state with the
/// right next step (allow, open Settings, enable precise location).
struct LocationStatusCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow("Location")
            content
        }
        .card()
    }

    @ViewBuilder
    private var content: some View {
        let location = model.location
        switch location.authorization {
        case .notDetermined:
            Text("FlightGlance needs your location to show where you are, your ground speed, altitude and progress. It stays on your iPhone and is never uploaded.")
                .font(.subheadline)
            Button {
                location.requestPermission()
            } label: {
                Label("Allow Location Access", systemImage: "location.fill")
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        case .denied, .restricted:
            status(symbol: "location.slash.fill", tint: Theme.problem,
                   title: location.authorization == .restricted ? "Location access is restricted" : "Location access is off",
                   detail: "Without it you'll still see the map and route, but not your position or readings. Turn on location for FlightGlance in Settings.")
            settingsButton
        case .servicesOff:
            status(symbol: "location.slash.fill", tint: Theme.problem,
                   title: "Location Services are off",
                   detail: "Turn them on in Settings › Privacy & Security › Location Services.")
            settingsButton
        case .authorized:
            if !location.isPrecise {
                status(symbol: "scope", tint: Theme.caution, title: "Precise Location is off",
                       detail: "Positions may be off by several kilometres. Turn on Precise Location for an accurate track.")
                Button("Turn On Precise Location") { location.requestTemporaryPreciseLocation() }
                    .buttonStyle(.bordered)
            } else if let fix = location.latestFix {
                status(symbol: "checkmark.circle.fill", tint: Theme.good, title: "Location ready",
                       detail: "GPS fix within ±\(Int(fix.horizontalAccuracy.rounded())) m.")
            } else {
                status(symbol: "location.fill", tint: Theme.good, title: "Location allowed",
                       detail: "Looking for GPS. A first fix can take a minute or two indoors or in a cabin.")
            }
        }
    }

    private func status(symbol: String, tint: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .font(.body.weight(.semibold))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.footnote).foregroundStyle(Theme.secondaryText)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var settingsButton: some View {
        Button("Open Settings") {
            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
        }
        .buttonStyle(.bordered)
    }
}
