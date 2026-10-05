import CoreGraphics
import Foundation
import Testing
@testable import FlightGlance

func fix(_ point: GeoPoint, at time: Date, accuracy: Double = 10, speed: Double? = 240) -> GPSFix {
    GPSFix(timestamp: time, coordinate: point, horizontalAccuracy: accuracy,
           altitude: 10_000, verticalAccuracy: 15, speed: speed, speedAccuracy: speed == nil ? nil : 1,
           course: 270, courseAccuracy: 2)
}

@Suite("Track recording")
struct TrackRecorderTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func firstUsableFixStartsTheTrack() {
        var recorder = TrackRecorder()
        #expect(recorder.ingest(fix(heathrow, at: start)) == .added)
        #expect(recorder.points.count == 1)
        #expect(recorder.distanceTraveled == 0)
    }

    @Test func inaccurateAndInvalidFixesAreIgnored() {
        var recorder = TrackRecorder()
        #expect(recorder.ingest(fix(heathrow, at: start, accuracy: 5_000)) == .inaccurate)
        #expect(recorder.ingest(fix(heathrow, at: start, accuracy: -1)) == .inaccurate)
        #expect(recorder.ingest(fix(GeoPoint(latitude: 0, longitude: 0), at: start)) == .inaccurate)
        #expect(recorder.points.isEmpty)
    }

    @Test func jitterDoesNotAddDistance() {
        var recorder = TrackRecorder()
        recorder.ingest(fix(heathrow, at: start, accuracy: 30))
        for i in 1...20 {
            let jitter = GeoMath.destination(from: heathrow, bearing: Double(i * 37 % 360), distance: 40)
            #expect(recorder.ingest(fix(jitter, at: start.addingTimeInterval(Double(i)), accuracy: 30)) == .tooClose)
        }
        #expect(recorder.distanceTraveled == 0)
        #expect(recorder.points.count == 1)
    }

    @Test func distanceAccumulatesAlongTheTrack() {
        var recorder = TrackRecorder()
        for i in 0...10 {
            let p = GeoMath.destination(from: heathrow, bearing: 270, distance: Double(i) * 2_500)
            recorder.ingest(fix(p, at: start.addingTimeInterval(Double(i) * 10)))
        }
        #expect(recorder.points.count == 11)
        #expect(isClose(recorder.distanceTraveled, 25_000, within: 1))
    }

    @Test func impossibleJumpsAreRejectedThenRecovered() {
        var recorder = TrackRecorder()
        recorder.ingest(fix(heathrow, at: start))
        // 500 km in 10 s is a glitch.
        let far = GeoMath.destination(from: heathrow, bearing: 90, distance: 500_000)
        #expect(recorder.ingest(fix(far, at: start.addingTimeInterval(10))) == .outlier)
        #expect(recorder.distanceTraveled == 0)
        // ...but if the receiver insists, the earlier point was the bad one: restart there.
        var result = TrackRecorder.IngestResult.outlier
        for i in 2...5 { result = recorder.ingest(fix(far, at: start.addingTimeInterval(Double(i) * 10))) }
        #expect(result == .added)
        #expect(recorder.points.last?.startsNewSegment == true)
        #expect(recorder.distanceTraveled == 0)
    }

    @Test func outOfOrderFixesAreIgnored() {
        var recorder = TrackRecorder()
        recorder.ingest(fix(heathrow, at: start))
        let later = GeoMath.destination(from: heathrow, bearing: 90, distance: 5_000)
        #expect(recorder.ingest(fix(later, at: start.addingTimeInterval(-5))) == .outOfOrder)
    }

    @Test func longSignalGapStartsANewSegment() {
        var recorder = TrackRecorder()
        recorder.ingest(fix(heathrow, at: start))
        let next = GeoMath.destination(from: heathrow, bearing: 270, distance: 60_000)
        #expect(recorder.ingest(fix(next, at: start.addingTimeInterval(300))) == .added)
        #expect(recorder.points.last?.startsNewSegment == true)
        // The stretch still counts towards distance flown (the aircraft did cover it).
        #expect(isClose(recorder.distanceTraveled, 60_000, within: 1))
    }

    @Test func slowTaxiIsNotMistakenForSignalLoss() {
        var recorder = TrackRecorder()
        recorder.ingest(fix(heathrow, at: start, speed: 8))
        // Fixes every second for four minutes, moving 8 m/s: few stored points, but no gap.
        for second in 1...240 {
            let p = GeoMath.destination(from: heathrow, bearing: 0, distance: Double(second) * 8)
            recorder.ingest(fix(p, at: start.addingTimeInterval(Double(second)), speed: 8))
        }
        #expect(recorder.points.count > 1)
        #expect(recorder.points.allSatisfy { !$0.startsNewSegment })
    }

    @Test func speedHistoryIsTrimmedToTheWindow() {
        var recorder = TrackRecorder()
        for minute in 0..<40 {
            let p = GeoMath.destination(from: heathrow, bearing: 270, distance: Double(minute) * 15_000)
            recorder.ingest(fix(p, at: start.addingTimeInterval(Double(minute) * 60)))
        }
        let span = recorder.speedSamples.last!.timestamp.timeIntervalSince(recorder.speedSamples.first!.timestamp)
        #expect(span <= recorder.configuration.speedHistoryWindow)
    }

    @Test func recorderSurvivesEncoding() throws {
        var recorder = TrackRecorder()
        recorder.ingest(fix(heathrow, at: start))
        recorder.ingest(fix(GeoMath.destination(from: heathrow, bearing: 270, distance: 5_000), at: start.addingTimeInterval(20)))
        let data = try JSONEncoder().encode(recorder)
        let decoded = try JSONDecoder().decode(TrackRecorder.self, from: data)
        #expect(decoded == recorder)
        // Restored state still rejects out-of-order fixes.
        var restored = decoded
        #expect(restored.ingest(fix(heathrow, at: start.addingTimeInterval(10))) == .outOfOrder)
    }
}

