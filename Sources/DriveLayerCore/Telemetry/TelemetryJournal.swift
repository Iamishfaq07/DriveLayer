import Foundation

/// Append-only on-disk storage for a drive's telemetry while the drive is happening.
///
/// Telemetry used to accumulate in an array and be written once, at the end. A long
/// drive therefore grew an unbounded buffer and lost every sample if iOS terminated
/// the app — which it is entitled to do at any point during a two-hour drive.
///
/// The shape here is chunks, not a rewritten file. Each flush writes a new, small,
/// atomic file and never touches the ones already there, so:
///
/// - the cost of a flush does not grow with the length of the drive;
/// - a termination mid-write can cost at most the newest chunk;
/// - a corrupt chunk costs its own twenty seconds, not the whole drive.
///
/// It lives in the core, not the app target, because it is the part with the awkward
/// cases — partial writes, duplicate flushes, recovery after relaunch — and the app
/// target is not reachable by `swift test`. It takes a root URL rather than resolving
/// one, so tests point it at a temporary directory.
struct TelemetryJournal: Sendable {

    /// Where both the chunk directories and the compacted files live.
    let root: URL

    /// `FileManager` is not `Sendable`, so holding one as a stored property makes this
    /// struct only conditionally safe to send - a warning today and an error in Swift 6.
    /// Nothing needed to inject one, so it is read from `.default` at each use instead.
    private var fileManager: FileManager { .default }

    init(root: URL) {
        self.root = root
    }

    // MARK: - Paths

    /// The compacted file for a finished drive.
    func compactedURL(vehicleID: UUID, tripID: UUID) -> URL {
        root.appendingPathComponent("\(vehicleID.uuidString)-\(tripID.uuidString).dlts")
    }

    /// The directory of not-yet-compacted chunks for a drive.
    func journalURL(vehicleID: UUID, tripID: UUID) -> URL {
        root
            .appendingPathComponent("journal", isDirectory: true)
            .appendingPathComponent("\(vehicleID.uuidString)-\(tripID.uuidString)", isDirectory: true)
    }

    private var journalRoot: URL {
        root.appendingPathComponent("journal", isDirectory: true)
    }

    // MARK: - Writing

    /// Appends a chunk. Does nothing for an empty flush rather than writing an empty file.
    @discardableResult
    func appendChunk(_ samples: [TelemetrySample], vehicleID: UUID, tripID: UUID) -> Bool {
        guard !samples.isEmpty else { return false }
        let directory = journalURL(vehicleID: vehicleID, tripID: tripID)
        do {
            try createDirectoryIfNeeded(directory)
            let url = directory.appendingPathComponent(nextChunkName(in: directory))
            let data = try TelemetrySeriesCodec.encode(samples)
            try data.write(to: url, options: [.atomic])
            return true
        } catch {
            PrivacyLog.error(.persistence, "Could not append a telemetry chunk")
            return false
        }
    }

    /// The filename for the next chunk in a journal directory.
    ///
    /// One past the highest sequence already present -- deliberately not one past the
    /// *count*. Those two agree only while the sequence has no gaps, and a gap is
    /// exactly what a removed or unreadable chunk leaves behind. With `chunk-000001`
    /// and `chunk-000003` on disk, counting yields three again, and because the write
    /// below is atomic it replaces `chunk-000003` wholesale: twenty seconds of a drive
    /// nobody has read yet, gone. The previous comment here argued a repeat was
    /// harmless, which was true of read *ordering* and not of overwriting.
    ///
    /// Names stay zero-padded and sortable because `journalledSamples` reads in
    /// filename order, and that order decides which of two samples sharing a timestamp
    /// survives the merge.
    private func nextChunkName(in directory: URL) -> String {
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        let highest = names.compactMap { Self.chunkSequence(of: $0) }.max() ?? 0
        return String(format: "chunk-%06d.dlts", highest + 1)
    }

