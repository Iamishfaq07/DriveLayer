import Foundation

/// Something a driver chose to report about the road.
struct RoadReport: Sendable, Equatable, Identifiable, Codable {
    enum Kind: String, Sendable, Codable, CaseIterable {
        case roughSurface
        case pothole
        case obstruction
        case flooding
        case fog
        case ice
        case roadworks

        var displayName: String {
            switch self {
            case .roughSurface: return "Rough surface"
            case .pothole: return "Pothole"
            case .obstruction: return "Obstruction"
            case .flooding: return "Flooding"
            case .fog: return "Fog"
            case .ice: return "Ice"
            case .roadworks: return "Roadworks"
            }
        }

        var symbolName: String {
            switch self {
            case .roughSurface: return "road.lanes"
            case .pothole: return "exclamationmark.triangle"
            case .obstruction: return "cone"
            case .flooding: return "water.waves"
            case .fog: return "cloud.fog"
            case .ice: return "snowflake"
            case .roadworks: return "wrench.and.screwdriver"
            }
        }
    }

    var id: UUID
    var kind: Kind
    var latitude: Double
    var longitude: Double
    var createdAt: Date
    var note: String?
    /// Reports are local to this device until the driver explicitly shares them.
    var isSharedExternally: Bool

    init(id: UUID = UUID(),
         kind: Kind,
         latitude: Double,
         longitude: Double,
         createdAt: Date,
         note: String? = nil,
         isSharedExternally: Bool = false) {
        self.id = id
        self.kind = kind
        self.latitude = latitude
        self.longitude = longitude
        self.createdAt = createdAt
        self.note = note
        self.isSharedExternally = isSharedExternally
    }
}

/// Source of road condition information along a route.
///
/// There is no bundled hazard dataset and no crowd network yet. The protocol exists so
/// that when one arrives, nothing else has to change; until then the only conforming
/// source is the driver's own reports, held on their device.
protocol RoadConditionProviding: Sendable {
    var isConfigured: Bool { get }
    /// Reports near a corridor of coordinates.
    func reports(near coordinates: [GeoPoint], radiusMetres: Double) async throws -> [RoadReport]
}

/// The driver's own reports, stored locally. Nothing leaves the device.
actor LocalRoadReportStore: RoadConditionProviding {
    private var stored: [RoadReport] = []

    nonisolated var isConfigured: Bool { true }

    func add(_ report: RoadReport) {
        stored.append(report)
    }

    func remove(id: UUID) {
        stored.removeAll { $0.id == id }
    }

    func all() -> [RoadReport] { stored }

    func replaceAll(_ newReports: [RoadReport]) {
        stored = newReports
    }

    func reports(near coordinates: [GeoPoint], radiusMetres: Double) async throws -> [RoadReport] {
        guard !coordinates.isEmpty else { return [] }
        return stored.filter { report in
            coordinates.contains { point in
                Geo.distance(fromLatitude: point.latitude, longitude: point.longitude,
                             toLatitude: report.latitude, longitude: report.longitude) <= radiusMetres
            }
        }
    }
}
