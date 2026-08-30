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
            PrivacyLog.logger(.persistence).error("Could not prepare the \(name, privacy: .public) directory")
            return nil
        }
    }
}

/// Stores each drive's telemetry as one compact blob.
///
/// Telemetry is regenerable-ish bulk data: it is excluded from backup so a driver's
/// iCloud backup does not carry hundreds of megabytes of engine samples, and it is
/// written with file protection so it is unreadable while the device is locked.
final class TelemetryFileStore: @unchecked Sendable {

    static let shared = TelemetryFileStore()

    private let queue = DispatchQueue(label: "com.drivelayer.telemetry-store")
    private lazy var root = ProtectedDirectory.url(named: "Telemetry", excludedFromBackup: true)

    private func fileURL(vehicleID: UUID, tripID: UUID) -> URL? {
        root?.appendingPathComponent("\(vehicleID.uuidString)-\(tripID.uuidString).dlts")
    }

    func write(samples: [TelemetrySample], vehicleID: UUID, tripID: UUID) {
        guard !samples.isEmpty, let url = fileURL(vehicleID: vehicleID, tripID: tripID) else { return }
        queue.async {
            do {
                let data = try TelemetrySeriesCodec.encode(samples)
                try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } catch {
                PrivacyLog.logger(.persistence).error("Could not write telemetry for a drive")
            }
        }
    }

    func read(vehicleID: UUID, tripID: UUID) -> [TelemetrySample] {
        guard let url = fileURL(vehicleID: vehicleID, tripID: tripID),
              let data = try? Data(contentsOf: url) else { return [] }
        return (try? TelemetrySeriesCodec.decode(data)) ?? []
    }

    func delete(vehicleID: UUID, tripID: UUID) {
        guard let url = fileURL(vehicleID: vehicleID, tripID: tripID) else { return }
        queue.async { try? FileManager.default.removeItem(at: url) }
    }

    func deleteAll(forVehicle vehicleID: UUID) {
        guard let root else { return }
        queue.async {
            let contents = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            for url in contents where url.lastPathComponent.hasPrefix(vehicleID.uuidString) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    func deleteEverything() {
        guard let root else { return }
        queue.async { try? FileManager.default.removeItem(at: root) }
    }

    /// Total bytes on disk, for the storage row in settings.
    func totalBytes() -> Int64 {
        guard let root,
              let contents = try? FileManager.default.contentsOfDirectory(at: root,
                                                                          includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        return contents.reduce(0) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return total + Int64(size)
        }
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
            PrivacyLog.logger(.persistence).error("Could not store a document")
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

    func deleteEverything() {
        guard let root else { return }
        try? FileManager.default.removeItem(at: root)
    }
}
