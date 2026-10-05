import SwiftUI

@main
struct FlightGlanceApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(Theme.accent)
                .task { await model.loadResources() }
                .onChange(of: scenePhase) { _, phase in model.scenePhaseChanged(to: phase) }
                #if DEBUG
                .onAppear(perform: applyDebugOrientation)
                #endif
        }
    }
}

#if DEBUG
/// `-FGLandscape YES` rotates the app to landscape (for screenshots in the Simulator).
@MainActor
private func applyDebugOrientation() {
    guard UserDefaults.standard.bool(forKey: "FGLandscape"),
          let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
    scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight))
}
#endif

/// Switches between the setup screen and the in-flight dashboard.
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            switch model.phase {
            case .loading:
                ProgressView("Loading offline map…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.background)
            case .failed(let message):
                ContentUnavailableView("Map data unavailable", systemImage: "exclamationmark.triangle",
                                       description: Text(message))
            case .setup:
                SetupView()
                    .transition(.opacity)
            case .inFlight:
                if let session = model.session, let atlas = model.atlas {
                    DashboardView(session: session, atlas: atlas)
                        .transition(.opacity)
                }
            }
        }
        .animation(.smooth(duration: 0.35), value: model.phase)
    }
}
