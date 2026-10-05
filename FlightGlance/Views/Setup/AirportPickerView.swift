import SwiftUI

/// Offline airport search sheet (code, city or name).
struct AirportPickerView: View {
    let title: String
    let database: AirportDatabase?
    var nearby: [Airport] = []
    let onSelect: (Airport) -> Void

    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var results: [Airport] { database?.search(trimmedQuery) ?? [] }

    var body: some View {
        NavigationStack {
            List {
                if trimmedQuery.isEmpty {
                    if !nearby.isEmpty {
                        Section("Near you") {
                            ForEach(nearby) { row($0) }
                        }
                    }
                    Section {
                        Label("Search by airport code (LHR or EGLL), city, or airport name. \((database?.airports.count ?? 0).formatted()) airports are stored on your iPhone, so search works offline.",
                              systemImage: "magnifyingglass")
                            .font(.footnote)
                            .foregroundStyle(Theme.secondaryText)
                    }
                } else {
                    ForEach(results) { row($0) }
                }
            }
            .overlay {
                if !trimmedQuery.isEmpty && results.isEmpty {
                    ContentUnavailableView.search(text: trimmedQuery)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Code, city or airport")
            .autocorrectionDisabled()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func row(_ airport: Airport) -> some View {
        Button {
            onSelect(airport)
            dismiss()
        } label: {
            AirportRow(airport: airport)
        }
        .buttonStyle(.plain)
    }
}

struct AirportRow: View {
    let airport: Airport
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
        layout {
            Text(airport.iata)
                .font(.headline.monospaced())
                .foregroundStyle(Theme.accent)
                .frame(minWidth: 44, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(airport.name)
                    .font(.body)
                Text([airport.locationDescription, airport.icao].compactMap { $0 }.joined(separator: " · "))
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
