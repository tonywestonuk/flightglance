import CoreLocation
import Foundation

/// One position report from the GPS, with every optional reading validated.
///
/// Core Location signals "no value" with negative numbers (e.g. `speed == -1`). Those are
/// mapped to `nil` here so no view can accidentally display a sentinel as a real reading.
struct GPSFix: Codable, Equatable, Sendable {
    var timestamp: Date
    var coordinate: GeoPoint
    /// Radius of uncertainty (metres, 68 % confidence).
    var horizontalAccuracy: Double
    /// Altitude above mean sea level from GPS (metres). Not a barometric/pressure altitude.
    var altitude: Double?
    var verticalAccuracy: Double?
    /// Ground speed (m/s) derived by the GPS receiver. Not airspeed.
    var speed: Double?
    var speedAccuracy: Double?
    /// Course over ground (degrees true). Not the aircraft's nose heading.
    var course: Double?
    var courseAccuracy: Double?

    init(timestamp: Date, coordinate: GeoPoint, horizontalAccuracy: Double,
         altitude: Double? = nil, verticalAccuracy: Double? = nil,
         speed: Double? = nil, speedAccuracy: Double? = nil,
         course: Double? = nil, courseAccuracy: Double? = nil) {
        self.timestamp = timestamp
        self.coordinate = coordinate
        self.horizontalAccuracy = horizontalAccuracy
        self.altitude = altitude
        self.verticalAccuracy = verticalAccuracy
        self.speed = speed
        self.speedAccuracy = speedAccuracy
        self.course = course
        self.courseAccuracy = courseAccuracy
    }

    init(location: CLLocation) {
        timestamp = location.timestamp
        coordinate = GeoPoint(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
        horizontalAccuracy = location.horizontalAccuracy
        let altitudeValid = location.verticalAccuracy > 0
        altitude = altitudeValid ? location.altitude : nil
        verticalAccuracy = altitudeValid ? location.verticalAccuracy : nil
        let speedValid = location.speed >= 0 && location.speedAccuracy >= 0
        speed = speedValid ? location.speed : nil
        speedAccuracy = speedValid ? location.speedAccuracy : nil
        let courseValid = location.course >= 0 && location.courseAccuracy >= 0
        course = courseValid ? location.course : nil
        courseAccuracy = courseValid ? location.courseAccuracy : nil
    }

    /// A position is usable only with a non-negative accuracy and a sane coordinate.
    var hasValidPosition: Bool {
        horizontalAccuracy >= 0
            && abs(coordinate.latitude) <= 90 && abs(coordinate.longitude) <= 180
            && !(coordinate.latitude == 0 && coordinate.longitude == 0)
    }

    /// Course is meaningless when barely moving, so hide it below ~10 kt.
    var usableCourse: Double? {
        guard let course, let speed, speed >= 5 else { return nil }
        return course
    }

    /// Dead reckoning: this fix carried forward to `date` along its course at its ground speed.
    /// Fills in the Lock Screen between GPS samples without switching the GPS on. Nil below
    /// ~50 kt (taxiing or holding, where course is unreliable), without a course, or more than
    /// `maximumInterval` after the fix, by when a turn could have taken the aircraft well away.
    func extrapolatedPosition(at date: Date, maximumInterval: TimeInterval = 10 * 60) -> GeoPoint? {
        let elapsed = date.timeIntervalSince(timestamp)
        guard elapsed >= 0, elapsed <= maximumInterval,
              let speed, speed >= 25, let course = usableCourse else { return nil }
        return GeoMath.destination(from: coordinate, bearing: course, distance: speed * elapsed)
    }
}

/// A stored breadcrumb on the observed GPS track.
struct TrackPoint: Codable, Equatable, Sendable {
    var latitude: Double
    var longitude: Double
    var timestamp: Date
    /// True when there was a long gap (signal loss) before this point. The renderer draws
    /// the connection to it as a faint dotted line because that stretch was not observed.
    var startsNewSegment: Bool

    var coordinate: GeoPoint { GeoPoint(latitude: latitude, longitude: longitude) }

    enum CodingKeys: String, CodingKey {
        case latitude = "a", longitude = "o", timestamp = "t", startsNewSegment = "g"
    }
}
