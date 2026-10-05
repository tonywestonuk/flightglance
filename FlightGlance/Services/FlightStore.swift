import Foundation

/// Everything needed to resume a flight after the app is closed or relaunched mid-flight.
struct SavedFlight: Codable, Sendable {
    var plan: FlightPlan
    var startedAt: Date
    var recorder: TrackRecorder
    var simulation: FlightSimulation?
}

/// Persists the active flight as JSON in Application Support. Local only; never uploaded.
struct FlightStore: Sendable {
    let url: URL

    static var standard: FlightStore {
        let directory = URL.applicationSupportDirectory.appending(path: "FlightGlance", directoryHint: .isDirectory)
        return FlightStore(url: directory.appending(path: "active-flight.json"))
    }

    func load() -> SavedFlight? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(SavedFlight.self, from: data)
    }

    func save(_ flight: SavedFlight) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(flight)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}
