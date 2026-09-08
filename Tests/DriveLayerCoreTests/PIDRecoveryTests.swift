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

private actor NoDataThenValueTransport: OBDTransport {
    nonisolated let identifier = "no-data-recovery"
    nonisolated let displayName = "NO DATA recovery"
    private var first = true
    func connect() async throws {}
    func disconnect() async {}
    func send(_ command: String, timeout: TimeInterval) async throws -> String {
        if first { first = false; throw OBDError.noData }
        return "41 0C 1C 20\r>"
    }
}

final class PIDRecoveryTests: XCTestCase {
    func testMode01NoDataCoolsDownThenRecoversInSameSession() async throws {
        let clock = MutableDateProvider(Date(timeIntervalSince1970: 1_700_000_000))
        let session = OBDSession(transport: NoDataThenValueTransport(), dateProvider: clock)
        let pid = OBDPID.current(0x0C)
        do { _ = try await session.read(pid); XCTFail("Expected NO DATA") }
        catch { XCTAssertEqual(error as? OBDError, .noData) }
        let unsupported = await session.unsupportedPIDs
        XCTAssertFalse(unsupported.contains(pid))
        let initiallyPollable = await session.canPoll(pid)
        XCTAssertFalse(initiallyPollable)
        let retryDate = await session.retryDate(for: pid)
        clock.set(try XCTUnwrap(retryDate))
        let reading = try await session.read(pid)
        XCTAssertEqual(reading.numericValue, 1800)
        let recovered = await session.canPoll(pid)
        XCTAssertTrue(recovered)
    }

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
