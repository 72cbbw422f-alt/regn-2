import Foundation
import CoreLocation
import Combine

struct SMHIWarning: Identifiable {
    let id: String
    let event: String
    let areaName: String
    let level: String
    let description: String
    let start: Date?
    let end: Date?
    let distanceKm: Double
}

@MainActor
final class SMHIWarningService: ObservableObject {
    @Published private(set) var warnings: [SMHIWarning] = []
    @Published private(set) var status = "Väntar på position"
    @Published private(set) var lastUpdated: Date?

    private let endpoint = URL(string: "https://opendata-download-warnings.smhi.se/ibww/api/version/1/warning.json")!
    private var lastCoordinate: CLLocationCoordinate2D?

    func refresh(coordinate: CLLocationCoordinate2D) async {
        lastCoordinate = coordinate
        status = "Hämtar officiella SMHI-varningar…"
        do {
            var request = URLRequest(url: endpoint)
            request.timeoutInterval = 20
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            let root = try JSONSerialization.jsonObject(with: data)
            guard let records = root as? [[String: Any]] else { throw URLError(.cannotParseResponse) }
            let now = Date()
            let found = records.flatMap { record -> [SMHIWarning] in
                guard let eventObject = record["event"] as? [String: Any],
                      let event = eventObject["sv"] as? String,
                      let areas = record["warningAreas"] as? [[String: Any]] else { return [] }
                return areas.compactMap { area in
                    guard let geometry = area["area"] as? [String: Any],
                          let geometryObject = geometry["geometry"] as? [String: Any],
                          let type = geometryObject["type"] as? String,
                          let coordinates = geometryObject["coordinates"] else { return nil }
                    let areaName = (area["areaName"] as? [String: Any])?["sv"] as? String ?? "Okänt område"
                    let eventCode = (eventObject["code"] as? String ?? "").uppercased()
                    let geometryProperties = geometry["properties"] as? [String: Any] ?? [:]
                    let geometryCode = (geometryProperties["code"] as? String ?? "").uppercased()
                    let whereDescription = ((area["descriptions"] as? [[String: Any]])?
                        .first(where: { (($0["title"] as? [String: Any])?["code"] as? String) == "WHERE" })?["text"] as? [String: Any])?["sv"] as? String ?? ""
                    let marine = geometryCode == "SWE_SEA_DISTRICTS" ||
                        Self.isMarine(event: event, code: eventCode, area: "\(areaName) \(whereDescription)")
                    let tolerance = marine ? 75.0 : 5.0
                    let distance = Self.distanceToGeometry(latitude: coordinate.latitude,
                                                           longitude: coordinate.longitude,
                                                           type: type, coordinates: coordinates)
                    guard distance <= tolerance else { return nil }

                    let start = Self.parseDate(area["approximateStart"] as? String)
                    let end = Self.parseDate(area["approximateEnd"] as? String)
                    if let end, end < now { return nil }

                    let warningLevel = area["warningLevel"] as? [String: Any] ?? [:]
                    let displayAreaName = whereDescription.isEmpty ? areaName : whereDescription
                    let levelCode = (warningLevel["code"] as? String ?? "").uppercased()
                    let rawLevel = warningLevel["sv"] as? String ?? "Varning"
                    guard ["YELLOW", "ORANGE", "RED"].contains(levelCode) ||
                          ["gul", "orange", "röd", "rod"].contains(rawLevel.lowercased()) else { return nil }
                    let level: String
                    switch levelCode {
                    case "YELLOW": level = "Gul varning"
                    case "ORANGE": level = "Orange varning"
                    case "RED": level = "Röd varning"
                    default:
                        switch rawLevel.lowercased() {
                        case "gul": level = "Gul varning"
                        case "orange": level = "Orange varning"
                        case "röd", "rod": level = "Röd varning"
                        default: level = rawLevel
                        }
                    }
                    let details = (area["descriptions"] as? [[String: Any]])?
                        .first(where: { (($0["title"] as? [String: Any])?["code"] as? String) == "INCIDENT" })
                    let description = (details?["text"] as? [String: Any])?["sv"] as? String ?? event
                    let areaId = String(describing: area["id"] ?? UUID().uuidString)
                    return SMHIWarning(id: "\(record["id"] ?? areaId)-\(areaId)",
                                       event: event, areaName: displayAreaName, level: level,
                                       description: description, start: start, end: end,
                                       distanceKm: distance)
                }
            }
            warnings = found.sorted {
                Self.levelRank($0.level) == Self.levelRank($1.level)
                    ? $0.distanceKm < $1.distanceKm
                    : Self.levelRank($0.level) > Self.levelRank($1.level)
            }
            lastUpdated = now
            status = warnings.isEmpty ? "Inga aktiva SMHI-varningar i ditt område" : "\(warnings.count) aktiva SMHI-varningar nära dig"
        } catch {
            status = "Kunde inte hämta SMHI-data – behåller senaste lyckade resultat"
        }
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func levelRank(_ level: String) -> Int {
        switch level.lowercased() {
        case "röd varning", "röd": return 3
        case "orange varning", "orange": return 2
        case "gul varning", "gul": return 1
        default: return 0
        }
    }

    private static func isMarine(event: String, code: String, area: String) -> Bool {
        let value = "\(event) \(code) \(area)".lowercased()
        return value.contains("till havs") || value.contains("hav") ||
               value.contains("kuling") || value.contains("gale") ||
               value.contains("storm at sea") || code.contains("SEA")
    }

    private static func distanceToGeometry(latitude: Double, longitude: Double,
                                           type: String, coordinates: Any) -> Double {
        let polygons: [[[[Double]]]]
        if type == "Polygon", let polygon = coordinates as? [[[Double]]] {
            polygons = [polygon]
        } else if type == "MultiPolygon", let multi = coordinates as? [[[[Double]]]] {
            polygons = multi
        } else {
            return .infinity
        }
        let point = CLLocation(latitude: latitude, longitude: longitude)
        var minimum = Double.infinity
        for polygon in polygons {
            guard let outer = polygon.first, outer.count >= 3 else { continue }
            let insideOuter = pointInRing(latitude: latitude, longitude: longitude, ring: outer)
            let insideHole = polygon.dropFirst().contains {
                pointInRing(latitude: latitude, longitude: longitude, ring: $0)
            }
            // A point inside a GeoJSON interior ring is outside the warning polygon.
            if insideOuter && !insideHole {
                return 0
            }
            for ring in polygon where ring.count >= 2 {
                for index in 0..<(ring.count - 1) {
                    let a = CLLocation(latitude: ring[index][1], longitude: ring[index][0])
                    let b = CLLocation(latitude: ring[index + 1][1], longitude: ring[index + 1][0])
                    minimum = min(minimum, distance(point, toSegmentFrom: a, to: b))
                }
            }
        }
        return minimum / 1000
    }

    private static func pointInRing(latitude: Double, longitude: Double, ring: [[Double]]) -> Bool {
        guard ring.count >= 3 else { return false }
        var inside = false
        var j = ring.count - 1
        for i in ring.indices {
            let xi = ring[i][0], yi = ring[i][1]
            let xj = ring[j][0], yj = ring[j][1]
            let crosses = ((yi > latitude) != (yj > latitude)) &&
                (longitude < (xj - xi) * (latitude - yi) / ((yj - yi) == 0 ? 0.0000001 : (yj - yi)) + xi)
            if crosses { inside.toggle() }
            j = i
        }
        return inside
    }

    private static func distance(_ point: CLLocation, toSegmentFrom a: CLLocation, to b: CLLocation) -> Double {
        let referenceLatitude = point.coordinate.latitude * .pi / 180
        let scaleX = 111_320.0 * cos(referenceLatitude)
        let scaleY = 110_540.0
        let px = 0.0, py = 0.0
        let ax = (a.coordinate.longitude - point.coordinate.longitude) * scaleX
        let ay = (a.coordinate.latitude - point.coordinate.latitude) * scaleY
        let bx = (b.coordinate.longitude - point.coordinate.longitude) * scaleX
        let by = (b.coordinate.latitude - point.coordinate.latitude) * scaleY
        let dx = bx - ax, dy = by - ay
        let denominator = dx * dx + dy * dy
        let t = denominator == 0 ? 0 : max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / denominator))
        return hypot(ax + t * dx, ay + t * dy)
    }
}
