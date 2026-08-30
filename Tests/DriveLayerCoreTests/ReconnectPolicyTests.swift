import XCTest
@testable import DriveLayerCore

/// A dropped BLE link used to set `.failed(.connectionLost)` and stop, so a tunnel cost
/// live engine data for the rest of the drive. These pin the ladder that replaced it.
final class ReconnectPolicyTests: XCTestCase {

    func testLadderClimbsThenSettles() {
        let policy = ReconnectPolicy()
        XCTAssertEqual(policy.delay(forAttempt: 1), 1)
        XCTAssertEqual(policy.delay(forAttempt: 2), 2)
        XCTAssertEqual(policy.delay(forAttempt: 3), 5)
        XCTAssertEqual(policy.delay(forAttempt: 4), 10)
        XCTAssertEqual(policy.delay(forAttempt: 5), 30)
    }

    func testItKeepsTryingAtTheLongestDelayRatherThanGivingUp() {
        let policy = ReconnectPolicy()
        for attempt in 6...500 {
            XCTAssertEqual(policy.delay(forAttempt: attempt), 30,
                           "an adapter reappearing an hour into a drive is worth catching")
        }
    }

    func testTheFirstRetryIsImmediateEnoughForARadioGlitch() throws {
        let policy = ReconnectPolicy()
        let first = try XCTUnwrap(policy.delay(forAttempt: 1))
        XCTAssertLessThanOrEqual(first, 1,
                                 "a two-second dropout should not cost more than it has to")
    }

    func testBackoffNeverGoesBackwards() throws {
        let policy = ReconnectPolicy()
        var previous: TimeInterval = 0
        for attempt in 1...10 {
            let delay = try XCTUnwrap(policy.delay(forAttempt: attempt))
            XCTAssertGreaterThanOrEqual(delay, previous)
            previous = delay
        }
    }

    func testAnAttemptCapStopsTheLadder() {
        let policy = ReconnectPolicy(maximumAttempts: 3)
        XCTAssertNotNil(policy.delay(forAttempt: 3))
        XCTAssertNil(policy.delay(forAttempt: 4))
    }

    func testAttemptZeroIsNotAnAttempt() {
        XCTAssertNil(ReconnectPolicy().delay(forAttempt: 0))
        XCTAssertNil(ReconnectPolicy().delay(forAttempt: -1))
    }

    func testEmptyLadderStillReturnsSomethingUsable() {
        let policy = ReconnectPolicy(delaysSeconds: [])
        XCTAssertEqual(policy.settledDelaySeconds, 30)
        XCTAssertEqual(policy.delay(forAttempt: 1), 30, "never a zero-delay busy loop")
    }

    func testStatusSaysTheDriveIsStillRecording() {
        let policy = ReconnectPolicy()
        XCTAssertTrue(policy.statusDescription(attempt: 1).contains("Reconnecting"))
        // The reassurance matters: losing the adapter is not losing the drive, and a
        // driver who thinks it is will stop and fiddle with it.
        XCTAssertTrue(policy.statusDescription(attempt: 3).contains("still recording"))
    }

    func testExhaustedStatusTellsTheDriverWhatToDo() {
        let policy = ReconnectPolicy(maximumAttempts: 2)
        let message = policy.statusDescription(attempt: 3)
        XCTAssertTrue(message.contains("Settings"))
        XCTAssertFalse(message.contains("Reconnecting"), "it is not reconnecting any more")
    }
}
