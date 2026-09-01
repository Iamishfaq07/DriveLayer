import XCTest
@testable import DriveLayerCore

/// The point of this suite is narrow and worth stating, because it looks like a test
/// of a logging wrapper and is really a test of a build promise.
///
/// `TelemetryJournal` is Foundation-only product logic that the package compiles and
/// tests on any platform. It used to call `PrivacyLog.logger(.persistence).error(...)`,
/// and `logger(_:)` existed only inside `#if canImport(os)`. On macOS that compiles,
/// so the single macOS runner in CI reported green while the cross-platform build the
/// package advertises could not have worked. A test cannot observe a compile failure
/// on a platform it is not running on — so what is asserted here instead is the
/// property that keeps the failure from returning: the core logs through a
/// platform-independent API, and that API works without `os`.
final class PrivacyLogTests: XCTestCase {

    /// Captures records so tests can assert on them rather than reading the system log.
    private final class RecordingSink: PrivacyLogSink {
        struct Record: Equatable {
            let level: PrivacyLog.Level
            let category: PrivacyLog.Category
            let message: String
        }

        private let lock = NSLock()
        private var storage: [Record] = []

        func write(level: PrivacyLog.Level, category: PrivacyLog.Category, message: String) {
            lock.lock()
            storage.append(Record(level: level, category: category, message: message))
            lock.unlock()
        }

        var records: [Record] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    private var sink: RecordingSink!

    override func setUp() {
        super.setUp()
        sink = RecordingSink()
        PrivacyLog.setSink(sink)
    }

    override func tearDown() {
        PrivacyLog.resetSink()
        sink = nil
        super.tearDown()
    }

    // MARK: - The API exists and works without `os`

    /// Every level reaches the sink, on every platform. If this file compiles at all
    /// off-platform, the regression that motivated it cannot recur.
    func testEveryLevelReachesTheSink() {
        PrivacyLog.debug(.app, "debug message")
        PrivacyLog.info(.app, "info message")
        PrivacyLog.error(.app, "error message")
        PrivacyLog.fault(.app, "fault message")

        XCTAssertEqual(sink.records.map(\.level), [.debug, .info, .error, .fault])
        XCTAssertEqual(sink.records.map(\.message),
                       ["debug message", "info message", "error message", "fault message"])
    }

    /// The category travels with the record, since a persistence failure and a BLE
    /// failure are not read by the same person.
    func testCategoryIsCarried() {
        PrivacyLog.error(.persistence, "a persistence failure")
        PrivacyLog.error(.obd, "an adapter failure")

        XCTAssertEqual(sink.records.map(\.category), [.persistence, .obd])
    }

    // MARK: - The journal logs through that API

    /// Drives the real production failure path: an append into a location that cannot
    /// be written. What matters is not the wording but that the journal reports it
    /// through `PrivacyLog` at all — that call is the one that used to be `os`-only.
    func testJournalReportsAFailedAppendThroughPrivacyLog() throws {
        // A file where the journal expects a directory, so writing cannot succeed.
        let blocker = FileManager.default.temporaryDirectory
            .appendingPathComponent("dl-privacylog-\(UUID().uuidString)")
        try Data("not a directory".utf8).write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }

        let journal = TelemetryJournal(root: blocker)
        let sample = TelemetrySample(timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                                     values: [.engineRPM: 1_000])

        journal.appendChunk([sample], vehicleID: UUID(), tripID: UUID())

        XCTAssertTrue(sink.records.contains { $0.category == .persistence && $0.level == .error },
                      "A failed telemetry append should be reported through PrivacyLog.")
    }

    // MARK: - Redaction

    /// Coordinates are coarsened to ~1 km before they may be logged.
    func testCoarseCoordinatesDoNotRevealAPosition() {
        let coarse = PrivacyLog.coarse(latitude: 34.083656, longitude: 74.797371)

        XCTAssertFalse(coarse.contains("083656"))
        XCTAssertFalse(coarse.contains("797371"))
        XCTAssertTrue(coarse.contains("34.08"))
    }

    /// Identifiers keep their tail for correlation and lose everything else.
    func testRedactedIdentifierKeepsOnlyTheTail() {
        XCTAssertEqual(PrivacyLog.redactedIdentifier("ABCDEF123456"), "********3456")
        // Nothing short enough to be guessable survives at all.
        XCTAssertEqual(PrivacyLog.redactedIdentifier("123"), "****")
    }

    /// A document number is redacted even when written with spaces.
    func testRedactedDocumentNumberIgnoresSpacing() {
        XCTAssertEqual(PrivacyLog.redactedDocumentNumber("1234 5678 9012"), "********9012")
    }
}
