import SwiftUI

/// In-flight screen: the offline map with the route and GPS track, plus key readings.
///
/// Portrait stacks the map above a readings panel (the panel never takes more than about half
/// the height and scrolls if Dynamic Type makes it taller). Landscape puts the panel in a
/// sidebar. The panel can be hidden to give the map the whole screen. Layout is driven by the
/// available size, not by device model.
struct DashboardView: View {
    @Environment(AppModel.self) private var model
    let session: FlightSession
    let atlas: WorldAtlas

    @State private var map = MapController(style: MapStyle(rawValue: UserDefaults.standard.string(forKey: AppModel.mapStyleKey) ?? "") ?? .globe)
    @State private var confirmingEnd = false
    @State private var showingAbout = false
    @State private var airplaneReminderDismissed = false
    @AppStorage(AppModel.unitsKey) private var units: UnitSystem = .aviation
    @AppStorage(AppModel.mapStyleKey) private var mapStyle: MapStyle = .globe
    @AppStorage("readingsHidden") private var readingsHidden = false
    @State private var summaryHeight: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            let isWide = geometry.size.width > geometry.size.height * 1.1
            if isWide {
                HStack(spacing: 0) {
                    mapLayer(safeArea: geometry.safeAreaInsets,
                             edges: readingsHidden ? .all : [.top, .bottom, .leading])
                        .safeAreaInset(edge: .bottom, spacing: 0) { if readingsHidden { summaryPanel(columns: 6) } }
                    if !readingsHidden {
                        VStack(spacing: 0) {
                            hideButton(isWide: true)
                            ScrollView { livePanel }
                        }
                        .frame(width: min(440, max(300, geometry.size.width * 0.4)))
                        .background(Theme.panel.ignoresSafeArea())
                        .transition(.move(edge: .trailing))
                    }
                }
            } else {
                VStack(spacing: 0) {
                    mapLayer(safeArea: geometry.safeAreaInsets,
                             edges: readingsHidden ? .all : [.top, .horizontal])
                        .safeAreaInset(edge: .bottom, spacing: 0) { if readingsHidden { summaryPanel(columns: 3) } }
                        .layoutPriority(-1)
                    if !readingsHidden {
                        VStack(spacing: 0) {
                            hideButton(isWide: false)
                            ViewThatFits(in: .vertical) {
                                livePanel
                                ScrollView { livePanel }
                            }
                        }
                        .frame(maxHeight: geometry.size.height * 0.5)
                        .background(Theme.panel.ignoresSafeArea(edges: [.bottom, .horizontal]))
                        .transition(.move(edge: .bottom))
                    }
                }
            }
        }
        .onChange(of: session.latestFix?.timestamp) { _, _ in
            map.follow(session.aircraftPosition)
        }
        .onChange(of: mapStyle) { _, style in
            withAnimation(.smooth(duration: 0.4)) { map.style = style }
            if map.isFollowing, let position = session.aircraftPosition { map.center(on: position, animated: false) }
        }
        .confirmationDialog("End this flight?", isPresented: $confirmingEnd, titleVisibility: .visible) {
            Button("End Flight", role: .destructive) { model.endFlight() }
        } message: {
            Text("Your recorded track will be cleared from this iPhone.")
        }
        .sheet(isPresented: $showingAbout) { AboutView() }
    }

    private func readings(at date: Date) -> FlightReadings {
        let location = model.location
        let signal = GPSSignalState.evaluate(authorization: location.authorization,
                                             isSimulated: location.isSimulated,
                                             isUpdating: location.isUpdating,
                                             updatesStarted: location.updatesStarted,
                                             lastFix: session.latestFix,
                                             now: date,
                                             sampleInterval: location.sampleInterval)
        return FlightReadings.make(plan: session.plan, recorder: session.recorder,
                                   latestFix: session.latestFix, signal: signal, now: date,
                                   sampleInterval: location.effectiveInterval)
    }

    /// Readings refresh every few seconds (countdowns, "last fix 20 s ago", signal loss) and
    /// whenever a new fix arrives.
    private var livePanel: some View {
        TimelineView(.periodic(from: .now, by: 5)) { timeline in
            panel(readings(at: timeline.date), now: timeline.date)
        }
    }

    /// The map redraws when a fix arrives or the user moves it. Its clock only needs to be
    /// slow — to grey out the aircraft if fixes stop — because re-rendering the globe every
    /// second for no reason costs battery and heat.
    private func mapLayer(safeArea: EdgeInsets, edges: Edge.Set) -> some View {
        TimelineView(.periodic(from: .now, by: 15)) { timeline in
            mapArea(readings(at: timeline.date), safeArea: safeArea, edges: edges)
        }
    }

    // MARK: Map

    private func mapArea(_ readings: FlightReadings, safeArea: EdgeInsets, edges: Edge.Set) -> some View {
        AtlasMapView(atlas: atlas,
                     overlay: session.overlay(isLive: readings.signal.isLive),
                     controller: map,
                     initialFrame: initialCamera(for:),
                     accessibilitySummary: mapSummary(readings))
            .ignoresSafeArea(edges: edges)
            .overlay(alignment: .top) {
                VStack(spacing: 8) {
                    topBar(readings)
                    SignalBanner(signal: readings.signal, isPrecise: model.location.isPrecise,
                                 requestPermission: model.location.requestPermission,
                                 requestPrecise: model.location.requestTemporaryPreciseLocation)
                    if model.cellular.isConnected && !airplaneReminderDismissed {
                        AirplaneModeBanner { withAnimation { airplaneReminderDismissed = true } }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 6)
            }
            .overlay(alignment: .bottomTrailing) {
                MapControls(isFollowing: map.isFollowing, canFollow: session.latestFix != nil,
                            follow: followAircraft, fitRoute: { map.fit(session.framingPoints) },
                            zoomIn: { map.zoom(by: 2, anchor: nil, animated: true) },
                            zoomOut: { map.zoom(by: 0.5, anchor: nil, animated: true) })
                    .padding(12)
            }
            .onAppear { updateChromeInsets(safeArea: safeArea, edges: edges) }
            .onChange(of: safeArea) { _, insets in updateChromeInsets(safeArea: insets, edges: edges) }
            .onChange(of: readingsHidden) { _, _ in
                updateChromeInsets(safeArea: safeArea, edges: edges)
                if map.isFollowing, let position = session.aircraftPosition { map.center(on: position) }
            }
            .onChange(of: summaryHeight) { _, _ in updateChromeInsets(safeArea: safeArea, edges: edges) }
    }

    // MARK: Hiding the readings

    private func setReadingsHidden(_ hidden: Bool) {
        withAnimation(.smooth(duration: 0.35)) { readingsHidden = hidden }
    }

    /// Top of the readings panel: tap (or swipe down / right) to hide it.
    private func hideButton(isWide: Bool) -> some View {
        Button {
            setReadingsHidden(true)
        } label: {
            Image(systemName: isWide ? "chevron.compact.right" : "chevron.compact.down")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Theme.secondaryText)
                .frame(maxWidth: .infinity, alignment: isWide ? .trailing : .center)
                .padding(.horizontal, 16)
                .frame(minHeight: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(DragGesture(minimumDistance: 12).onEnded { value in
            let distance = isWide ? value.translation.width : value.translation.height
            if distance > 30 { setReadingsHidden(true) }
        })
        .accessibilityLabel("Hide readings")
        .accessibilityHint("Shows the map full screen")
    }

    /// Compact, semi-transparent readings shown along the bottom when the full panel is hidden.
    /// The map continues underneath it. Tap or swipe up for the full readings.
    private func summaryPanel(columns: Int) -> some View {
        TimelineView(.periodic(from: .now, by: 5)) { timeline in
            ReadingsSummary(readings: readings(at: timeline.date), plan: session.plan, units: units, columns: columns)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            // Grabber: the panel can be pulled up into the full readings.
            Capsule()
                .fill(Theme.secondaryText.opacity(0.45))
                .frame(width: 36, height: 4)
                .padding(.top, 5)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .onTapGesture { setReadingsHidden(false) }
        .gesture(DragGesture(minimumDistance: 12).onEnded { value in
            if value.translation.height < -30 { setReadingsHidden(false) }
        })
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Shows the full readings")
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { summaryHeight = $0 }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func topBar(_ readings: FlightReadings) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Button {
                model.editFlight()
            } label: {
                HStack(spacing: 8) {
                    Text(session.plan.title)
                        .font(.headline.monospaced())
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.secondaryText)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(minHeight: 44)
                .floatingChrome(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Flight from \(session.plan.origin.city) to \(session.plan.destination.city)")
            .accessibilityHint("Edit flight details")

            Spacer(minLength: 4)

            GPSStatusPill(signal: readings.signal, now: Date())
            menu
        }
    }

    private var menu: some View {
        Menu {
            Picker("Map", selection: $mapStyle) {
                ForEach(MapStyle.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
            }
            Picker("Units", selection: $units) {
                ForEach(UnitSystem.allCases) { Text($0.title).tag($0) }
            }
            Picker("GPS Updates", selection: Bindable(model).gpsInterval) {
                ForEach(AppModel.gpsIntervalChoices, id: \.self) { Text("Every \($0) seconds").tag($0) }
            }
            Button {
                setReadingsHidden(!readingsHidden)
            } label: {
                Label(readingsHidden ? "Show Full Readings" : "Compact Readings (Bigger Map)",
                      systemImage: readingsHidden ? "rectangle.expand.vertical" : "rectangle.compress.vertical")
            }
            Button {
                map.fit(session.framingPoints)
            } label: {
                Label("Show Whole Route", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            Button {
                showingAbout = true
            } label: {
                Label("About These Readings", systemImage: "info.circle")
            }
            Divider()
            Button {
                model.editFlight()
            } label: {
                Label("Edit Flight…", systemImage: "pencil")
            }
            Button(role: .destructive) {
                confirmingEnd = true
            } label: {
                Label("End Flight", systemImage: "xmark.circle")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .floatingChrome(in: Circle())
                .contentShape(Circle())
        }
        .accessibilityLabel("Flight options")
    }

    /// Tells the map which parts of it are covered by the top bar, buttons and safe areas so
    /// the aircraft is centred in the visible part and labels stay clear of the controls.
    private func updateChromeInsets(safeArea: EdgeInsets, edges: Edge.Set) {
        map.chromeInsets = EdgeInsets(
            top: (edges.contains(.top) ? safeArea.top : 0) + 62,
            leading: edges.contains(.leading) ? safeArea.leading : 0,
            bottom: (edges.contains(.bottom) ? safeArea.bottom : 0) + 12 + (readingsHidden ? summaryHeight : 0),
            trailing: 64)
    }

    private func followAircraft() {
        guard let position = session.aircraftPosition else { return }
        map.center(on: position)
    }

    /// First framing: centred on the aircraft (or the whole route if there's no fix yet),
    /// zoomed so both airports stay in view where possible.
    private func initialCamera(for size: CGSize) -> GeoCamera? {
        guard var camera = GeoCamera.framing(session.framingPoints, around: session.aircraftPosition,
                                             style: map.style, size: size, padding: map.fitPadding) else { return nil }
        if map.style == .globe {
            // Start a little further out than a tight fit so the curve of the earth shows.
            camera.radius *= 0.72
            camera = camera.clamped(style: .globe, size: size)
            if let position = session.aircraftPosition {
                camera = camera.centered(on: position, focusOffset: map.focusOffset, style: .globe, size: size)
            }
        }
        return camera
    }

    /// "Position every 30 s, last fix 12 s ago."
    private func fixAge(_ readings: FlightReadings, now: Date) -> String {
        let every = "Position every \(model.gpsInterval) s"
        guard let time = readings.lastFixTime else { return every + "." }
        let age = max(0, Int(now.timeIntervalSince(time)))
        let ago = age < 90 ? "\(age) s ago" : "\(age / 60) min ago"
        return "\(every), last fix \(ago)."
    }

    private func mapSummary(_ readings: FlightReadings) -> String {
        var parts = ["Route from \(session.plan.origin.name) to \(session.plan.destination.name)."]
        if let progress = readings.progress {
            parts.append("Aircraft about \(Int((progress * 100).rounded())) percent along the route.")
        } else {
            parts.append("Aircraft position not yet known.")
        }
        parts.append(map.isFollowing ? "Map is following the aircraft." : "Map is not following the aircraft.")
        return parts.joined(separator: " ")
    }

    // MARK: Panel

    private func panel(_ readings: FlightReadings, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            RouteProgressView(plan: session.plan, progress: readings.progress,
                              remaining: readings.remainingDistance, units: units)
            MetricsGrid(readings: readings, plan: session.plan, units: units)
            HStack(alignment: .firstTextBaseline) {
                Text("From this iPhone's GPS, not the aircraft's instruments. \(fixAge(readings, now: now))")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                Spacer(minLength: 8)
                Button("About") { showingAbout = true }
                    .font(.caption.weight(.semibold))
                    .accessibilityLabel("About these readings")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
