import XCTest
@testable import DriveLayerCore

/// Whether a telemetry journal on disk should be kept or collected.
///
/// Of the three cases, the third — a journal whose drive is not in the database — was
/// handled nowhere, so orphans accumulated for the life of the install. These cover the
/// decision itself; the enumeration and deletion around it live in the app layer.
final class JournalReconciliationTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let grace: TimeInterval = 48 * 3_600

    private func outcome(hasTripRow: Bool, writtenAgo: TimeInterval?) -> JournalReconciliation.Outcome {
        JournalReconciliation.outcome(hasTripRow: hasTripRow,
                                      lastWrite: writtenAgo.map { now.addingTimeInterval(-$0) },
                                      now: now,
                                      grace: grace)
    }

    // MARK: - A drive exists

    func testAJournalBelongingToAKnownDriveIsAlwaysKept() {
        // However old. The drive is in the database, so this is not an orphan and age is
        // irrelevant — retention is a separate policy with its own rules.
        XCTAssertEqual(outcome(hasTripRow: true, writtenAgo: 0), .keep)
        XCTAssertEqual(outcome(hasTripRow: true, writtenAgo: 10 * 365 * 24 * 3_600), .keep)
        XCTAssertEqual(outcome(hasTripRow: true, writtenAgo: nil), .keep)
    }

    // MARK: - No drive exists

    func testAnOldJournalWithNoDriveIsDiscarded() {
        XCTAssertEqual(outcome(hasTripRow: false, writtenAgo: 72 * 3_600), .discard)
    }

    /// The safety property that matters most. A journal being written right now belongs to
    /// a drive in progress, whose row may not be saved yet — deleting it would destroy the
    /// drive being recorded.
    func testARecentJournalIsKeptEvenWithNoDrive() {
        XCTAssertEqual(outcome(hasTripRow: false, writtenAgo: 0), .keep)
        XCTAssertEqual(outcome(hasTripRow: false, writtenAgo: 60), .keep)
        XCTAssertEqual(outcome(hasTripRow: false, writtenAgo: 47 * 3_600), .keep)
    }

    func testTheGraceBoundaryFallsTowardsKeeping() {
        // Exactly at the boundary is kept. Where a boundary has to fall one way, it falls
        // towards not deleting data.
        XCTAssertEqual(outcome(hasTripRow: false, writtenAgo: grace), .keep)
        XCTAssertEqual(outcome(hasTripRow: false, writtenAgo: grace + 1), .discard)
    }

    func testAJournalThatCannotBeDatedIsKept() {
        // Undateable means unjudgeable. The cost of keeping is an empty directory; the cost
        // of the opposite mistake is telemetry that cannot come back.
        XCTAssertEqual(outcome(hasTripRow: false, writtenAgo: nil), .keep)
    }

    func testAZeroGraceStillKeepsAJournalBelongingToADrive() {
        XCTAssertEqual(JournalReconciliation.outcome(hasTripRow: true,
                                                     lastWrite: now,
                                                     now: now,
                                                     grace: 0),
                       .keep)
    }
}
