import XCTest
@testable import DriveLayerCore

final class OBDCapabilityDigestTests: XCTestCase {

    private let harrier = VehicleProfileCatalog.profile(id: VehicleProfileCatalog.harrier2026AdventureXPlusID)

    private func report(codes: Set<UInt8>,
                        stored: ModeSupport = .unknown,
                        notes: [String] = []) -> OBDCapabilityReport {
        OBDCapabilityReport(supportedCodes: codes,
                            storedDTCSupport: stored,
                            discoveredAt: Date(timeIntervalSince1970: 1_700_000_000),
                            notes: notes)
    }

    /// The bitmap-request codes are how a car is asked what it supports. Listing them
    /// as findings would pad every report with rows nobody can act on.
    func testSupportBitmapRequestsAreNotReportedAsParameters() {
        let found = OBDCapabilityDigest.findings(
            report: report(codes: Set(OBDPIDCatalog.supportedPIDRequestCodes).union([0x0C])),
            profile: harrier)
        let everyCode = (found.interpreted + found.reportedButNotInterpreted + found.expectedButAbsent)
            .map(\.code)
        for plumbing in OBDPIDCatalog.supportedPIDRequestCodes {
            XCTAssertFalse(everyCode.contains(plumbing), "\(plumbing) is plumbing, not a finding")
        }
        XCTAssertEqual(found.interpreted.map(\.code), [0x0C])
    }

    /// The point of the report: separating what the car offers from what DriveLayer
    /// can currently make of it.
    func testParametersTheCarOffersButDriveLayerCannotDecodeAreListedSeparately() {
        // 0x0C (engine RPM) is decoded; 0x83 (NOx sensor) is known by name only.
        let found = OBDCapabilityDigest.findings(report: report(codes: [0x0C, 0x83]), profile: harrier)
        XCTAssertEqual(found.interpreted.map(\.code), [0x0C])
        XCTAssertEqual(found.reportedButNotInterpreted.map(\.code), [0x83])
        XCTAssertTrue(found.reportedButNotInterpreted[0].name.contains("NOx"),
                      "an undecoded parameter should still be named, not shown as a bare number")
        XCTAssertFalse(found.reportedButNotInterpreted[0].isInterpreted)
    }

    /// A profile that predicts more than the car delivers is the thing a first drive
    /// is meant to catch, so it has to be visible rather than silently dropped.
    ///
    /// Built from a profile of its own rather than the catalog's: the reference
    /// Harrier deliberately predicts nothing (`expectedStandardPIDs: []`, because no
    /// PID list has been verified for that engine), so it cannot exercise this path.
    func testParametersTheProfileExpectedButTheCarDidNotReportAreShown() throws {
        var optimistic = try XCTUnwrap(harrier)
        optimistic.expectedStandardPIDs = [.current(0x0C), .current(0x0D), .current(0x05)]

        // The car answers only one of the three the profile predicted.
        let found = OBDCapabilityDigest.findings(report: report(codes: [0x0C]), profile: optimistic)
        XCTAssertEqual(found.interpreted.map(\.code), [0x0C])
        XCTAssertEqual(found.expectedButAbsent.map(\.code), [0x05, 0x0D])
        XCTAssertTrue(found.profileMadePredictions)
    }

    /// The reference profile predicts nothing, which is not the same as every
    /// prediction coming true — and both leave the list empty. Saying "the profile
    /// matched the car" for a comparison that never happened is exactly the kind of
    /// confident wrong sentence this app exists to avoid.
    func testAProfileThatPredictsNothingIsNotReportedAsAMatch() throws {
        let profile = try XCTUnwrap(harrier)
        XCTAssertTrue(profile.expectedStandardPIDs.isEmpty,
                      "the reference profile is expected to predict nothing; if that changed, this test should too")

        let found = OBDCapabilityDigest.findings(report: report(codes: [0x0C]), profile: profile)
        XCTAssertFalse(found.profileMadePredictions)
        XCTAssertTrue(found.expectedButAbsent.isEmpty)

        let text = OBDCapabilityDigest.text(report: report(codes: [0x0C]),
                                            profile: profile,
                                            capabilityLevel: .obdConnected,
                                            adapterDescription: "ELM327 v1.5",
                                            appVersion: "1.0 (1)",
                                            generatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertTrue(text.contains("nothing to compare against"))
        XCTAssertFalse(text.contains("every parameter the profile predicted was present"),
                       "a profile that predicted nothing must not be reported as having matched")
    }

    func testNothingIsExpectedWhenThereIsNoProfile() {
        let found = OBDCapabilityDigest.findings(report: report(codes: [0x0C]), profile: nil)
        XCTAssertTrue(found.expectedButAbsent.isEmpty)
        XCTAssertEqual(found.interpreted.map(\.code), [0x0C])
    }

    /// The whole reason this exists rather than sharing the data export: that one
    /// carries trips, coordinates and documents. This must carry none of it.
    func testTheReportCarriesNoLocationOrIdentifyingData() throws {
        let profile = try XCTUnwrap(harrier)
        let text = OBDCapabilityDigest.text(
            report: report(codes: [0x0C, 0x83], stored: .supported, notes: ["Block 0x40 timed out."]),
            profile: profile,
            capabilityLevel: .obdConnected,
            adapterDescription: "ELM327 v1.5",
            appVersion: "1.0 (1)",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000))

        for forbidden in ["latitude", "longitude", "VIN", "odometer", "trip", "document"] {
            XCTAssertFalse(text.lowercased().contains(forbidden.lowercased()),
                           "\(forbidden) must not appear in a shareable capability report")
        }
    }

    func testTheReportNamesWhatTheCarSaidAndWhatWasMadeOfIt() throws {
        let text = OBDCapabilityDigest.text(
            report: report(codes: [0x0C, 0x83], stored: .supported, notes: ["Block 0x40 timed out."]),
            profile: harrier,
            capabilityLevel: .obdConnected,
            adapterDescription: "ELM327 v1.5",
            appVersion: "1.0 (1)",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000))

        XCTAssertTrue(text.contains("ELM327 v1.5"))
        XCTAssertTrue(text.contains("Connected"), "the capability level should be named")
        XCTAssertTrue(text.contains("supported"), "stored DTC support should be stated")
        XCTAssertTrue(text.contains("Block 0x40 timed out."), "discovery notes are the useful part")
        XCTAssertTrue(text.contains("0C"))
        XCTAssertTrue(text.contains("83"))
        XCTAssertTrue(text.contains("2023-11-14"), "the timestamp should be stable and readable")
    }

    /// A driver with no adapter still gets a report, and it says so rather than
    /// implying a connection that never happened.
    func testAReportWithoutAnAdapterSaysSoRatherThanLookingEmpty() {
        let text = OBDCapabilityDigest.text(report: report(codes: []),
                                            profile: nil,
                                            capabilityLevel: .phoneOnly,
                                            adapterDescription: nil,
                                            appVersion: "1.0 (1)",
                                            generatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertTrue(text.contains("not recorded"))
        XCTAssertTrue(text.contains("No vehicle profile selected."))
        XCTAssertTrue(text.contains("None. If the adapter was connected, this is the finding."))
    }
}
