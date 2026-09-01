import Foundation

/// Shared behaviour for the two on-disk stores: everything DriveLayer writes is
/// protected, excluded from iCloud backup where it is regenerable, and deletable.
private enum ProtectedDirectory {

    static func url(named name: String, excludedFromBackup: Bool) -> URL? {
        guard var base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        base.appendPathComponent("DriveLayer/\(name)", isDirectory: true)
        do {
            if !FileManager.default.fileExists(atPath: base.path) {
                try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [
                    .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
                ])
            }
            if excludedFromBackup {
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                var mutable = base
                try mutable.setResourceValues(values)
            }
            return base
        } catch {
            PrivacyLog.error(.persistence, "Could not prepare the \(name) directory")
            return nil
        }
    }
}

/// Stores each drive's telemetry as one compact blob.
///
/// Telemetry is regenerable-ish bulk data: it is excluded from backup so a driver's
/// iCloud backup does not carry hundreds of megabytes of engine samples, and it is
/// written with file protection so it is unreadable while the device is locked.
/// The telemetry write surface the drive coordinator depends on.
///
/// A protocol rather than the singleton because the interesting path is the one that
/// fails. Samples have to survive a write that did not happen, and a test that can only
/// ever succeed cannot demonstrate that they do.
protocol TelemetryWriting: Sendable {
    /// True only once the samples are on disk. See the note on the implementation.
    @discardableResult
    func appendChunk(samples: [TelemetrySample], vehicleID: UUID, tripID: UUID) -> Bool
    /// Discardable at the recovery call site, where a failure simply leaves the journal in
    /// place to be compacted at the next launch.
    @discardableResult
    func finalise(vehicleID: UUID, tripID: UUID, appending trailing: [TelemetrySample]) -> Bool
    func discardJournal(vehicleID: UUID, tripID: UUID)
}

extension TelemetryFileStore: TelemetryWriting {}

final class TelemetryFileStore: @unchecked Sendable {

    static let shared = TelemetryFileStore()

    /// Serialises access to the directory. The journal is a value type holding only a
    /// URL, so this queue is the whole of the concurrency story: appends from the drive
    /// loop, reads from the trip screen and deletions from privacy settings all run one
    /// at a time, in the order they were asked for.
    private let queue = DispatchQueue(label: "com.drivelayer.telemetry-store")

    /// Nil only if the directory could not be prepared, in which case every call below
    /// becomes a no-op rather than a crash - losing telemetry is not worth a crash.
    private lazy var journal: TelemetryJournal? = ProtectedDirectory
        .url(named: "Telemetry", excludedFromBackup: true)
        .map { TelemetryJournal(root: $0) }

    /// Writes a drive's telemetry in one go, for callers holding all of it in memory.
    @discardableResult
    func write(samples: [TelemetrySample], vehicleID: UUID, tripID: UUID) -> Bool {
        guard let journal else { return false }
        return queue.sync { journal.finalise(vehicleID: vehicleID, tripID: tripID, appending: samples) }
    }

    /// Appends a chunk for a drive that is still going. See `TelemetryJournal`.
    ///
    /// Synchronous, and the result is the point of it. This used to be `queue.async` with
    /// the journal's `Bool` discarded, and the caller cleared its buffer on the next line
    /// -- so a failed write, or the app being terminated before the queued block ran, lost
    /// the samples with no copy anywhere. `queue.sync` is what `read` and
    /// `interruptedTrips` already do, and a chunk is one small encode plus one atomic
    /// write, so the main thread is held for a trivial period once every twenty seconds.
    /// Losing telemetry is the worse trade.
    @discardableResult
    func appendChunk(samples: [TelemetrySample], vehicleID: UUID, tripID: UUID) -> Bool {
        guard let journal else { return false }
        return queue.sync { journal.appendChunk(samples, vehicleID: vehicleID, tripID: tripID) }
    }

    /// Compacts a finished drive's chunks, plus anything still in memory.
    @discardableResult
    func finalise(vehicleID: UUID, tripID: UUID, appending trailing: [TelemetrySample] = []) -> Bool {
        guard let journal else { return false }
        return queue.sync { journal.finalise(vehicleID: vehicleID, tripID: tripID, appending: trailing) }
    }

