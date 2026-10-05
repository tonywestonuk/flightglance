import Foundation
import Testing
@testable import FlightGlance

@Suite("Arrival estimate")
struct ETAEstimatorTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let destination = GeoPoint(latitude: 0, longitude: 10)

    /// A point `km` kilometres due west of the destination along the equator.
    func position(kmFromDestination km: Double) -> GeoPoint {
        GeoMath.destination(from: destination, bearing: 270, distance: km * 1000)
    }

    func samples(speed: Double, count: Int = 10, endingAt end: Date? = nil, every interval: TimeInterval = 10) -> [SpeedSample] {
        let end = end ?? now
        return (0..<count).map { SpeedSample(timestamp: end.addingTimeInterval(-Double(count - 1 - $0) * interval), speed: speed) }
    }

    func estimate(position: GeoPoint?, fixTime: Date?, samples: [SpeedSample] = [], track: [TrackPoint] = []) -> ETAEstimator.Result {
        ETAEstimator.estimate(position: position, fixTime: fixTime, destination: destination,
                              speedSamples: samples, track: track, now: now)
    }

    @Test func remainingDistanceOverAverageSpeed() throws {
        let result = estimate(position: position(kmFromDestination: 1_000), fixTime: now, samples: samples(speed: 250))
        guard case .estimate(let eta) = result else { Issue.record("expected an estimate, got \(result)"); return }
        #expect(isClose(eta.remainingDistance, 1_000_000, within: 1))
        #expect(eta.groundSpeed == 250)
        #expect(isClose(eta.timeRemaining, 4_000, within: 0.1))
        #expect(isClose(eta.arrival.timeIntervalSince(now), 4_000, within: 0.1))
        #expect(eta.method == .gpsGroundSpeed)
    }

    @Test func estimateIsAnchoredToTheFixTimeDuringBriefSignalLoss() {
        // Last fix 10 minutes ago: arrival stays put, so time remaining shrinks by 10 minutes.
        let fixTime = now.addingTimeInterval(-600)
        let result = estimate(position: position(kmFromDestination: 1_000), fixTime: fixTime,
                              samples: samples(speed: 250, endingAt: fixTime))
        guard case .estimate(let eta) = result else { Issue.record("expected an estimate"); return }
        #expect(isClose(eta.arrival.timeIntervalSince(fixTime), 4_000, within: 0.1))
        #expect(isClose(eta.timeRemaining, 3_400, within: 0.1))
    }

    @Test func averagesOverTheWindowOnly() {
        // Old slow samples (taxi) fall outside the 5-minute window and are ignored.
        let old = samples(speed: 5, count: 5, endingAt: now.addingTimeInterval(-900))
        let recent = samples(speed: 200, count: 4, endingAt: now) + [SpeedSample(timestamp: now.addingTimeInterval(1), speed: 240)]
        let average = ETAEstimator.averageSpeed(of: old + recent, endingAt: now.addingTimeInterval(1))
        #expect(isClose(average ?? 0, 208, within: 1e-9))
    }

    @Test func noPositionMeansNoEstimate() {
        #expect(estimate(position: nil, fixTime: nil, samples: samples(speed: 250)) == .unavailable(.noPosition))
    }

    @Test func noSpeedReadingsAndNoTrackMeansNoEstimate() {
        #expect(estimate(position: position(kmFromDestination: 500), fixTime: now) == .unavailable(.noSpeed))
        // Too few samples to trust.
        #expect(estimate(position: position(kmFromDestination: 500), fixTime: now,
                         samples: samples(speed: 250, count: 2)) == .unavailable(.noSpeed))
    }

    @Test func zeroSpeedIsNotDividedBy() {
        #expect(estimate(position: position(kmFromDestination: 500), fixTime: now,
                         samples: samples(speed: 0)) == .unavailable(.speedTooLow))
    }

    @Test func taxiSpeedIsTooLowToEstimate() {
        #expect(estimate(position: position(kmFromDestination: 500), fixTime: now,
                         samples: samples(speed: 12)) == .unavailable(.speedTooLow))
    }

    @Test func staleFixWithdrawsTheEstimate() {
        let fixTime = now.addingTimeInterval(-16 * 60)
        #expect(estimate(position: position(kmFromDestination: 500), fixTime: fixTime,
                         samples: samples(speed: 250, endingAt: fixTime)) == .unavailable(.fixTooOld))
    }

    @Test func nearTheDestinationReportsArriving() {
        #expect(estimate(position: position(kmFromDestination: 3), fixTime: now,
                         samples: samples(speed: 70)) == .arriving)
        // Arriving even when speed is unknown or zero (e.g. taxiing in).
        #expect(estimate(position: position(kmFromDestination: 1), fixTime: now) == .arriving)
    }

    @Test func implausiblyLongEstimatesAreRejected() {
        // 19,000 km at just over the minimum speed would be ~8 days.
        #expect(estimate(position: GeoPoint(latitude: 0, longitude: -160), fixTime: now,
                         samples: samples(speed: 26)) == .unavailable(.notCredible))
    }

    @Test func fallsBackToTrackSpeedWithoutGPSSpeed() {
        // Breadcrumbs 15 km apart every 60 s = 250 m/s.
        let track = (0..<5).map { i -> TrackPoint in
            let p = GeoMath.destination(from: position(kmFromDestination: 1_060), bearing: 90, distance: Double(i) * 15_000)
            return TrackPoint(latitude: p.latitude, longitude: p.longitude,
                              timestamp: now.addingTimeInterval(Double(i - 4) * 60), startsNewSegment: false)
        }
        let result = estimate(position: track.last!.coordinate, fixTime: now, track: track)
        guard case .estimate(let eta) = result else { Issue.record("expected an estimate, got \(result)"); return }
        #expect(eta.method == .trackAverage)
        #expect(isClose(eta.groundSpeed, 250, within: 1))
    }

    @Test func estimatesWithFixesEveryFiveMinutes() {
        // Lock Screen mode: one fix every 5 minutes. A plain 5-minute window would hold a
        // single reading; the stretched window still finds enough.
        let sparse = samples(speed: 250, count: 4, every: 300)
        #expect(estimate(position: position(kmFromDestination: 1_000), fixTime: now, samples: sparse)
            == .unavailable(.noSpeed))
        let result = ETAEstimator.estimate(position: position(kmFromDestination: 1_000), fixTime: now,
                                           destination: destination, speedSamples: sparse, track: [], now: now,
                                           configuration: .forSampling(every: 300))
        guard case .estimate(let eta) = result else { Issue.record("expected an estimate, got \(result)"); return }
        #expect(isClose(eta.timeRemaining, 4_000, within: 0.1))
    }

    @Test func trackSpeedIgnoresSignalGaps() {
        let a = TrackPoint(latitude: 0, longitude: 0, timestamp: now.addingTimeInterval(-200), startsNewSegment: false)
        let b = TrackPoint(latitude: 0, longitude: 1, timestamp: now.addingTimeInterval(-100), startsNewSegment: true)
        #expect(ETAEstimator.trackSpeed(of: [a, b], endingAt: now, window: 300) == nil)
    }
}
