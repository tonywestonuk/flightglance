import SwiftUI

/// Before-flight screen: airport entry, location permission, start.
struct SetupView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AppModel.unitsKey) private var units: UnitSystem = .aviation
    @AppStorage(AppModel.mapStyleKey) private var mapStyle: MapStyle = .globe
    @State private var picking: AirportRole?
    @State private var showingAbout = false
    @State private var confirmingEnd = false

    enum AirportRole: String, Identifiable {
        case origin, destination
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if model.isEditingFlight {
                        inProgressCard
                    } else {
                        intro
                    }
                    routeCard
                    LocationStatusCard()
                    offlineCard
                    #if DEBUG
                    developerCard
                    #endif
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.background.ignoresSafeArea())
            .safeAreaInset(edge: .bottom, spacing: 0) { startBar }
            .navigationTitle(model.isEditingFlight ? "Edit Flight" : "FlightGlance")
            .toolbar {
                if model.isEditingFlight {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            model.returnToFlight()
                        } label: {
                            Label("Back to Flight", systemImage: "chevron.left")
                        }
                        .accessibilityLabel("Back to flight")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingAbout = true } label: {
                        Image(systemName: "info.circle")
                    }
                    .accessibilityLabel("About FlightGlance")
                }
            }
            .sheet(item: $picking) { role in
                picker(for: role)
            }
            .sheet(isPresented: $showingAbout) { AboutView() }
            .confirmationDialog("End this flight?", isPresented: $confirmingEnd, titleVisibility: .visible) {
                Button("End Flight", role: .destructive) { model.endFlight() }
            } message: {
                Text("Your recorded track will be cleared from this iPhone.")
            }
            .onAppear { model.warmUpLocationIfAuthorized() }
            .onChange(of: model.location.authorization) { model.warmUpLocationIfAuthorized() }
        }
    }

    // MARK: Sections

    private var intro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Follow your flight, even in Airplane Mode.")
                .font(.title3.weight(.semibold))
            Text("FlightGlance uses your iPhone's GPS and a built-in world map, so it works without Wi-Fi or a cell signal once you're in the air.")
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }

    /// Shown when editing a flight that is still being tracked.
    private var inProgressCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow("Flight in progress")
            Text("GPS is still recording. Correcting the airports or flight number keeps your recorded track.")
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
            endButton
        }
        .card()
    }

    private var endButton: some View {
        Button(role: .destructive) {
            confirmingEnd = true
        } label: {
            Label("End Flight", systemImage: "xmark.circle")
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .tint(Theme.problem)
    }

    private var routeCard: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 10) {
            Eyebrow("Route")
            ZStack(alignment: .trailing) {
                VStack(spacing: 8) {
                    AirportField(label: "From", airport: model.draft.origin) { picking = .origin }
                    AirportField(label: "To", airport: model.draft.destination) { picking = .destination }
                }
                Button {
                    withAnimation(.smooth) {
                        swap(&model.draft.origin, &model.draft.destination)
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.body.weight(.semibold))
                        .frame(width: 40, height: 40)
                        .background(Theme.card, in: Circle())
                        .overlay(Circle().strokeBorder(Theme.cardBorder))
                }
                .padding(.trailing, 44)
                .accessibilityLabel("Swap departure and arrival")
                .disabled(model.draft.origin == nil && model.draft.destination == nil)
            }

            if let plan = model.draft.plan {
                routeSummary(plan)
            } else if let origin = model.draft.origin, origin == model.draft.destination {
                Label("Departure and arrival are the same airport.", systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(Theme.caution)
            }
        }
        .card()
    }

    private func routeSummary(_ plan: FlightPlan) -> some View {
        let distance = ReadingFormatter.distance(plan.greatCircleDistance, units: units)
        return VStack(alignment: .leading, spacing: 8) {
            if let atlas = model.atlas {
                StaticAtlasMap(atlas: atlas, overlay: previewOverlay(plan), style: mapStyle)
                    .frame(height: mapStyle == .globe ? 230 : 170)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityElement()
                    .accessibilityLabel("Route preview map from \(plan.origin.city) to \(plan.destination.city)")
            }
            Text("Distance: \(distance.joined)")
                .font(.footnote.weight(.medium))
            Text("The dashed line is the shortest path between the airports, shown for reference. During the flight it runs from your position to the destination, and your actual track is drawn from GPS.")
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
        }
    }

    private func previewOverlay(_ plan: FlightPlan) -> MapOverlay {
        let route = GeoMath.greatCirclePath(from: plan.origin.coordinate, to: plan.destination.coordinate)
        var overlay = MapOverlay()
        overlay.route = route
        if let first = route.first, let last = route.last {
            overlay.markers = [.init(code: plan.origin.iata, coordinate: first, role: .origin),
                               .init(code: plan.destination.iata, coordinate: last, role: .destination)]
        }
        return overlay
    }

    private var offlineCard: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 12) {
            Eyebrow("Ready for Airplane Mode")
            TipRow(symbol: "map", text: "The world map is built in. Nothing to download, no signal needed.")
            TipRow(symbol: "airplane", text: "Turn on Airplane Mode as usual. GPS keeps working.")
            TipRow(symbol: "location.fill", text: "For the best signal, keep your iPhone near a window.")
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Position updates")
                Picker("Position updates", selection: $model.gpsInterval) {
                    ForEach(AppModel.gpsIntervalChoices, id: \.self) { Text("\($0) s").tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text("The GPS switches on briefly for each position, then off to save battery.")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
            }
            Toggle(isOn: $model.lockScreenUpdates) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show on Lock Screen")
                    Text(model.lockScreenUpdates
                         ? "While locked, the GPS wakes every 5 minutes in a low-power mode, and your country, nearest town and distance to go are estimated from your speed every 30 seconds in between. iOS shows a location indicator."
                         : "Tracking pauses while your iPhone is locked and catches up when you unlock it.")
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                }
            }
        }
        .card()
    }

    #if DEBUG
    private var developerCard: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 10) {
            Eyebrow("Developer")
            Toggle(isOn: $model.simulateGPS) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Simulate GPS along route")
                    Text("Debug builds only. Every reading is clearly marked as simulated.")
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                }
            }
        }
        .card()
    }
    #endif

    private var startBar: some View {
        VStack(spacing: 6) {
            Button {
                model.startFlight()
            } label: {
                Label(startTitle, systemImage: model.isEditingFlight ? "checkmark" : "location.north.line.fill")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(model.draft.plan == nil)
            if model.draft.plan == nil {
                Text("Choose departure and arrival airports to start.")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private var startTitle: String {
        if model.isEditingFlight {
            return model.draft.plan == model.session?.plan ? "Back to Flight" : "Update Flight"
        }
        return model.simulateGPS ? "Start Simulated Flight" : "Start Tracking"
    }

    // MARK: Actions

    private func picker(for role: AirportRole) -> some View {
        AirportPickerView(
            title: role == .origin ? "Departure Airport" : "Arrival Airport",
            database: model.airports,
            nearby: role == .origin ? nearbyAirports : [],
            onSelect: { airport in
                if role == .origin { model.draft.origin = airport } else { model.draft.destination = airport }
            })
    }

    private var nearbyAirports: [Airport] {
        guard let fix = model.location.latestFix, let airports = model.airports else { return [] }
        return airports.nearest(to: fix.coordinate)
    }
}

/// A tappable field showing a chosen airport (or a prompt to choose one).
struct AirportField: View {
    let label: String
    let airport: Airport?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.secondaryText)
                    if let airport {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(airport.iata)
                                .font(.title3.weight(.bold).monospaced())
                            Text(airport.city.isEmpty ? airport.name : airport.city)
                                .font(.body)
                                .lineLimit(1)
                        }
                        Text(airport.name)
                            .font(.footnote)
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(2)
                    } else {
                        Text("Choose airport")
                            .font(.body)
                            .foregroundStyle(Theme.accent)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .background(Theme.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(airport.map { "\(label): \($0.name), \($0.iata)" } ?? "\(label): not chosen")
        .accessibilityHint("Choose an airport")
    }
}

private struct TipRow: View {
    let symbol: String
    let text: String

    var body: some View {
        Label {
            Text(text).font(.subheadline)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(Theme.accent)
                .frame(width: 24)
        }
    }
}
