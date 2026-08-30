import XCTest
@testable import DriveLayerCore

/// Covers the cases the old design could not survive: the app being terminated
/// mid-drive, a half-written chunk, the same flush arriving twice, and a failed
/// compaction. Telemetry used to live in an array until the drive ended, so every one
/// of these lost the whole drive.
final class TelemetryJournalTests: XCTestCase {

    private var root: URL!
    private var journal: TelemetryJournal!
    private let vehicleID = UUID()
    private let tripID = UUID()
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dlts-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        journal = TelemetryJournal(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// `count` samples one second apart, starting `offset` seconds in.
    private func samples(count: Int, offset: Int = 0) -> [TelemetrySample] {
        (0..<count).map { index in
            TelemetrySample(timestamp: start.addingTimeInterval(Double(offset + index)),
                            values: [.engineRPM: Double(1_000 + index)])
        }
    }

    // MARK: - Termination and recovery

    /// The brief's scenario: chunks written, app terminates, relaunch, telemetry recovered.
    func testChunksSurviveTerminationAndAreRecovered() throws {
        journal.appendChunk(samples(count: 20, offset: 0), vehicleID: vehicleID, tripID: tripID)
        journal.appendChunk(samples(count: 20, offset: 20), vehicleID: vehicleID, tripID: tripID)
        journal.appendChunk(samples(count: 20, offset: 40), vehicleID: vehicleID, tripID: tripID)

        // No finalise: this is iOS terminating the app part-way through a drive.
        // A fresh journal on the same directory stands in for the next launch.
        let afterRelaunch = TelemetryJournal(root: root)
        let recovered = afterRelaunch.journalledSamples(vehicleID: vehicleID, tripID: tripID)

        XCTAssertEqual(recovered.count, 60, "all three chunks, none of them lost")
        XCTAssertEqual(recovered.first?.timestamp, start)
        XCTAssertEqual(recovered.last?.timestamp, start.addingTimeInterval(59))
        XCTAssertEqual(afterRelaunch.interruptedTrips().map(\.tripID), [tripID],
                       "and the drive is discoverable without knowing its id")
    }

    func testInterruptedTripCarriesBothIdentifiers() throws {
        journal.appendChunk(samples(count: 5), vehicleID: vehicleID, tripID: tripID)
        let found = try XCTUnwrap(journal.interruptedTrips().first)
        XCTAssertEqual(found.vehicleID, vehicleID)
        XCTAssertEqual(found.tripID, tripID)
    }

    func testCompactedDrivesAreNotReportedAsInterrupted() {
        journal.appendChunk(samples(count: 5), vehicleID: vehicleID, tripID: tripID)
        journal.finalise(vehicleID: vehicleID, tripID: tripID)
        XCTAssertTrue(journal.interruptedTrips().isEmpty)
    }

    // MARK: - Age

    /// Reconciliation uses this to tell a journal that outlived its process from one being
    /// written right now. Getting it wrong deletes the drive in progress.
    func testAJournalReportsWhenItWasLastWritten() {
        XCTAssertNil(journal.journalLastWrite(vehicleID: vehicleID, tripID: tripID),
                     "nothing written yet, so there is nothing to date")

        journal.appendChunk(samples(count: 5), vehicleID: vehicleID, tripID: tripID)
        let written = journal.journalLastWrite(vehicleID: vehicleID, tripID: tripID)
        XCTAssertNotNil(written)
        // Wall-clock, not the sample timestamps: the question is when the file was touched,
        // not what period the telemetry covers.
        XCTAssertLessThan(abs(Date().timeIntervalSince(written ?? .distantPast)), 60)
    }

    func testAnUnknownJournalHasNoWriteDate() {
        XCTAssertNil(journal.journalLastWrite(vehicleID: UUID(), tripID: UUID()))
    }

    // MARK: - Reporting failure

    /// The coordinator now clears its buffer only when this returns true, so the return
    /// value has to mean something. It used to be discarded across a queue hop.
    func testAppendReportsSuccess() {
        XCTAssertTrue(journal.appendChunk(samples(count: 5), vehicleID: vehicleID, tripID: tripID))
    }

    func testAppendReportsFailureRatherThanPretendingItWrote() throws {
        // A journal rooted at a path that cannot hold a directory: the file below stands
        // where the journal tree would have to go.
        let blocked = root.appendingPathComponent("blocked", isDirectory: false)
        try Data("not a directory".utf8).write(to: blocked)

        let refusing = TelemetryJournal(root: blocked)
        XCTAssertFalse(refusing.appendChunk(samples(count: 5), vehicleID: vehicleID, tripID: tripID),
                       "a write that did not happen must not report success")
    }

    func testAnEmptyFlushIsNotReportedAsAWrite() {
        XCTAssertFalse(journal.appendChunk([], vehicleID: vehicleID, tripID: tripID))
    }

    // MARK: - Chunk naming

    /// Names used to come from the file *count*, so a gap in the sequence made the next
    /// append reuse a name that was already taken -- and because the write is atomic it
    /// replaced a chunk nobody had read yet.
    func testAGapInTheSequenceDoesNotOverwriteAnExistingChunk() throws {
        journal.appendChunk(samples(count: 10, offset: 0), vehicleID: vehicleID, tripID: tripID)
        journal.appendChunk(samples(count: 10, offset: 10), vehicleID: vehicleID, tripID: tripID)
        journal.appendChunk(samples(count: 10, offset: 20), vehicleID: vehicleID, tripID: tripID)

        // Remove the middle chunk. That leaves chunk-000001 and chunk-000003, a count of
        // two, and a count-based name would therefore produce chunk-000003 a second time.
        let directory = journal.journalURL(vehicleID: vehicleID, tripID: tripID)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("chunk-000002.dlts"))

        journal.appendChunk(samples(count: 10, offset: 30), vehicleID: vehicleID, tripID: tripID)

        let recovered = journal.journalledSamples(vehicleID: vehicleID, tripID: tripID)
        XCTAssertEqual(recovered.count, 30, "the two survivors plus the chunk just written")
        XCTAssertTrue(recovered.contains { $0.timestamp == start.addingTimeInterval(20) },
                      "the chunk a count-based name would have destroyed is still readable")
        XCTAssertEqual(recovered.last?.timestamp, start.addingTimeInterval(39),
                       "and the new samples landed somewhere of their own")
    }

