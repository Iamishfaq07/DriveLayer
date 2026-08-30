import XCTest
@testable import DriveLayerCore

/// A transport that answers from a table the test can rewrite mid-session.
///
/// Needed because the bug being pinned here is about *time*: the same command has to
/// answer one way at connect and another way later, and the session must ask again.
private final class ScriptedTransport: OBDTransport, @unchecked Sendable {

    let identifier = "scripted-adapter"
    let displayName = "Scripted adapter"

    private let lock = NSLock()
    private var replies: [String: String]
    private var log: [String] = []

    init(replies: [String: String]) {
        self.replies = replies
    }

    func connect() async throws {}
    func disconnect() async {}

    func send(_ command: String, timeout: TimeInterval) async throws -> String {
        lock.lock()
        defer { lock.unlock() }
        log.append(command)
        return replies[command] ?? "NO DATA\r\r>"
    }

    /// Changes what a command answers, standing in for a fault appearing while driving.
    func set(_ command: String, to reply: String) {
        lock.lock()
        replies[command] = reply
        lock.unlock()
    }

    var requests: [String] {
        lock.lock()
        defer { lock.unlock() }
        return log
    }

    func requestCount(of command: String) -> Int {
        requests.filter { $0 == command }.count
    }
}

private func hexReply(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02X", $0) }.joined(separator: " ") + "\r\r>"
}

/// A car that reports a handful of parameters and, at first, no fault codes.
private func healthyCarReplies() -> [String: String] {
    let bitmap = OBDSupportBitmap.encode(base: 0x00, codes: [0x01, 0x04, 0x05, 0x0C, 0x0D])
    return [
        "ATZ": "ELM327 v1.5\r\r>",
        "ATE0": "OK\r\r>",
        "ATL0": "OK\r\r>",
        "ATH0": "OK\r\r>",
        "ATS1": "OK\r\r>",
        "ATAT1": "OK\r\r>",
        "ATSP0": "OK\r\r>",
        "ATDPN": "A6\r\r>",
        "0100": hexReply([0x41, 0x00] + bitmap)
        // Everything else, including modes 03, 07 and 0A, falls through to NO DATA -
        // which is exactly what a car with nothing wrong with it answers.
    ]
}

final class DTCCapabilityRegressionTests: XCTestCase {

    /// The scenario from the brief, end to end.
    ///
    /// A healthy car answers mode 03 with NO DATA at connect. That used to be recorded
    /// as `.unknown` and then read as "unsupported" in two independent places, so a
    /// fault appearing later was never read - the app went blind to faults *because*
    /// nothing was wrong when it connected.
    func testFaultAppearingAfterAHealthyConnectIsStillFound() async throws {
        let clock = MutableDateProvider(Date(timeIntervalSince1970: 1_700_000_000))
        let transport = ScriptedTransport(replies: healthyCarReplies())
        let session = OBDSession(transport: transport, dateProvider: clock)

        // 1 and 2: connect, and mode 03 answers NO DATA during discovery.
        try await session.start()
        // Hoisted out of the assertion: XCTAssert takes an autoclosure, which is not
        // an async context, so awaiting an actor property inside one does not compile.
        let discovered = await session.capabilities
        let capabilities = try XCTUnwrap(discovered)
        XCTAssertEqual(capabilities.storedDTCSupport, .unknown,
                       "NO DATA on mode 03 is ambiguous and must stay ambiguous")

        // 3: the session carries on, and reading codes finds none.
        let firstRead = await session.readDiagnosticCodes()
        XCTAssertTrue(firstRead.codes.isEmpty)
        XCTAssertEqual(transport.requestCount(of: "03"), 2,
                       "once during discovery, once for this read")

        // 4: a misfire code appears while driving.
        transport.set("03", to: hexReply([0x43, 0x01, 0x03, 0x01]))

        // 5: DriveLayer reads it.
        let secondRead = await session.readDiagnosticCodes()
        XCTAssertEqual(secondRead.codes.map(\.code), ["P0301"],
                       "the whole point: the mode must be asked again")
        XCTAssertEqual(transport.requestCount(of: "03"), 3,
                       "a third request actually reached the adapter")

        // And now it is known to work, rather than merely not ruled out.
        let relearned = await session.capabilities
        let learned = try XCTUnwrap(relearned)
        XCTAssertEqual(learned.storedDTCSupport, .supported)
    }

    func testRepeatedNoDataNeverGivesUpOnTheMode() async throws {
        let clock = MutableDateProvider(Date(timeIntervalSince1970: 1_700_000_000))
        let transport = ScriptedTransport(replies: healthyCarReplies())
        let session = OBDSession(transport: transport, dateProvider: clock)
        try await session.start()

        for _ in 0..<8 {
            _ = await session.readDiagnosticCodes()
        }

        XCTAssertEqual(transport.requestCount(of: "03"), 9,
                       "a healthy car answers NO DATA every time and must still be asked")
        let current = await session.capabilities
        let capabilities = try XCTUnwrap(current)
        XCTAssertEqual(capabilities.storedDTCSupport, .unknown)
        let canReport = await session.canReportDiagnostics
        XCTAssertTrue(canReport)
    }