@Suite("Dead reckoning")
struct DeadReckoningTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let position = GeoPoint(latitude: 50, longitude: -20)

    @Test func carriesTheFixAlongItsCourseAtItsSpeed() throws {
        let last = fix(position, at: start)
        let estimate = try #require(last.extrapolatedPosition(at: start.addingTimeInterval(300)))
        #expect(isClose(GeoMath.distance(position, estimate), 240 * 300, within: 1))
        #expect(isClose(GeoMath.initialBearing(from: position, to: estimate), 270, within: 0.01))
        #expect(last.extrapolatedPosition(at: start) == position)
    }

    @Test func noEstimateWhenItCantBeTrusted() {
        let later = start.addingTimeInterval(60)
        // Taxiing or holding.
        #expect(fix(position, at: start, speed: 20).extrapolatedPosition(at: later) == nil)
        #expect(fix(position, at: start, speed: nil).extrapolatedPosition(at: later) == nil)
        var noCourse = fix(position, at: start)
        noCourse.course = nil
        #expect(noCourse.extrapolatedPosition(at: later) == nil)
        // Too long after the fix, or before it.
        #expect(fix(position, at: start).extrapolatedPosition(at: start.addingTimeInterval(11 * 60)) == nil)
        #expect(fix(position, at: start).extrapolatedPosition(at: start.addingTimeInterval(-1)) == nil)
    }
}

@Suite("GPS status")
struct GPSSignalStateTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func state(_ authorization: LocationAuthorization = .authorized, fix: GPSFix? = nil, simulated: Bool = false,
               updating: Bool = true, started: Date? = nil) -> GPSSignalState {
        GPSSignalState.evaluate(authorization: authorization, isSimulated: simulated, isUpdating: updating,
                                updatesStarted: started ?? now.addingTimeInterval(-600), lastFix: fix, now: now)
    }

    @Test func permissionStates() {
        #expect(state(.notDetermined) == .permissionNeeded)
        #expect(state(.denied) == .denied)
        #expect(state(.restricted) == .restricted)
        #expect(state(.servicesOff) == .servicesOff)
        #expect(state(.denied, simulated: true) == .simulated)
    }

    @Test func acquiringThenGivingUp() {
        #expect(state(started: now.addingTimeInterval(-10)) == .acquiring)
        #expect(state(started: now.addingTimeInterval(-120)) == .lost(lastFix: nil))
        // Just unlocked: the old fix predates the restart, so it's "finding GPS", not "lost".
        let beforeLock = now.addingTimeInterval(-1_800)
        #expect(state(fix: fix(heathrow, at: beforeLock), started: now.addingTimeInterval(-5)) == .acquiring)
        #expect(GPSSignalState.Thresholds(sampleInterval: 60).lostAfter == 120)
    }

    @Test func accuracyClassification() {
        #expect(state(fix: fix(heathrow, at: now, accuracy: 12)) == .good(accuracy: 12))
        #expect(state(fix: fix(heathrow, at: now, accuracy: 650)) == .weak(accuracy: 650))
    }

    @Test func staleFixMeansSignalLost() {
        // Sampling every 30 s with up to 45 s to acquire: a fix 60 s old is still current...
        #expect(state(fix: fix(heathrow, at: now.addingTimeInterval(-60))).isLive)
        // ...but one older than a full cycle plus slack means the signal is lost.
        let old = now.addingTimeInterval(-120)
        #expect(state(fix: fix(heathrow, at: old)) == .lost(lastFix: old))
        #expect(!state(fix: fix(heathrow, at: old)).isLive)
        #expect(state(fix: fix(heathrow, at: now), updating: false) == .lost(lastFix: now))
    }

    @Test func readingsHideLiveValuesWhenSignalIsLost() {
        let plan = FlightPlan(origin: .sample("LHR", heathrow), destination: .sample("JFK", kennedy))
        let lastFix = fix(GeoMath.interpolate(from: heathrow, to: kennedy, fraction: 0.5), at: now.addingTimeInterval(-60))
        let readings = FlightReadings.make(plan: plan, recorder: TrackRecorder(), latestFix: lastFix,
                                           signal: .lost(lastFix: lastFix.timestamp), now: now)
        #expect(readings.liveFix == nil)
        // Position-derived values remain available, labelled as from the last fix.
        #expect(readings.remainingDistance != nil)
        #expect(isClose(readings.progress ?? 0, 0.5, within: 0.01))
    }
}