    func discardJournal(vehicleID: UUID, tripID: UUID) {
        guard let journal else { return }
        queue.async { journal.discard(vehicleID: vehicleID, tripID: tripID) }
    }

    func read(vehicleID: UUID, tripID: UUID) -> [TelemetrySample] {
        guard let journal else { return [] }
        return queue.sync { journal.samples(vehicleID: vehicleID, tripID: tripID) }
    }

    func delete(vehicleID: UUID, tripID: UUID) {
        guard let journal else { return }
        queue.async { journal.delete(vehicleID: vehicleID, tripID: tripID) }
    }

    func deleteAll(forVehicle vehicleID: UUID) {
        guard let journal else { return }
        queue.async { journal.deleteAll(vehicleID: vehicleID) }
    }

    func deleteEverything() {
        guard let journal else { return }
        queue.async { journal.deleteEverything() }
    }

    func journalLastWrite(vehicleID: UUID, tripID: UUID) -> Date? {
        guard let journal else { return nil }
        return queue.sync { journal.journalLastWrite(vehicleID: vehicleID, tripID: tripID) }
    }

    /// Drives whose telemetry was never compacted, because the app did not get to
    /// finish them. Read at launch, alongside the interrupted drives in the database.
    func interruptedTrips() -> [(vehicleID: UUID, tripID: UUID)] {
        guard let journal else { return [] }
        return queue.sync { journal.interruptedTrips() }
    }

    /// Deletes raw telemetry older than the driver's retention window.
    @discardableResult
    func deleteCompacted(olderThan cutoff: Date) -> Int {
        guard let journal else { return 0 }
        return queue.sync { journal.deleteCompacted(olderThan: cutoff) }
    }

    /// Total bytes on disk, for the storage row in settings.
    func totalBytes() -> Int64 {
        guard let journal else { return 0 }
        return queue.sync { journal.totalBytes() }
    }
}

/// Stores glovebox documents.
///
/// Complete protection, not the weaker until-first-unlock level: a registration
/// certificate or insurance policy should be unreadable whenever the phone is locked,
/// and nothing in DriveLayer needs to read one in the background.
final class DocumentFileStore: @unchecked Sendable {

    static let shared = DocumentFileStore()

    private lazy var root = ProtectedDirectory.url(named: "Documents", excludedFromBackup: false)

    func fileURL(documentID: UUID, fileExtension: String) -> URL? {
        root?.appendingPathComponent("\(documentID.uuidString).\(fileExtension)")
    }

    @discardableResult
    func store(data: Data, documentID: UUID, fileExtension: String) -> String? {
        guard let url = fileURL(documentID: documentID, fileExtension: fileExtension) else { return nil }
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            return url.lastPathComponent
        } catch {
            PrivacyLog.error(.persistence, "Could not store a document")
            return nil
        }
    }

    func read(fileName: String) -> Data? {
        guard let url = root?.appendingPathComponent(fileName) else { return nil }
        return try? Data(contentsOf: url)
    }

    func delete(documentID: UUID) {
        guard let root else { return }
        let contents = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for url in contents where url.lastPathComponent.hasPrefix(documentID.uuidString) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Empties the directory rather than removing it, for the same reason as
    /// `TelemetryFileStore.deleteEverything()`.
    func deleteEverything() {
        guard let root else { return }
        let contents = (try? FileManager.default.contentsOfDirectory(at: root,
                                                                    includingPropertiesForKeys: nil)) ?? []
        for url in contents {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Removes the files belonging to a set of documents, for vehicle deletion.
    ///
    /// The database rows are deleted by `GarageStore`; without this the scans they
    /// pointed at stayed on disk, unreferenced and so unreachable by any later
    /// cleanup. An insurance policy and a registration certificate are exactly the
    /// files a driver means when they say delete.
    func delete(documentIDs: [UUID]) {
        for id in documentIDs {
            delete(documentID: id)
        }
    }
}
