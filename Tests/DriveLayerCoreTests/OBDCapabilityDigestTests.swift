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
    func testParametersTheProfileExpectedButTheCarDidNotReportAreShown() throws {
        let profile = try XCTUnwrap(harrier)
        let expected = Set(profile.expectedStandardPIDs.filter { $0.mode == .currentData }
            .compactMap(\.code))
            .subtracting(Set(OBDPIDCatalog.supportedPIDRequestCodes))
        XCTAssertFalse(expected.isEmpty, "the reference profile should predict some parameters")

        // A car that reports nothing at all: every prediction is a miss.
        let found = OBDCapabilityDigest.findings(report: report(codes: []), profile: profile)
        XCTAssertEqual(Set(found.expectedButAbsent.map(\.code)), expected)
        XCTAssertTrue(found.interpreted.isEmpty)
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