    /// The sequence number in a name like `chunk-000007.dlts`, or nil for anything else
    /// that happens to be sitting in the directory.
    static func chunkSequence(of name: String) -> Int? {
        let prefix = "chunk-"
        let suffix = ".dlts"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
        let digits = name.dropFirst(prefix.count).dropLast(suffix.count)
        guard !digits.isEmpty, digits.allSatisfy({ $0.isNumber }) else { return nil }
        return Int(digits)
    }

    private func createDirectoryIfNeeded(_ url: URL) throws {
        guard !fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [
            .protectionKey: "NSFileProtectionCompleteUntilFirstUserAuthentication"
        ])
    }

    // MARK: - Reading

    /// Every sample recovered from a drive's chunks, oldest first, duplicates removed.
    ///
    /// A chunk that will not decode is skipped and logged rather than failing the read.
    /// Losing the twenty seconds in a half-written chunk is enormously better than
    /// losing the two hours in the ones around it.
    func journalledSamples(vehicleID: UUID, tripID: UUID) -> [TelemetrySample] {
        let directory = journalURL(vehicleID: vehicleID, tripID: tripID)
        let files = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var samples: [TelemetrySample] = []
        for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where url.pathExtension == "dlts" {
            guard let data = try? Data(contentsOf: url),
                  let decoded = try? TelemetrySeriesCodec.decode(data) else {
                PrivacyLog.error(.persistence, "Skipped an unreadable telemetry chunk")
                continue
            }
            samples.append(contentsOf: decoded)
        }
        return Self.merge(samples)
    }

    /// A drive's telemetry, compacted or not.
    ///
    /// Prefers the compacted file; falls back to the chunks, which is what a drive still
    /// in progress — or one interrupted before it could be compacted — has instead.
    func samples(vehicleID: UUID, tripID: UUID) -> [TelemetrySample] {
        if let data = try? Data(contentsOf: compactedURL(vehicleID: vehicleID, tripID: tripID)),
           let decoded = try? TelemetrySeriesCodec.decode(data) {
            return decoded
        }
        return journalledSamples(vehicleID: vehicleID, tripID: tripID)
    }

    /// Sorted by time, one sample per timestamp.
    ///
    /// The deduplication matters: a checkpoint that flushes and then fails to clear its
    /// buffer, or a retried flush, writes the same samples twice, and a drive is not
    /// more accurate for having counted the same second twice.
    static func merge(_ samples: [TelemetrySample]) -> [TelemetrySample] {
        var seen = Set<Date>()
        return samples
            .sorted { $0.timestamp < $1.timestamp }
            .filter { seen.insert($0.timestamp).inserted }
    }

    // MARK: - Finishing

    /// Compacts a drive's chunks, plus anything still in memory, into one file.
    ///
    /// The chunks are removed **only after** the compacted file is written. A failure or
    /// a termination part-way through therefore leaves the journal intact and the drive
    /// still recoverable, rather than destroying the source before the copy exists.
    @discardableResult
    func finalise(vehicleID: UUID,
                         tripID: UUID,
                         appending trailing: [TelemetrySample] = []) -> Bool {
        let combined = journalledSamples(vehicleID: vehicleID, tripID: tripID) + trailing
        guard !combined.isEmpty else {
            discard(vehicleID: vehicleID, tripID: tripID)
            return true
        }

        do {
            let data = try TelemetrySeriesCodec.encode(Self.merge(combined))
            try createDirectoryIfNeeded(root)
            try data.write(to: compactedURL(vehicleID: vehicleID, tripID: tripID), options: [.atomic])
            discard(vehicleID: vehicleID, tripID: tripID)
            return true
        } catch {
            PrivacyLog.error(.persistence, "Could not compact telemetry; chunks kept for recovery")
            return false
        }
    }

    /// Throws away a drive's chunks, leaving any compacted file alone.
    func discard(vehicleID: UUID, tripID: UUID) {
        try? fileManager.removeItem(at: journalURL(vehicleID: vehicleID, tripID: tripID))
    }

    /// Removes everything for a drive, compacted and not.
    func delete(vehicleID: UUID, tripID: UUID) {
        discard(vehicleID: vehicleID, tripID: tripID)
        try? fileManager.removeItem(at: compactedURL(vehicleID: vehicleID, tripID: tripID))
    }

    // MARK: - Recovery

    /// Drives with chunks still on disk: the ones interrupted before compaction.
    /// When a journal was last written to, or nil if it is not there.
    ///
    /// Reconciliation needs this to tell a journal that outlived its process from one
    /// being written right now. Deleting the latter would throw away the drive in progress.
    func journalLastWrite(vehicleID: UUID, tripID: UUID) -> Date? {
        let directory = journalURL(vehicleID: vehicleID, tripID: tripID)
        let files = (try? fileManager.contentsOfDirectory(at: directory,
                                                         includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let dates = files.compactMap { url -> Date? in
            try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }
        return dates.max()
    }

    func interruptedTrips() -> [(vehicleID: UUID, tripID: UUID)] {
        let entries = (try? fileManager.contentsOfDirectory(atPath: journalRoot.path)) ?? []
        return entries.compactMap(Self.parseIdentifiers).sorted { $0.tripID.uuidString < $1.tripID.uuidString }
    }

    /// Splits a `"<vehicle uuid>-<trip uuid>"` directory name back into two ids.
    static func parseIdentifiers(_ name: String) -> (vehicleID: UUID, tripID: UUID)? {
        // Two 36-character UUIDs and the joining hyphen.
        guard name.count == 73 else { return nil }
        let parts = name.split(separator: "-")
        guard parts.count == 10 else { return nil }
        guard let vehicleID = UUID(uuidString: parts[0..<5].joined(separator: "-")),
              let tripID = UUID(uuidString: parts[5..<10].joined(separator: "-")) else { return nil }
        return (vehicleID: vehicleID, tripID: tripID)
    }

    /// Removes every drive belonging to one vehicle, compacted and journalled.
    func deleteAll(vehicleID: UUID) {
        let prefix = vehicleID.uuidString
        for url in (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        where url.lastPathComponent.hasPrefix(prefix) {
            try? fileManager.removeItem(at: url)
        }
        for url in (try? fileManager.contentsOfDirectory(at: journalRoot, includingPropertiesForKeys: nil)) ?? []
        where url.lastPathComponent.hasPrefix(prefix) {
            try? fileManager.removeItem(at: url)
        }
    }

    /// Empties the store.
    ///
    /// Empties rather than removes the root: callers hold a resolved URL to it, and
    /// deleting the directory itself would leave them writing into somewhere that no
    /// longer exists, silently.
    func deleteEverything() {
        for url in (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            try? fileManager.removeItem(at: url)
        }
    }

    /// Removes compacted telemetry last written before `cutoff`, returning how many
    /// drives were dropped.
    ///
    /// This is what "keep engine history for N days" has to do. The setting used to
    /// prune learned baselines instead, which destroyed the lightweight intelligence
    /// model and kept every raw byte - backwards in both directions at once.
    ///
    /// Journalled chunks are deliberately left alone. A drive still in progress, or one
    /// waiting to be recovered at the next launch, is not history yet.
    @discardableResult
    func deleteCompacted(olderThan cutoff: Date) -> Int {
        var removed = 0
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let contents = (try? fileManager.contentsOfDirectory(at: root,
                                                            includingPropertiesForKeys: keys)) ?? []
        for url in contents where url.pathExtension == "dlts" {
            let modified = (try? url.resourceValues(forKeys: Set(keys)))?.contentModificationDate
            guard let modified, modified < cutoff else { continue }
            do {
                try fileManager.removeItem(at: url)
                removed += 1
            } catch {
                PrivacyLog.error(.persistence, "Could not prune an expired telemetry file")
            }
        }
        return removed
    }

    /// Total bytes held, for the storage row in settings.
    func totalBytes() -> Int64 {
        var total: Int64 = 0
        let keys: [URLResourceKey] = [.fileSizeKey, .isDirectoryKey]
        guard let walker = fileManager.enumerator(at: root, includingPropertiesForKeys: keys) else { return 0 }
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true { continue }
            total += Int64(values?.fileSize ?? 0)
        }
        return total
    }
}