    /// The other half of the fix: a *definite* refusal is remembered, so this does not
    /// turn into asking a car that genuinely cannot answer, forever.
    func testDefiniteRefusalIsRememberedAndStopsTheAsking() async throws {
        let clock = MutableDateProvider(Date(timeIntervalSince1970: 1_700_000_000))
        var replies = healthyCarReplies()
        replies["03"] = "?\r\r>"
        let transport = ScriptedTransport(replies: replies)
        let session = OBDSession(transport: transport, dateProvider: clock)
        try await session.start()

        _ = await session.readDiagnosticCodes()
        let refused = await session.capabilities
        let after = try XCTUnwrap(refused)
        XCTAssertEqual(after.storedDTCSupport, .unsupported,
                       "an unrecognised-command reply is not ambiguous the way NO DATA is")

        let countBefore = transport.requestCount(of: "03")
        _ = await session.readDiagnosticCodes()
        XCTAssertEqual(transport.requestCount(of: "03"), countBefore,
                       "no point asking a mode the adapter has definitely refused")
    }

    /// No regression on current data: the mode 01 support bitmap is authoritative, so a
    /// PID the ECU did not list must still be rejected locally rather than polled at 1 Hz.
    func testUnlistedCurrentDataPIDIsStillRejectedLocally() async throws {
        let clock = MutableDateProvider(Date(timeIntervalSince1970: 1_700_000_000))
        let transport = ScriptedTransport(replies: healthyCarReplies())
        let session = OBDSession(transport: transport, dateProvider: clock)
        try await session.start()

        // 0x0F (intake air temperature) was not in the advertised bitmap.
        do {
            _ = try await session.request(.current(0x0F))
            XCTFail("an unlisted PID should be refused without a round trip")
        } catch let error as OBDError {
            guard case .pidNotSupported = error else {
                return XCTFail("expected pidNotSupported, got \(error)")
            }
        }
        XCTAssertEqual(transport.requestCount(of: "010F"), 0,
                       "nothing should have reached the adapter")
    }
}

final class ModeSupportSemanticsTests: XCTestCase {

    func testOnlyDefiniteUnsupportedStopsAnAttempt() {
        XCTAssertTrue(ModeSupport.supported.canAttempt)
        XCTAssertTrue(ModeSupport.unknown.canAttempt, "unknown is a reason to ask, not to give up")
        XCTAssertFalse(ModeSupport.unsupported.canAttempt)
    }

    func testSupportsAndCanAttemptDifferExactlyOnUnknown() {
        let report = OBDCapabilityReport(supportedCodes: [0x0C], storedDTCSupport: .unknown)
        let mode03 = OBDPID(mode: .storedDTCs)
        XCTAssertFalse(report.supports(mode03), "unknown is not a promise that it works")
        XCTAssertTrue(report.canAttempt(mode03), "but it is a reason to try")
    }

    func testUnsupportedModeIsNeitherSupportedNorAttemptable() {
        let report = OBDCapabilityReport(supportedCodes: [0x0C], storedDTCSupport: .unsupported)
        let mode03 = OBDPID(mode: .storedDTCs)
        XCTAssertFalse(report.supports(mode03))
        XCTAssertFalse(report.canAttempt(mode03))
    }

    func testDiagnosticsAreReportableWhileAnyModeMightAnswer() {
        XCTAssertTrue(OBDCapabilityReport(supportedCodes: [0x0C]).canReportDiagnostics,
                      "all three modes default to unknown, so diagnostics are not ruled out")
        let refused = OBDCapabilityReport(supportedCodes: [0x0C],
                                         storedDTCSupport: .unsupported,
                                         pendingDTCSupport: .unsupported,
                                         permanentDTCSupport: .unsupported)
        XCTAssertFalse(refused.canReportDiagnostics,
                       "this is the case that must read as 'unavailable', never as 'no faults'")
    }

    func testModeNineIsAttemptableRatherThanHardCodedOff() {
        let report = OBDCapabilityReport(supportedCodes: [0x0C])
        XCTAssertTrue(report.canAttempt(OBDPID(mode: .vehicleInformation)),
                      "VIN and calibration ID were unreachable because this returned false")
    }

    func testOnlyFaultModesCountAsDiagnostic() {
        XCTAssertTrue(OBDMode.storedDTCs.isDiagnostic)
        XCTAssertTrue(OBDMode.pendingDTCs.isDiagnostic)
        XCTAssertTrue(OBDMode.permanentDTCs.isDiagnostic)
        XCTAssertFalse(OBDMode.currentData.isDiagnostic)
        XCTAssertFalse(OBDMode.freezeFrame.isDiagnostic)
        XCTAssertFalse(OBDMode.vehicleInformation.isDiagnostic)
    }
}
