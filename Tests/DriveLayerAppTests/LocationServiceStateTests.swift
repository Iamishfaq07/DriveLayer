import XCTest
import CoreLocation

/// The state machine that decides whether DriveLayer is watching for a drive.
///
/// It had no tests at all, and the bug it was hiding was not subtle: a request made
/// before the driver answered the permission prompt was dropped on the floor, and the
/// grant that arrived seconds later had nothing to replay. Since the first request at
/// launch is `.idle`, that meant a driver who allowed location when first asked got no
/// automatic drive detection until the next launch — while Settings said "Active".
///
/// In a test bundle CoreLocation reports `.notDetermined` and never grants anything, so
/// these cover the half that is reachable: that intent is recorded, that nothing claims
/// to be running when it is not, and that stopping clears both.
@MainActor
final class LocationServiceStateTests: XCTestCase {

    /// `start(fidelity:)` is nonisolated and hops to the main actor, so give the hop a
    /// bounded chance to land rather than sleeping for a fixed period.
    private func settle(_ service: LocationService) async {
        for _ in 0..<100 where service.requestedFidelity == nil {
            await Task.yield()
        }
    }

    func testAFreshServiceIsNotTrackingAndWantsNothing() {
        let service = LocationService()
        XCTAssertNil(service.requestedFidelity)
        XCTAssertEqual(service.trackingState, .stopped)
        XCTAssertFalse(service.isTracking)
        XCTAssertFalse(service.isMonitoring)
    }

    func testARequestMadeWithoutPermissionIsStillRemembered() async {
        let service = LocationService()
        service.start(fidelity: .idle)
        await settle(service)

        // The whole point: the authorization guard may refuse to start anything, but it
        // must not lose the fact that starting was asked for.
        XCTAssertEqual(service.requestedFidelity, .idle,
                       "the request has to outlive the authorization guard")
    }

    func testAnUnauthorisedRequestDoesNotClaimToBeRunning() async {
        let service = LocationService()
        service.start(fidelity: .driving)
        await settle(service)

        XCTAssertEqual(service.requestedFidelity, .driving)
        // `.notDetermined` in a test bundle, so nothing can have started.
        XCTAssertEqual(service.authorization, .notDetermined)
        XCTAssertEqual(service.trackingState, .stopped)
        XCTAssertFalse(service.isMonitoring, "and the UI must not be told otherwise")
        XCTAssertEqual(service.fidelity, .idle, "no fidelity is in force")
    }

    func testTheLatestRequestIsTheOneRemembered() async {
        let service = LocationService()
        service.start(fidelity: .idle)
        await settle(service)
        service.start(fidelity: .active)
        for _ in 0..<100 where service.requestedFidelity != .active {
            await Task.yield()
        }
        XCTAssertEqual(service.requestedFidelity, .active)
    }

    func testStoppingClearsIntentAsWellAsTracking() async {
        let service = LocationService()
        service.start(fidelity: .driving)
        await settle(service)
        XCTAssertNotNil(service.requestedFidelity)

        service.stop()
        for _ in 0..<100 where service.requestedFidelity != nil {
            await Task.yield()
        }

        // Stopping is the app saying it no longer wants updates, which is a different
        // thing from iOS refusing to provide them -- so the intent goes too, and a later
        // permission change has nothing to replay.
        XCTAssertNil(service.requestedFidelity)
        XCTAssertEqual(service.trackingState, .stopped)
    }
}