@Suite("Flight session & simulation")
@MainActor
struct FlightSessionTests {
    @Test func trackStaysContinuousAcrossTheDateLine() {
        let plan = FlightPlan(origin: .sample("SFO", sanFrancisco), destination: .sample("NRT", narita))
        let simulation = FlightSimulation(origin: sanFrancisco, destination: narita,
                                          anchorDate: Date(), startProgress: 0.9)
        let session = FlightSession(plan: plan, simulation: simulation)
        for fix in simulation.history(until: Date(), interval: 30) { session.ingest(fix) }
        let points = session.track.flatMap { $0 }
        #expect(points.count > 100)
        for (a, b) in zip(points, points.dropFirst()) {
            #expect(abs(b.longitude - a.longitude) < 5)
        }
        // Unwrapped westward past the date line, matching the reference route.
        #expect(points.last!.longitude < -180)
        #expect(session.route.last!.longitude < -180)
    }

    @Test func simulationFliesTheGreatCircle() {
        let anchor = Date()
        let simulation = FlightSimulation(origin: heathrow, destination: kennedy, anchorDate: anchor, startProgress: 0.5)
        let mid = simulation.fix(at: anchor)
        #expect(isClose(GeoMath.routeProgress(of: mid.coordinate, from: heathrow, to: kennedy), 0.5, within: 1e-6))
        #expect(mid.speed! > 200)
        let arrived = simulation.fix(at: anchor.addingTimeInterval(100_000))
        #expect(GeoMath.distance(arrived.coordinate, kennedy) < 1)
        #expect(arrived.speed == 0)
        #expect(arrived.course == nil)
        let history = simulation.history(until: anchor)
        #expect(GeoMath.distance(history.first!.coordinate, heathrow) < 1)
        #expect(zip(history, history.dropFirst()).allSatisfy { $0.timestamp < $1.timestamp })
    }

    @Test func routeRunsFromTheAircraftToTheDestination() {
        let plan = FlightPlan(origin: .sample("LHR", heathrow), destination: .sample("JFK", kennedy))
        let session = FlightSession(plan: plan)
        #expect(GeoMath.distance(session.route.first!, heathrow) < 1)
        let position = GeoPoint(latitude: 50, longitude: -20)
        session.ingest(fix(position, at: Date()))
        #expect(GeoMath.distance(session.route.first!, position) < 1)
        #expect(GeoMath.distance(session.route.last!, kennedy) < 1)
        // The origin stays marked and framed even though the line no longer starts there.
        let overlay = session.overlay(isLive: true)
        #expect(overlay.markers.first { $0.role == .origin }?.coordinate == heathrow)
        #expect(overlay.framingPoints.contains(heathrow))
    }

    @Test func aircraftCourseIsOnlyShownWhenKnown() {
        let plan = FlightPlan(origin: .sample("LHR", heathrow), destination: .sample("JFK", kennedy))
        let session = FlightSession(plan: plan)
        session.ingest(fix(GeoPoint(latitude: 50, longitude: -20), at: Date()))
        #expect(session.overlay(isLive: true).aircraft?.course == 270)
        // Stationary: no course, so a dot is drawn rather than a guessed heading.
        var stationary = fix(GeoPoint(latitude: 50, longitude: -20.1), at: Date().addingTimeInterval(1), speed: 0)
        stationary.course = nil
        session.ingest(stationary)
        #expect(session.overlay(isLive: true).aircraft?.course == nil)
    }

    @Test func headingPointsTheRightWayOnBothMaps() {
        let point = GeoPoint(latitude: 50, longitude: -20)
        let globe = GlobeProjection(camera: GeoCamera(latitude: 45, longitude: -10, radius: 400),
                                    size: CGSize(width: 400, height: 600))
        // West is left on screen (angle ±π); north is up (angle −π/2, screen y grows down).
        #expect(cos(globe.headingAngle(at: point, course: 270)) < -0.98)
        #expect(sin(globe.headingAngle(at: point, course: 0)) < -0.98)
        #expect(cos(AtlasRenderer.headingAngle(at: point, course: 270)) < -0.999)
        #expect(sin(AtlasRenderer.headingAngle(at: point, course: 0)) < -0.999)
    }
}

extension Airport {
    static func sample(_ code: String, _ point: GeoPoint) -> Airport {
        Airport(iata: code, icao: nil, name: "\(code) Airport", city: code, countryCode: "US",
                latitude: point.latitude, longitude: point.longitude, timeZoneIdentifier: nil, sizeRank: 0)
    }
}
