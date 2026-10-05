import SwiftUI

/// What each reading means, how arrival is estimated, privacy, and data credits.
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("About these readings") {
                    Explainer(title: "Ground speed (GPS)", symbol: "speedometer",
                              text: "Your speed over the ground, measured by your iPhone's GPS. It differs from the airspeed pilots fly by, because of wind: a tailwind makes it higher, a headwind lower.")
                    Explainer(title: "Altitude (GPS)", symbol: "arrow.up.to.line",
                              text: "Height above mean sea level calculated by GPS. Aircraft altimeters use air pressure, so the altitude the crew announces can differ by several hundred feet. GPS altitude is also less precise than GPS position.")
                    Explainer(title: "Course (GPS)", symbol: "safari",
                              text: "The direction you are moving over the ground. Wind means the aircraft's nose can point a few degrees away from this.")
                    Explainer(title: "Time to arrival (estimate)", symbol: "clock",
                              text: "Remaining distance from your GPS position to the destination airport, divided by your average GPS ground speed over the last 5 minutes. It ignores the approach, holding, wind changes and taxiing, so treat it as a guide, not the airline's arrival time. It isn't shown while you're slower than about 50 knots.")
                    Explainer(title: "Route line", symbol: "point.topleft.down.to.point.bottomright.curvepath",
                              text: "The dashed line is the shortest path from your position to the destination airport, drawn for reference. It is not the airline's filed route. The solid line is the track your GPS actually recorded; dotted stretches mark signal gaps.")
                    Explainer(title: "Distance flown", symbol: "ruler",
                              text: "The sum of distances between recorded GPS points since you started tracking.")
                }

                Section("Airplane Mode & privacy") {
                    Explainer(title: "Works offline", symbol: "airplane",
                              text: "GPS is a receiver, so it keeps working in Airplane Mode. The map is built into the app; no tiles or network are used in flight.")
                    Explainer(title: "Stays on your iPhone", symbol: "lock.fill",
                              text: "Your location and track are stored only on this device, and are deleted when you end the flight.")
                    Link("Privacy Policy", destination: URL(string: "https://github.com/tonywestonuk/flightglance/blob/main/PRIVACY.md")!)
                        .font(.subheadline)
                }

                Section("Map & data credits") {
                    Credit(title: "Natural Earth",
                           detail: "Made with Natural Earth. Free vector and raster map data @ naturalearthdata.com. Coastlines, lakes, borders and cities (public domain).")
                    Credit(title: "OurAirports",
                           detail: "Airport names, codes and positions from ourairports.com (public domain).")
                    Credit(title: "mwgg/Airports", detail: "Airport time zones.\n\n" + Self.mitLicense)
                }

                Section {
                    LabeledContent("Version", value: Bundle.main.appVersion)
                }
            }
            .navigationTitle("FlightGlance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

extension AboutView {
    static let mitLicense = """
    The MIT License (MIT)

    Copyright (c) 2014 mwgg

    Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
    """
}

private struct Explainer: View {
    let title: String
    let symbol: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Text(text)
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

private struct Credit: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(detail).font(.footnote).foregroundStyle(Theme.secondaryText)
        }
        .accessibilityElement(children: .combine)
    }
}

extension Bundle {
    var appVersion: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}
