import XCTest
@testable import DriveLayerCore

final class DiagnosticSnapshotTests: XCTestCase {
    func testEmptyCodesAreNormalOnlyAfterAllModesSucceed() {
        let complete = DiagnosticSnapshot(storedStatus: .successful,
                                          pendingStatus: .successful,
                                          permanentStatus: .successful)
        XCTAssertTrue(complete.hasSuccessfulZeroCodeScan)
        XCTAssertEqual(complete.summary, "No diagnostic trouble codes found")

        let incomplete = DiagnosticSnapshot(storedStatus: .successful,
                                            pendingStatus: .unavailable,
                                            permanentStatus: .successful)
        XCTAssertFalse(incomplete.hasSuccessfulZeroCodeScan)
        XCTAssertEqual(incomplete.summary, "Diagnostics unavailable")
    }

    func testPartialScanWithCodeDoesNotClaimCompleteScan() {
        let code = DiagnosticTroubleCode(code: "P0300", system: .powertrain, status: .stored)
        let snapshot = DiagnosticSnapshot(storedCodes: [code],
                                          storedStatus: .successful,
                                          pendingStatus: .failed("timeout"),
                                          permanentStatus: .successful)
        XCTAssertEqual(snapshot.summary, "Diagnostic scan incomplete")
        XCTAssertEqual(snapshot.coverage, 2.0 / 3.0, accuracy: 0.001)
    }
}
