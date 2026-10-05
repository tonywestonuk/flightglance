import Foundation

/// Offline airport search over the bundled `Airports.json`.
final class AirportDatabase: Sendable {
    let airports: [Airport]
    private let byCode: [String: Airport]
    /// Lower-cased, diacritic-folded "city name" per airport, parallel to `airports`.
    private let searchKeys: [String]
    /// Folded city names, parallel to `airports`.
    private let cityKeys: [String]

    init(airports: [Airport]) {
        self.airports = airports
        var codes: [String: Airport] = [:]
        for airport in airports {
            codes[airport.iata] = airport
            if let icao = airport.icao, codes[icao] == nil { codes[icao] = airport }
        }
        byCode = codes
        searchKeys = airports.map { Self.fold("\($0.city) \($0.name)") }
        cityKeys = airports.map { Self.fold($0.city) }
    }

    static func loadBundled(from bundle: Bundle = .main) throws -> AirportDatabase {
        guard let url = bundle.url(forResource: "Airports", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try AirportDatabase(json: Data(contentsOf: url))
    }

    /// Rows are `[iata, icao, name, city, country, lat, lon, tz, sizeRank]`.
    convenience init(json: Data) throws {
        let rows = try JSONDecoder().decode([[JSONScalar]].self, from: json)
        let airports = rows.compactMap { row -> Airport? in
            guard row.count >= 9, let iata = row[0].string, let lat = row[5].double, let lon = row[6].double else {
                return nil
            }
            let icao = row[1].string ?? ""
            let tz = row[7].string ?? ""
            return Airport(iata: iata, icao: icao.isEmpty ? nil : icao, name: row[2].string ?? iata,
                           city: row[3].string ?? "", countryCode: row[4].string ?? "",
                           latitude: lat, longitude: lon, timeZoneIdentifier: tz.isEmpty ? nil : tz,
                           sizeRank: Int(row[8].double ?? 2))
        }
        self.init(airports: airports)
    }

    func airport(code: String) -> Airport? {
        byCode[code.uppercased().trimmingCharacters(in: .whitespaces)]
    }

    /// Ranked search by IATA/ICAO code, city or airport name.
    func search(_ query: String, limit: Int = 60) -> [Airport] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let upper = trimmed.uppercased()
        let folded = Self.fold(trimmed)
        let words = folded.split(separator: " ").map(String.init)

        var ranked: [(rank: Int, airport: Airport)] = []
        for (index, airport) in airports.enumerated() {
            let key = searchKeys[index]
            let rank: Int
            if airport.iata == upper {
                rank = 0
            } else if airport.icao == upper {
                rank = 1
            } else if cityKeys[index].hasPrefix(folded) {
                rank = 2
            } else if key.hasPrefix(folded) || key.contains(" " + folded) {
                rank = 3
            } else if upper.count <= 3, airport.iata.hasPrefix(upper) {
                rank = 4
            } else if words.allSatisfy({ key.contains($0) }) {
                rank = 5
            } else {
                continue
            }
            ranked.append((rank * 10 + airport.sizeRank, airport))
        }
        return ranked
            .sorted { $0.rank != $1.rank ? $0.rank < $1.rank : $0.airport.iata < $1.airport.iata }
            .prefix(limit)
            .map(\.airport)
    }

    /// Nearest airports to a position, largest first among near-ties.
    func nearest(to point: GeoPoint, limit: Int = 3, within radius: Double = 80_000) -> [Airport] {
        airports
            .map { ($0, GeoMath.distance(point, $0.coordinate)) }
            .filter { $0.1 <= radius }
            .sorted { $0.1 < $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    private static func fold(_ string: String) -> String {
        string.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

/// Decodes a heterogeneous JSON array element (string or number).
enum JSONScalar: Decodable {
    case string(String)
    case number(Double)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var double: Double? {
        if case .number(let value) = self { return value }
        return nil
    }
}
