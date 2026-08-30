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
    // MARK: - Permission granted is not the same as updates running

    func testAlwaysWithoutRunningUpdatesIsNotActive() {
        let status = AutomaticDetectionStatus.resolve(isEnabled: true,
                                                     authorization: .always,
                                                     isReceivingUpdates: false)
        XCTAssertEqual(status, .permittedButNotStarted)
        XCTAssertFalse(status.detectsInBackground,
                       "nothing is watching, so nothing will be detected")
        XCTAssertFalse(status.needsSettingsApp, "iOS has already granted it; this is ours to fix")
        XCTAssertNotNil(status.explanation, "and the driver is told rather than shown Active")
        XCTAssertEqual(status.summary, "Not running")
    }

    func testAlwaysWithRunningUpdatesIsStillActive() {
        XCTAssertEqual(AutomaticDetectionStatus.resolve(isEnabled: true,
                                                       authorization: .always,
                                                       isReceivingUpdates: true),
                       .active)
    }

    func testWhenInUseWithoutRunningUpdatesIsNotForegroundOnly() {
        // Foreground-only is a promise that it works while the app is open. If updates
        // are not running it does not, and saying so beats a softer half-truth.
        XCTAssertEqual(AutomaticDetectionStatus.resolve(isEnabled: true,
                                                       authorization: .whenInUse,
                                                       isReceivingUpdates: false),
                       .permittedButNotStarted)
    }

    func testARefusedPermissionStillReadsAsBlockedRatherThanNotRunning() {
        // Ordering matters: a denial is the driver-actionable case and must not be
        // masked by the newer one.
        for authorization in [LocationAuthorization.denied, .restricted] {
            let status = AutomaticDetectionStatus.resolve(isEnabled: true,
                                                          authorization: authorization,
                                                          isReceivingUpdates: false)
            XCTAssertEqual(status, .blocked(.locationPermissionDenied))
            XCTAssertTrue(status.needsSettingsApp)
        }
    }

    func testTheSwitchBeingOffOutranksEverything() {
        XCTAssertEqual(AutomaticDetectionStatus.resolve(isEnabled: false,
                                                       authorization: .always,
                                                       isReceivingUpdates: false),
                       .off)
    }
}