    func testChunkSequenceReadsOnlyChunkFilenames() {
        XCTAssertEqual(TelemetryJournal.chunkSequence(of: "chunk-000007.dlts"), 7)
        XCTAssertNil(TelemetryJournal.chunkSequence(of: "drive.dlts"), "the compacted file is not a chunk")
        XCTAssertNil(TelemetryJournal.chunkSequence(of: "chunk-.dlts"))
        XCTAssertNil(TelemetryJournal.chunkSequence(of: "chunk-00zz01.dlts"))
    }

    // MARK: - Corruption

    func testCorruptChunkIsSkippedRatherThanLosingTheDrive() throws {
        journal.appendChunk(samples(count: 20, offset: 0), vehicleID: vehicleID, tripID: tripID)
        journal.appendChunk(samples(count: 20, offset: 40), vehicleID: vehicleID, tripID: tripID)

        // A chunk truncated by the app dying half way through writing it.
        let directory = journal.journalURL(vehicleID: vehicleID, tripID: tripID)
        try Data([0x00, 0x01, 0x02]).write(to: directory.appendingPathComponent("chunk-000003.dlts"))

        let recovered = journal.journalledSamples(vehicleID: vehicleID, tripID: tripID)
        XCTAssertEqual(recovered.count, 40,
                       "the two readable chunks survive; only the broken one is lost")
    }

    func testNonTelemetryFilesInTheJournalAreIgnored() throws {
        journal.appendChunk(samples(count: 10), vehicleID: vehicleID, tripID: tripID)
        let directory = journal.journalURL(vehicleID: vehicleID, tripID: tripID)
        try Data("not telemetry".utf8).write(to: directory.appendingPathComponent("notes.txt"))
        XCTAssertEqual(journal.journalledSamples(vehicleID: vehicleID, tripID: tripID).count, 10)
    }

    // MARK: - Duplicate flushes

    func testDuplicateFlushDoesNotDoubleCountTheDrive() {
        let batch = samples(count: 30)
        journal.appendChunk(batch, vehicleID: vehicleID, tripID: tripID)
        // The same samples again: a checkpoint that flushed but failed to clear its
        // buffer, or a retried write.
        journal.appendChunk(batch, vehicleID: vehicleID, tripID: tripID)

        XCTAssertEqual(journal.journalledSamples(vehicleID: vehicleID, tripID: tripID).count, 30,
                       "a drive is not more accurate for counting the same second twice")
    }

    func testTrailingSamplesAlreadyOnDiskAreNotDuplicatedOnFinalise() {
        let batch = samples(count: 30)
        journal.appendChunk(batch, vehicleID: vehicleID, tripID: tripID)
        journal.finalise(vehicleID: vehicleID, tripID: tripID, appending: batch)
        XCTAssertEqual(journal.samples(vehicleID: vehicleID, tripID: tripID).count, 30)
    }

