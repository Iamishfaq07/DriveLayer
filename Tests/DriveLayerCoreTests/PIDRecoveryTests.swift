import XCTest
@testable import DriveLayerCore

private actor RecoveringPIDTransport: OBDTransport {
    nonisolated let identifier = "recovery-test"
    nonisolated let displayName = "Recovery test"
    private var failing = true
    private(set) var requests = 0
    func connect() async throws {}
    func disconnect() async {}
    func recover() { failing = false }
    func send(_ command: String, timeout: TimeInterval) async throws -> String {
        requests += 1
        if failing { throw OBDError.timeout }
        return "41 0C 1C 20\r>"
    }
}

final class PIDRecoveryTests: XCTestCase {
    func testRepeatedTimeoutsCooldownAndRecoverWithoutNewSession() async throws {
        let clock = MutableDateProvider(Date(timeIntervalSince1970: 1_700_000_000))
        let transport = RecoveringPIDTransport()
        let session = OBDSession(transport: transport, dateProvider: clock)
        let pid = OBDPID.current(0x0C)
        for failure in 1...7 {
            do { _ = try await session.read(pid); XCTFail("Expected timeout") }
            catch { XCTAssertEqual(error as? OBDError, .timeout) }
            let blocked = await session.canPoll(pid)
            XCTAssertFalse(blocked)
            let before = await transport.requests
            _ = try? await session.read(pid)
            let after = await transport.requests
            XCTAssertEqual(after, before, "Cooldown must not use the bus")
            let retryDate = await session.retryDate(for: pid)
            let retry = try XCTUnwrap(retryDate)
            XCTAssertEqual(retry.timeIntervalSince(clock.now), min(60, pow(2, Double(failure))))
            clock.set(retry)
        }
        let unsupported = await session.unsupportedPIDs
        XCTAssertFalse(unsupported.contains(pid))
        await transport.recover()
        let reading = try await session.read(pid)
        XCTAssertEqual(reading.numericValue, 1800)
        let retry = await session.retryDate(for: pid)
        XCTAssertNil(retry)
        let canPoll = await session.canPoll(pid)
        XCTAssertTrue(canPoll)
    }
}
