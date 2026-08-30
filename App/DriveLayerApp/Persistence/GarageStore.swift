import Foundation
import SwiftData

/// Reads and writes everything the app persists.
///
/// Main-actor bound because `ModelContext` is not sendable and every caller is UI.
/// Errors are surfaced through `lastError` rather than swallowed: a failed write is
/// something the driver should eventually be told about, not something that quietly
/// loses their fuel log.
@MainActor
@Observable
final class GarageStore {

    private let context: ModelContext
    private(set) var lastError: String?

    init(context: ModelContext) {
        self.context = context
    }

    /// Rows this build could not decode. Shown in the Debug Center: a non-zero value
    /// means a migration is missing, not that the data is gone.
    private(set) var undecodablePayloads = 0


    private func perform(_ description: String, _ work: () throws -> Void) {
        do {
            try work()
            try context.save()
        } catch {
            lastError = "\(description) failed: \(error.localizedDescription)"
            PrivacyLog.logger(.persistence).error("\(description, privacy: .public) failed")
        }
    }

    /// Decodes stored rows, counting whatever will not decode instead of discarding it.
    ///
    /// Every load site used to be `compactMap { try? $0.value() }`, which turned an
    /// unreadable payload into a row that had simply never existed: no throw, no log,
    /// nothing for the driver or for us to notice. A payload this build cannot read is
    /// far more likely to be one a *later* build can -- a migration not yet written, or
    /// data from a newer version -- so the row is left on disk untouched and the failure
    /// is surfaced instead.
    private func decodeAll<Record, Value>(_ records: [Record],
                                          description: String,
                                          _ transform: (Record) throws -> Value) -> [Value] {
        var values: [Value] = []
        var failures = 0
        for record in records {
            do {
                values.append(try transform(record))
            } catch {
                failures += 1
            }
        }
        if failures > 0 {
            undecodablePayloads += failures
            lastError = "\(description): \(failures) saved item(s) could not be read and were kept for a later version."
            PrivacyLog.logger(.persistence).error("\(description, privacy: .public): \(failures, privacy: .public) undecodable payloads")
        }
        return values
    }

    private func fetch<T: PersistentModel>(_ descriptor: FetchDescriptor<T>, description: String) -> [T] {
        do {
            return try context.fetch(descriptor)
        } catch {
            lastError = "\(description) failed: \(error.localizedDescription)"
            return []
        }
    }

    // MARK: - Vehicles

    func vehicles() -> [Vehicle] {
        let descriptor = FetchDescriptor<StoredVehicle>(sortBy: [SortDescriptor(\.createdAt)])
        return decodeAll(fetch(descriptor, description: "Loading vehicles"),
                         description: "Loading vehicles") { try $0.value() }
    }

    func primaryVehicle() -> Vehicle? {
        let all = vehicles()
        return all.first { $0.isPrimary } ?? all.first
    }

    func add(vehicle: Vehicle) {
        perform("Saving the vehicle") {
            let record = try StoredVehicle(vehicle: vehicle)
            context.insert(record)
            // Adding a vehicle brings its profile's service schedule with it, each
            // item tagged with where its interval came from.
            let profile = VehicleProfileCatalog.profile(id: vehicle.profileID)
            for item in MaintenanceEngine.defaultItems(for: vehicle, profile: profile) {
                context.insert(try StoredMaintenanceItem(item: item))
            }
        }
    }