    func testEmptyFlushWritesNothing() {
        XCTAssertFalse(journal.appendChunk([], vehicleID: vehicleID, tripID: tripID))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: journal.journalURL(vehicleID: vehicleID, tripID: tripID).path))
    }

    // MARK: - Compaction

    func testFinaliseCompactsAndThenRemovesTheChunks() {
        journal.appendChunk(samples(count: 20, offset: 0), vehicleID: vehicleID, tripID: tripID)
        journal.appendChunk(samples(count: 20, offset: 20), vehicleID: vehicleID, tripID: tripID)

        XCTAssertTrue(journal.finalise(vehicleID: vehicleID, tripID: tripID, appending: samples(count: 5, offset: 40)))

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: journal.compactedURL(vehicleID: vehicleID, tripID: tripID).path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: journal.journalURL(vehicleID: vehicleID, tripID: tripID).path),
                       "chunks go only once the compacted file exists")
        XCTAssertEqual(journal.samples(vehicleID: vehicleID, tripID: tripID).count, 45)
    }

    /// The ordering guarantee that makes the whole design safe: if compaction cannot be
    /// written, the chunks must still be there afterwards.
    func testFailedCompactionKeepsTheChunksForRecovery() {
        journal.appendChunk(samples(count: 20), vehicleID: vehicleID, tripID: tripID)

        // A directory where the compacted file needs to go, so writing the file fails.
        let blocker = journal.compactedURL(vehicleID: vehicleID, tripID: tripID)
        try? FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)

        XCTAssertFalse(journal.finalise(vehicleID: vehicleID, tripID: tripID),
                       "the write could not succeed, and finalise must say so")
        XCTAssertEqual(journal.journalledSamples(vehicleID: vehicleID, tripID: tripID).count, 20,
                       "the source must not be destroyed before the copy exists")
    }

    func testFinaliseWithNothingRecordedJustCleansUp() {
        XCTAssertTrue(journal.finalise(vehicleID: vehicleID, tripID: tripID))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: journal.compactedURL(vehicleID: vehicleID, tripID: tripID).path),
                       "an empty drive should not leave an empty file behind")
    }

    // MARK: - Reading

    func testSamplesFallBackToChunksWhileTheDriveIsStillGoing() {
        journal.appendChunk(samples(count: 12), vehicleID: vehicleID, tripID: tripID)
        XCTAssertEqual(journal.samples(vehicleID: vehicleID, tripID: tripID).count, 12,
                       "a drive in progress has no compacted file yet, and must still be readable")
    }

    func testSamplesPreferTheCompactedFile() {
        journal.appendChunk(samples(count: 12), vehicleID: vehicleID, tripID: tripID)
        journal.finalise(vehicleID: vehicleID, tripID: tripID)
        XCTAssertEqual(journal.samples(vehicleID: vehicleID, tripID: tripID).count, 12)
    }

    func testUnknownDriveReadsAsEmptyRatherThanFailing() {
        XCTAssertTrue(journal.samples(vehicleID: UUID(), tripID: UUID()).isEmpty)
    }

    // MARK: - Deletion

    func testDiscardRemovesChunksButLeavesTheCompactedFile() {
        journal.appendChunk(samples(count: 10), vehicleID: vehicleID, tripID: tripID)
        journal.finalise(vehicleID: vehicleID, tripID: tripID)
        journal.appendChunk(samples(count: 5, offset: 100), vehicleID: vehicleID, tripID: tripID)

        journal.discard(vehicleID: vehicleID, tripID: tripID)

        XCTAssertEqual(journal.samples(vehicleID: vehicleID, tripID: tripID).count, 10)
    }

    func testDeleteRemovesBoth() {
        journal.appendChunk(samples(count: 10), vehicleID: vehicleID, tripID: tripID)
        journal.finalise(vehicleID: vehicleID, tripID: tripID)
        journal.appendChunk(samples(count: 5, offset: 100), vehicleID: vehicleID, tripID: tripID)

        journal.delete(vehicleID: vehicleID, tripID: tripID)

        XCTAssertTrue(journal.samples(vehicleID: vehicleID, tripID: tripID).isEmpty)
    }

    func testDeleteAllForVehicleTakesCompactedAndLiveChunks() {
        let otherVehicle = UUID()
        let secondTrip = UUID()
        journal.appendChunk(samples(count: 10), vehicleID: vehicleID, tripID: tripID)
        journal.finalise(vehicleID: vehicleID, tripID: tripID)
        journal.appendChunk(samples(count: 10), vehicleID: vehicleID, tripID: secondTrip)
        journal.appendChunk(samples(count: 10), vehicleID: otherVehicle, tripID: UUID())

        journal.deleteAll(vehicleID: vehicleID)

        XCTAssertTrue(journal.samples(vehicleID: vehicleID, tripID: tripID).isEmpty)
        XCTAssertTrue(journal.samples(vehicleID: vehicleID, tripID: secondTrip).isEmpty,
                      "a drive still being written is still this vehicle's data")
        XCTAssertEqual(journal.interruptedTrips().count, 1, "the other vehicle is untouched")
    }

    func testDeleteEverythingEmptiesTheDirectoryWithoutRemovingIt() {
        journal.appendChunk(samples(count: 10), vehicleID: vehicleID, tripID: tripID)
        journal.finalise(vehicleID: vehicleID, tripID: tripID)
        journal.appendChunk(samples(count: 10), vehicleID: vehicleID, tripID: UUID())

        journal.deleteEverything()

        XCTAssertTrue(journal.interruptedTrips().isEmpty)
        XCTAssertTrue(journal.samples(vehicleID: vehicleID, tripID: tripID).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path),
                      "callers hold a resolved URL to this directory; removing it would "
                      + "leave them writing into nowhere")

        // And it is still usable afterwards.
        journal.appendChunk(samples(count: 3), vehicleID: vehicleID, tripID: tripID)
        XCTAssertEqual(journal.samples(vehicleID: vehicleID, tripID: tripID).count, 3)
    }

    // MARK: - Retention

    func testRetentionDeletesExpiredRawTelemetry() throws {
        let oldTrip = UUID()
        journal.appendChunk(samples(count: 10), vehicleID: vehicleID, tripID: oldTrip)
        journal.finalise(vehicleID: vehicleID, tripID: oldTrip)
        let recentTrip = UUID()
        journal.appendChunk(samples(count: 10), vehicleID: vehicleID, tripID: recentTrip)
        journal.finalise(vehicleID: vehicleID, tripID: recentTrip)

        // Age the first drive's file by a year.
        let aged = Date().addingTimeInterval(-365 * 24 * 3_600)
        try FileManager.default.setAttributes(
            [.modificationDate: aged],
            ofItemAtPath: journal.compactedURL(vehicleID: vehicleID, tripID: oldTrip).path)

        let cutoff = Date().addingTimeInterval(-180 * 24 * 3_600)
        XCTAssertEqual(journal.deleteCompacted(olderThan: cutoff), 1)

        XCTAssertTrue(journal.samples(vehicleID: vehicleID, tripID: oldTrip).isEmpty,
                      "this is what 'keep engine history for 180 days' has to mean")
        XCTAssertEqual(journal.samples(vehicleID: vehicleID, tripID: recentTrip).count, 10,
                       "and it must not take anything inside the window")
    }

    func testRetentionLeavesADriveStillBeingRecorded() throws {
        journal.appendChunk(samples(count: 10), vehicleID: vehicleID, tripID: tripID)
        let aged = Date().addingTimeInterval(-365 * 24 * 3_600)
        let chunk = journal.journalURL(vehicleID: vehicleID, tripID: tripID)
            .appendingPathComponent("chunk-000001.dlts")
        try FileManager.default.setAttributes([.modificationDate: aged], ofItemAtPath: chunk.path)

        XCTAssertEqual(journal.deleteCompacted(olderThan: Date()), 0)
        XCTAssertEqual(journal.journalledSamples(vehicleID: vehicleID, tripID: tripID).count, 10,
                       "an uncompacted drive is not history yet, whatever its file dates say")
    }

    // MARK: - Identifier parsing

    func testIdentifierParsingRoundTrips() throws {
        let vehicle = UUID()
        let trip = UUID()
        let parsed = try XCTUnwrap(
            TelemetryJournal.parseIdentifiers("\(vehicle.uuidString)-\(trip.uuidString)"))
        XCTAssertEqual(parsed.vehicleID, vehicle)
        XCTAssertEqual(parsed.tripID, trip)
    }

    func testIdentifierParsingRejectsAnythingElse() {
        XCTAssertNil(TelemetryJournal.parseIdentifiers("journal"))
        XCTAssertNil(TelemetryJournal.parseIdentifiers(UUID().uuidString))
        XCTAssertNil(TelemetryJournal.parseIdentifiers(""))
        XCTAssertNil(TelemetryJournal.parseIdentifiers(String(repeating: "a", count: 73)))
    }

    // MARK: - Storage accounting

    func testTotalBytesCountsChunksAsWellAsCompactedFiles() {
        XCTAssertEqual(journal.totalBytes(), 0)
        journal.appendChunk(samples(count: 50), vehicleID: vehicleID, tripID: tripID)
        let withChunks = journal.totalBytes()
        XCTAssertGreaterThan(withChunks, 0, "a drive in progress is using disk and should say so")
        journal.finalise(vehicleID: vehicleID, tripID: tripID)
        XCTAssertGreaterThan(journal.totalBytes(), 0)
    }
}
