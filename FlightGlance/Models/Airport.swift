import Foundation

/// An airport from the bundled database (OurAirports, filtered to scheduled service).
struct Airport: Identifiable, Hashable, Codable, Sendable {
    /// IATA code, e.g. "LHR".
    let iata: String
    /// ICAO code, e.g. "EGLL", when known.
    let icao: String?
    let name: String
    let city: String
    /// ISO 3166-1 alpha-2 country code.
    let countryCode: String
    let latitude: Double
    let longitude: Double
    /// IANA time zone identifier, used to show arrival estimates in local time.
    let timeZoneIdentifier: String?
    /// 0 = large, 1 = medium, 2 = small. Used to rank search results.
    let sizeRank: Int

    var id: String { iata }
    var coordinate: GeoPoint { GeoPoint(latitude: latitude, longitude: longitude) }
    var timeZone: TimeZone? { timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) }

    var countryName: String {
        Locale.current.localizedString(forRegionCode: countryCode) ?? countryCode
    }

    /// "London, United Kingdom"
    var locationDescription: String {
        city.isEmpty ? countryName : "\(city), \(countryName)"
    }
}

/// The route the user is flying. Only the endpoints are known; the line drawn between them
/// is a great-circle *reference*, not the airline's filed route.
struct FlightPlan: Codable, Hashable, Sendable {
    var origin: Airport
    var destination: Airport

    /// Great-circle distance between the airports, in metres.
    var greatCircleDistance: Double {
        GeoMath.distance(origin.coordinate, destination.coordinate)
    }

    var title: String { "\(origin.iata) → \(destination.iata)" }
}
