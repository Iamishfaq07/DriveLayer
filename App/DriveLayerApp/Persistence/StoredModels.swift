import Foundation
import SwiftData

/// SwiftData records.
///
/// Each record keeps the fields queries and sorts need as real columns, and stores
/// the rest of the domain value as an encoded payload. That keeps the schema small
/// and stable while the domain models — which are plain `Codable` structs in the core
/// and therefore testable without a database — remain the single source of truth.
///
/// High-frequency telemetry is deliberately absent here: it goes to
/// `TelemetryFileStore` as one compact blob per drive rather than millions of rows.
@Model
final class StoredVehicle {
    @Attribute(.unique) var id: UUID
    var nickname: String
    var profileID: String
    var isPrimary: Bool
    var createdAt: Date
    var odometerKm: Double?
    var payload: Data

    init(vehicle: Vehicle) throws {
        self.id = vehicle.id
        self.nickname = vehicle.nickname
        self.profileID = vehicle.profileID
        self.isPrimary = vehicle.isPrimary
        self.createdAt = vehicle.createdAt
        self.odometerKm = vehicle.odometerKm
        self.payload = try StoredCoding.encode(vehicle)
    }

    func value() throws -> Vehicle { try StoredCoding.decode(Vehicle.self, from: payload) }

    func update(with vehicle: Vehicle) throws {
        nickname = vehicle.nickname
        profileID = vehicle.profileID
        isPrimary = vehicle.isPrimary
        odometerKm = vehicle.odometerKm
        payload = try StoredCoding.encode(vehicle)
    }
}

@Model
final class StoredTrip {
    @Attribute(.unique) var id: UUID
    var vehicleID: UUID
    var startedAt: Date
    var endedAt: Date?
    var distanceMetres: Double
    var payload: Data

    init(trip: Trip) throws {
        self.id = trip.id
        self.vehicleID = trip.vehicleID
        self.startedAt = trip.startedAt
        self.endedAt = trip.endedAt
        self.distanceMetres = trip.distanceMetres
        self.payload = try StoredCoding.encode(trip)
    }

    func value() throws -> Trip { try StoredCoding.decode(Trip.self, from: payload) }

    func update(with trip: Trip) throws {
        endedAt = trip.endedAt
        distanceMetres = trip.distanceMetres
        payload = try StoredCoding.encode(trip)
    }
}

@Model
final class StoredFuelEntry {
    @Attribute(.unique) var id: UUID
    var vehicleID: UUID
    var date: Date
    var payload: Data

    init(entry: FuelEntry) throws {
        self.id = entry.id
        self.vehicleID = entry.vehicleID
        self.date = entry.date
        self.payload = try StoredCoding.encode(entry)
    }

    func value() throws -> FuelEntry { try StoredCoding.decode(FuelEntry.self, from: payload) }
}

@Model
final class StoredMaintenanceItem {
    @Attribute(.unique) var id: UUID
    var vehicleID: UUID
    var isEnabled: Bool
    var payload: Data

    init(item: MaintenanceItem) throws {
        self.id = item.id
        self.vehicleID = item.vehicleID
        self.isEnabled = item.isEnabled
        self.payload = try StoredCoding.encode(item)
    }

    func value() throws -> MaintenanceItem { try StoredCoding.decode(MaintenanceItem.self, from: payload) }

    func update(with item: MaintenanceItem) throws {
        isEnabled = item.isEnabled
        payload = try StoredCoding.encode(item)
    }
}

@Model
final class StoredServiceRecord {
    @Attribute(.unique) var id: UUID
    var vehicleID: UUID
    var date: Date
    var payload: Data

    init(record: ServiceRecord) throws {
        self.id = record.id
        self.vehicleID = record.vehicleID
        self.date = record.date
        self.payload = try StoredCoding.encode(record)
    }

    func value() throws -> ServiceRecord { try StoredCoding.decode(ServiceRecord.self, from: payload) }
}