    func update(vehicle: Vehicle) {
        let id = vehicle.id
        let descriptor = FetchDescriptor<StoredVehicle>(predicate: #Predicate { $0.id == id })
        perform("Updating the vehicle") {
            guard let record = try context.fetch(descriptor).first else { return }
            try record.update(with: vehicle)
        }
    }

    func setPrimaryVehicle(id: UUID) {
        perform("Switching vehicle") {
            for record in try context.fetch(FetchDescriptor<StoredVehicle>()) {
                record.isPrimary = (record.id == id)
                if var value = try? record.value() {
                    value.isPrimary = record.isPrimary
                    try record.update(with: value)
                }
            }
        }
    }

    /// Removes a vehicle and everything belonging to it. Used by "delete all data for
    /// this vehicle" in privacy settings, so it must genuinely leave nothing behind.
    func delete(vehicleID: UUID) {
        // StoredDocument.vehicleID is optional, so the predicate needs an optional to
        // compare against rather than relying on promotion.
        let optionalVehicleID: UUID? = vehicleID
        // Collected before the rows go, because afterwards there is nothing left to say
        // which files belonged to this vehicle. That is how the scans used to survive:
        // the metadata was deleted first and took the only reference with it.
        let documentIDs = documents(vehicleID: vehicleID).map(\.id)
        perform("Deleting the vehicle") {
            try context.delete(model: StoredTrip.self, where: #Predicate { $0.vehicleID == vehicleID })
            try context.delete(model: StoredFuelEntry.self, where: #Predicate { $0.vehicleID == vehicleID })
            try context.delete(model: StoredMaintenanceItem.self, where: #Predicate { $0.vehicleID == vehicleID })
            try context.delete(model: StoredServiceRecord.self, where: #Predicate { $0.vehicleID == vehicleID })
            try context.delete(model: StoredBaselineAggregate.self, where: #Predicate { $0.vehicleID == vehicleID })
            try context.delete(model: StoredRoadEvent.self, where: #Predicate { $0.vehicleID == vehicleID })
            try context.delete(model: StoredDocument.self, where: #Predicate { $0.vehicleID == optionalVehicleID })
            try context.delete(model: StoredVehicle.self, where: #Predicate { $0.id == vehicleID })
        }
        TelemetryFileStore.shared.deleteAll(forVehicle: vehicleID)
        DocumentFileStore.shared.delete(documentIDs: documentIDs)
    }

    // MARK: - Trips

    func trips(vehicleID: UUID, limit: Int? = nil) -> [Trip] {
        var descriptor = FetchDescriptor<StoredTrip>(
            predicate: #Predicate { $0.vehicleID == vehicleID },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return decodeAll(fetch(descriptor, description: "Loading drives"),
                         description: "Loading drives") { try $0.value() }
    }

    func save(trip: Trip) {
        let id = trip.id
        let descriptor = FetchDescriptor<StoredTrip>(predicate: #Predicate { $0.id == id })
        perform("Saving the drive") {
            if let existing = try context.fetch(descriptor).first {
                try existing.update(with: trip)
            } else {
                context.insert(try StoredTrip(trip: trip))
            }
        }
    }

    func delete(tripID: UUID) {
        perform("Deleting the drive") {
            try context.delete(model: StoredTrip.self, where: #Predicate { $0.id == tripID })
        }
    }

    /// Drives that were still open when the app was last terminated.
    /// A drive by id, whichever vehicle it belongs to.
    ///
    /// Reconciliation starts from journal directories on disk, which name a trip id and
    /// nothing else, so the vehicle-scoped lookups are the wrong shape for it.
    func trip(id: UUID) -> Trip? {
        let descriptor = FetchDescriptor<StoredTrip>(predicate: #Predicate { $0.id == id })
        return decodeAll(fetch(descriptor, description: "Loading a drive"),
                         description: "Loading a drive") { try $0.value() }.first
    }

    /// Whether a drive row exists at all, decodable or not.
    ///
    /// Deliberately distinct from `trip(id:)`. A row whose payload this build cannot read
    /// is emphatically not an orphan, and treating it as one would delete the telemetry
    /// belonging to a drive a later build can still recover.
    func tripRowExists(id: UUID) -> Bool {
        let descriptor = FetchDescriptor<StoredTrip>(predicate: #Predicate { $0.id == id })
        return !fetch(descriptor, description: "Checking for a drive").isEmpty
    }

    func openTrips(vehicleID: UUID) -> [Trip] {
        trips(vehicleID: vehicleID).filter { !$0.isComplete }
    }

    // MARK: - Fuel

    func fuelEntries(vehicleID: UUID) -> [FuelEntry] {
        let descriptor = FetchDescriptor<StoredFuelEntry>(
            predicate: #Predicate { $0.vehicleID == vehicleID },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        return decodeAll(fetch(descriptor, description: "Loading fuel entries"),
                         description: "Loading fuel entries") { try $0.value() }
    }

    func add(fuelEntry: FuelEntry) {
        perform("Saving the fuel entry") {
            context.insert(try StoredFuelEntry(entry: fuelEntry))
        }
    }

    func delete(fuelEntryID: UUID) {
        perform("Deleting the fuel entry") {
            try context.delete(model: StoredFuelEntry.self, where: #Predicate { $0.id == fuelEntryID })
        }
    }

    // MARK: - Maintenance and documents

    func maintenanceItems(vehicleID: UUID) -> [MaintenanceItem] {
        let descriptor = FetchDescriptor<StoredMaintenanceItem>(predicate: #Predicate { $0.vehicleID == vehicleID })
        return decodeAll(fetch(descriptor, description: "Loading maintenance"),
                         description: "Loading maintenance") { try $0.value() }
    }

    func save(maintenanceItem: MaintenanceItem) {
        let id = maintenanceItem.id
        let descriptor = FetchDescriptor<StoredMaintenanceItem>(predicate: #Predicate { $0.id == id })
        perform("Saving the maintenance item") {
            if let existing = try context.fetch(descriptor).first {
                try existing.update(with: maintenanceItem)
            } else {
                context.insert(try StoredMaintenanceItem(item: maintenanceItem))
            }
        }
    }

    func serviceRecords(vehicleID: UUID) -> [ServiceRecord] {
        let descriptor = FetchDescriptor<StoredServiceRecord>(
            predicate: #Predicate { $0.vehicleID == vehicleID },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        return decodeAll(fetch(descriptor, description: "Loading service history"),
                         description: "Loading service history") { try $0.value() }
    }

    func add(serviceRecord: ServiceRecord) {
        perform("Saving the service record") {
            context.insert(try StoredServiceRecord(record: serviceRecord))
        }
    }

    func documents(vehicleID: UUID?) -> [DocumentRecord] {
        let descriptor = FetchDescriptor<StoredDocument>(sortBy: [SortDescriptor(\.expiryDate)])
        let all = decodeAll(fetch(descriptor, description: "Loading documents"),
                            description: "Loading documents") { try $0.value() }
        guard let vehicleID else { return all }
        return all.filter { $0.vehicleID == vehicleID || $0.vehicleID == nil }
    }

    func add(document: DocumentRecord) {
        perform("Saving the document") {
            context.insert(try StoredDocument(document: document))
        }
    }

    func delete(documentID: UUID) {
        perform("Deleting the document") {
            try context.delete(model: StoredDocument.self, where: #Predicate { $0.id == documentID })
        }
        DocumentFileStore.shared.delete(documentID: documentID)
    }

    // MARK: - Baselines

    func baselineAggregates(vehicleID: UUID) -> [BaselineDailyAggregate] {
        let descriptor = FetchDescriptor<StoredBaselineAggregate>(predicate: #Predicate { $0.vehicleID == vehicleID })
        return fetch(descriptor, description: "Loading baselines").compactMap { $0.value() }
    }

    /// Folds a day's observations into storage, merging with any existing day.
    func merge(aggregates: [BaselineDailyAggregate], vehicleID: UUID) {
        guard !aggregates.isEmpty else { return }
        perform("Updating baselines") {
            for aggregate in aggregates {
                let identifier = StoredBaselineAggregate.identifier(vehicleID: vehicleID, aggregate: aggregate)
                let descriptor = FetchDescriptor<StoredBaselineAggregate>(predicate: #Predicate { $0.identifier == identifier })
                if let existing = try context.fetch(descriptor).first {
                    existing.merge(aggregate)
                } else {
                    context.insert(StoredBaselineAggregate(vehicleID: vehicleID, aggregate: aggregate))
                }
            }
        }
    }

    /// Discards everything learned about one vehicle, on explicit request.
    ///
    /// Not called by retention. See `AppEnvironment.applyRetentionPolicy()`.
    func deleteBaselines(vehicleID: UUID) {
        perform("Resetting learned baselines") {
            try context.delete(model: StoredBaselineAggregate.self,
                               where: #Predicate { $0.vehicleID == vehicleID })
        }
    }

    /// Drops baseline history older than a cutoff.
    ///
    /// Retained for the Debug Center and for a future explicit control; deliberately
    /// **not** wired to the telemetry retention setting any more.
    func pruneBaselines(olderThan cutoff: Date) {
        perform("Pruning baselines") {
            try context.delete(model: StoredBaselineAggregate.self, where: #Predicate { $0.dayStart < cutoff })
        }
    }

    // MARK: - Adapters

    func rememberedDevices() -> [StoredOBDDevice] {
        fetch(FetchDescriptor<StoredOBDDevice>(sortBy: [SortDescriptor(\.lastConnectedAt, order: .reverse)]),
              description: "Loading adapters")
    }

    func remember(deviceIdentifier: String, name: String, adapter: String?, protocolDescription: String?) {
        let descriptor = FetchDescriptor<StoredOBDDevice>(predicate: #Predicate { $0.identifier == deviceIdentifier })
        perform("Saving the adapter") {
            if let existing = try context.fetch(descriptor).first {
                existing.name = name
                existing.lastConnectedAt = Date()
                existing.adapterDescription = adapter
                existing.protocolDescription = protocolDescription
            } else {
                let record = StoredOBDDevice(identifier: deviceIdentifier, name: name, lastConnectedAt: Date())
                record.adapterDescription = adapter
                record.protocolDescription = protocolDescription
                context.insert(record)
            }
        }
    }

    func forgetDevices() {
        perform("Forgetting adapters") {
            try context.delete(model: StoredOBDDevice.self)
        }
    }

    // MARK: - Road events

    func add(roadEvent: RoadImpactEvent, vehicleID: UUID) {
        perform("Saving the road event") {
            context.insert(try StoredRoadEvent(vehicleID: vehicleID, event: roadEvent))
        }
    }

    func roadEvents(vehicleID: UUID) -> [RoadImpactEvent] {
        let descriptor = FetchDescriptor<StoredRoadEvent>(
            predicate: #Predicate { $0.vehicleID == vehicleID },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        return decodeAll(fetch(descriptor, description: "Loading road events"),
                         description: "Loading road events") { try $0.value() }
    }

    // MARK: - Privacy controls

    /// Removes every record the app holds. Backs "Delete all data" in settings.
    func deleteEverything() {
        perform("Deleting all data") {
            try context.delete(model: StoredTrip.self)
            try context.delete(model: StoredFuelEntry.self)
            try context.delete(model: StoredMaintenanceItem.self)
            try context.delete(model: StoredServiceRecord.self)
            try context.delete(model: StoredDocument.self)
            try context.delete(model: StoredBaselineAggregate.self)
            try context.delete(model: StoredRoadEvent.self)
            try context.delete(model: StoredOBDDevice.self)
            try context.delete(model: StoredVehicle.self)
        }
        TelemetryFileStore.shared.deleteEverything()
        DocumentFileStore.shared.deleteEverything()
    }

    /// Everything about one vehicle, as JSON, for the export control in settings.
    func exportBundle(vehicleID: UUID) throws -> Data {
        struct ExportBundle: Encodable {
            var exportedAt: Date
            var vehicle: Vehicle?
            var trips: [Trip]
            var fuelEntries: [FuelEntry]
            var maintenanceItems: [MaintenanceItem]
            var serviceRecords: [ServiceRecord]
            var documents: [DocumentRecord]
            /// Included because these carry coordinates. An export that quietly left
            /// out a location-bearing record type would not be the whole truth.
            var roadEvents: [RoadImpactEvent]
        }
        let bundle = ExportBundle(exportedAt: Date(),
                                  vehicle: vehicles().first { $0.id == vehicleID },
                                  trips: trips(vehicleID: vehicleID),
                                  fuelEntries: fuelEntries(vehicleID: vehicleID),
                                  maintenanceItems: maintenanceItems(vehicleID: vehicleID),
                                  serviceRecords: serviceRecords(vehicleID: vehicleID),
                                  documents: documents(vehicleID: vehicleID),
                                  roadEvents: roadEvents(vehicleID: vehicleID))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(bundle)
    }
}
