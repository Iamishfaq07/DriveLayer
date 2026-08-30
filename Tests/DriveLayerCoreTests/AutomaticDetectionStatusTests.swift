import XCTest
@testable import DriveLayerCore

/// The switch used to be the whole story: flipping it set a boolean and asked iOS for
/// nothing, so it could sit in the on position while the permission it needs had been
/// refused. These pin the rule that the reported state is a function of the setting
/// *and* the authorisation, never the setting alone.
final class AutomaticDetectionStatusTests: XCTestCase {

    private func status(_ isEnabled: Bool,
                       _ authorization: LocationAuthorization) -> AutomaticDetectionStatus {
        AutomaticDetectionStatus.resolve(isEnabled: isEnabled, authorization: authorization)
    }

    func testDisabledIsOffWhateverIOSHasGranted() {
        for authorization in LocationAuthorization.allCases {
            XCTAssertEqual(status(false, authorization), .off,
                           "the driver has not asked for it, so nothing else matters")
        }
    }

    func testOnlyAlwaysAuthorisationCountsAsActive() {
        XCTAssertEqual(status(true, .always), .active)
        XCTAssertTrue(status(true, .always).detectsInBackground)

        for authorization in LocationAuthorization.allCases where authorization != .always {
            XCTAssertFalse(status(true, authorization).detectsInBackground,
                           "\(authorization) cannot detect a drive that starts with the app closed")
        }
    }

    func testWhenInUseIsReportedAsForegroundOnlyRatherThanAsWorking() {
        let resolved = status(true, .whenInUse)
        XCTAssertEqual(resolved, .foregroundOnly)
        XCTAssertEqual(resolved.summary, "Only while DriveLayer is open")
        XCTAssertNotNil(resolved.explanation,
                        "the switch says on and the behaviour is partial, so it needs saying")
        XCTAssertFalse(resolved.needsSettingsApp,
                       "nothing is broken; there is a better choice available, not an error")
    }

    func testDeniedAndRestrictedBothBlockAndSendTheDriverToSettings() {
        for authorization in [LocationAuthorization.denied, .restricted] {
            let resolved = status(true, authorization)
            XCTAssertEqual(resolved, .blocked(.locationPermissionDenied))
            XCTAssertTrue(resolved.needsSettingsApp)
            XCTAssertEqual(resolved.summary, "Needs location permission",
                           "never 'on' when iOS is refusing")
        }
    }

    func testNotDeterminedIsWaitingRatherThanBlocked() {
        let resolved = status(true, .notDetermined)
        XCTAssertEqual(resolved, .awaitingPermission)
        XCTAssertFalse(resolved.needsSettingsApp,
                       "iOS has not refused - it has not been asked, and the app can still ask")
    }

    func testOnlyTheHonestStatesAreSilent() {
        // Off and active are the two cases where the switch and reality agree.
        XCTAssertNil(status(false, .always).explanation)
        XCTAssertNil(status(true, .always).explanation)
        // Every other case owes the driver an explanation.
        XCTAssertNotNil(status(true, .notDetermined).explanation)
        XCTAssertNotNil(status(true, .whenInUse).explanation)
        XCTAssertNotNil(status(true, .denied).explanation)
        XCTAssertNotNil(status(true, .restricted).explanation)
    }

    func testSummaryNeverClaimsMoreThanIsTrue() {
        for authorization in LocationAuthorization.allCases where authorization != .always {
            XCTAssertNotEqual(status(true, authorization).summary, "Active")
        }
    }
}