/// Glovebox metadata. The scanned file itself lives in the protected documents
/// directory; only its filename is stored here.
@Model
final class StoredDocument {
    @Attribute(.unique) var id: UUID
    var vehicleID: UUID?
    var kindRawValue: String
    var expiryDate: Date?
    var payload: Data

    init(document: DocumentRecord) throws {
        self.id = document.id
        self.vehicleID = document.vehicleID
        self.kindRawValue = document.kind.rawValue
        self.expiryDate = document.expiryDate
        self.payload = try StoredCoding.encode(document)
    }

    func value() throws -> DocumentRecord { try StoredCoding.decode(DocumentRecord.self, from: payload) }
}

/// One day of one metric in one context — the unit baselines are built from.
@Model
final class StoredBaselineAggregate {
    @Attribute(.unique) var identifier: String
    var vehicleID: UUID
    var dayStart: Date
    var metricRawValue: String
    var contextRawValue: String
    var count: Int
    var sum: Double
    var minimum: Double
    var maximum: Double

    init(vehicleID: UUID, aggregate: BaselineDailyAggregate) {
        self.identifier = StoredBaselineAggregate.identifier(vehicleID: vehicleID, aggregate: aggregate)
        self.vehicleID = vehicleID
        self.dayStart = aggregate.dayStart
        self.metricRawValue = aggregate.key.metric.rawValue
        self.contextRawValue = aggregate.key.context.rawValue
        self.count = aggregate.count
        self.sum = aggregate.sum
        self.minimum = aggregate.minimum
        self.maximum = aggregate.maximum
    }

    static func identifier(vehicleID: UUID, aggregate: BaselineDailyAggregate) -> String {
        "\(vehicleID.uuidString)|\(aggregate.key.storageIdentifier)|\(Int(aggregate.dayStart.timeIntervalSince1970))"
    }

    func value() -> BaselineDailyAggregate? {
        guard let metric = VehicleMetric(rawValue: metricRawValue),
              let context = BaselineContext(rawValue: contextRawValue) else { return nil }
        var aggregate = BaselineDailyAggregate(key: BaselineKey(metric: metric, context: context),
                                               dayStart: dayStart,
                                               firstValue: 0)
        aggregate.count = count
        aggregate.sum = sum
        aggregate.minimum = minimum
        aggregate.maximum = maximum
        return aggregate
    }

    func merge(_ aggregate: BaselineDailyAggregate) {
        count += aggregate.count
        sum += aggregate.sum
        minimum = Swift.min(minimum, aggregate.minimum)
        maximum = Swift.max(maximum, aggregate.maximum)
    }
}

/// A remembered adapter, so the app can reconnect without asking again.
@Model
final class StoredOBDDevice {
    @Attribute(.unique) var identifier: String
    var name: String
    var lastConnectedAt: Date
    var adapterDescription: String?
    var protocolDescription: String?

    init(identifier: String, name: String, lastConnectedAt: Date) {
        self.identifier = identifier
        self.name = name
        self.lastConnectedAt = lastConnectedAt
    }
}

@Model
final class StoredRoadEvent {
    @Attribute(.unique) var id: UUID
    var vehicleID: UUID
    var timestamp: Date
    var payload: Data

    init(vehicleID: UUID, event: RoadImpactEvent) throws {
        self.id = event.id
        self.vehicleID = vehicleID
        self.timestamp = event.timestamp
        self.payload = try StoredCoding.encode(event)
    }

    func value() throws -> RoadImpactEvent { try StoredCoding.decode(RoadImpactEvent.self, from: payload) }
}

enum StoredCoding {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}

enum DriveLayerSchema {
    /// Every model in the container. Adding a model here is a schema change: bump the
    /// version and add a migration stage rather than editing an existing record shape.
    static let models: [any PersistentModel.Type] = [
        StoredVehicle.self,
        StoredTrip.self,
        StoredFuelEntry.self,
        StoredMaintenanceItem.self,
        StoredServiceRecord.self,
        StoredDocument.self,
        StoredBaselineAggregate.self,
        StoredOBDDevice.self,
        StoredRoadEvent.self
    ]
}
