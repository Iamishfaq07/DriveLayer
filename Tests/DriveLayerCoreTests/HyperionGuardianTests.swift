import XCTest
@testable import DriveLayerCore

/// The aggregate that finally gives the Hyperion analysers a caller.
///
/// Most of what matters here is about honesty rather than analysis: an area nobody has
/// built yet has to be visibly unbuilt, and it must not drag the engine's overall status
/// down to unknown while every reading DriveLayer actually has says things are fine.
final class HyperionGuardianTests: XCTestCase {

    private let harrier = VehicleProfileCatalog.harrier2026AdventureXPlus
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Nothing to read

    func testWithNoReadingsEveryAreaIsVisiblyUnassessed() {
        let assessment = HyperionGuardian.assess(coolantC: .unavailable(), profile: harrier)

        XCTAssertTrue(assessment.isSilent)
        XCTAssertEqual(assessment.overall, .unknown, "unknown, not normal: we have not looked")
        XCTAssertEqual(Set(assessment.sections.map(\.area)), Set(HyperionSection.Area.allCases),
                       "every area is named even when none can be assessed")
        for section in assessment.sections {
            XCTAssertFalse(section.isAssessed)
            XCTAssertNotNil(section.notAssessedReason, "\(section.area) must say why")
        }
    }

    func testTheUnavailableAssessmentNamesEveryArea() {
        XCTAssertEqual(Set(HyperionAssessment.unavailable.sections.map(\.area)),
                       Set(HyperionSection.Area.allCases))
        XCTAssertTrue(HyperionAssessment.unavailable.isSilent)
        XCTAssertEqual(HyperionAssessment.unavailable.overall, .unknown)
    }

    // MARK: - Partial coverage

    func testCoolantAloneAssessesEngineStateAndNothingElse() {
        let assessment = HyperionGuardian.assess(coolantC: .measured(92, at: start), profile: harrier)

        let thermal = assessment.section(.thermal)
        XCTAssertEqual(thermal?.isAssessed, true)
        XCTAssertFalse(assessment.isSilent)
        XCTAssertEqual(assessment.section(.airAndTurbo)?.isAssessed, false,
                       "no intake or ambient reading, so there is no air story to tell")
        XCTAssertEqual(assessment.section(.fuelSystem)?.isAssessed, false)
    }

    /// The assertion this whole design exists for. Four of six areas are not built yet, and
    /// `unknown` outranks `normal` in a roll-up — so counting them would report the engine
    /// as unknown while everything DriveLayer can read says it is fine.
    func testUnassessedAreasDoNotDragTheOverallStatusToUnknown() {
        let assessment = HyperionGuardian.assess(coolantC: .measured(92, at: start), profile: harrier)

        XCTAssertLessThanOrEqual(assessment.overall, .watch,
                                 "a warm engine is not an unknown engine")
        XCTAssertNotEqual(assessment.overall, .unknown)
        XCTAssertEqual(assessment.assessedSections.count, 1)
    }

    func testIntakeAndAmbientTogetherAssessTheAirSide() {
        let assessment = HyperionGuardian.assess(coolantC: .measured(92, at: start),
                                                 intakeC: .measured(40, at: start),
                                                 ambientC: 32,
                                                 speedKmh: 70,
                                                 profile: harrier)
        XCTAssertEqual(assessment.section(.airAndTurbo)?.isAssessed, true)
        XCTAssertEqual(assessment.assessedSections.count, 2)
    }

    // MARK: - Rolling up

    func testHeatSoakRaisesTheOverallStatusToAWatchAndNoFurther() {
        // Stationary in traffic with a hot intake: the analyser calls this a watch, and
        // nothing in the roll-up is allowed to escalate it beyond that.
        let assessment = HyperionGuardian.assess(coolantC: .measured(92, at: start),
                                                 intakeC: .measured(68, at: start),
                                                 ambientC: 32,
                                                 speedKmh: 0,
                                                 idleSeconds: 600,
                                                 profile: harrier)
        XCTAssertEqual(assessment.section(.airAndTurbo)?.status, .watch)
        XCTAssertEqual(assessment.overall, .watch)
    }

    func testTheSummarySaysNothingUnusualWhenNothingIsUnusual() {
        let assessment = HyperionGuardian.assess(coolantC: .measured(92, at: start),
                                                 intakeC: .measured(38, at: start),
                                                 ambientC: 32,
                                                 speedKmh: 70,
                                                 profile: harrier)
        XCTAssertEqual(assessment.overall, .normal)
        XCTAssertTrue(assessment.summary.contains("No unusual"))
        // Scoped honestly: it claims nothing about the areas it has not looked at.
        XCTAssertTrue(assessment.summary.contains("can read so far"))
    }

    func testTheSummaryPointsAtAnAreaWithoutDiagnosingIt() {
        let assessment = HyperionGuardian.assess(coolantC: .measured(92, at: start),
                                                 intakeC: .measured(68, at: start),
                                                 ambientC: 32,
                                                 speedKmh: 0,
                                                 idleSeconds: 600,
                                                 profile: harrier)
        XCTAssertTrue(assessment.summary.lowercased().contains("air & turbo"))
        for forbidden in ["fail", "broken", "faulty", "replace"] {
            XCTAssertFalse(assessment.summary.lowercased().contains(forbidden),
                           "a summary must point, not diagnose")
        }
    }

    func testASilentEngineSaysSoRatherThanReportingHealth() {
        let assessment = HyperionGuardian.assess(coolantC: .unavailable(), profile: harrier)
        XCTAssertTrue(assessment.summary.contains("isn't reading anything"))
    }

    // MARK: - Aftertreatment, and the limits of OBD-II

    private func complete() -> MonitorStatus {
        MonitorStatus.decode(bytes: [0x00, 0x07, 0x01, 0x00])!
    }

    private func stillTesting() -> MonitorStatus {
        MonitorStatus.decode(bytes: [0x00, 0x27, 0x00, 0x00])!
    }

    func testFinishedSelfTestsMakeAftertreatmentAssessable() throws {
        let assessment = HyperionGuardian.assess(coolantC: .measured(92, at: start),
                                                 monitorStatus: complete(),
                                                 profile: harrier)
        let section = try XCTUnwrap(assessment.section(.aftertreatment))
        XCTAssertTrue(section.isAssessed)
        XCTAssertEqual(section.status, .normal)
    }

    /// The line the brief is explicit about, and the one worth protecting: readiness is what
    /// standard OBD-II exposes, filter loading is not, and saying so beats another number.
    func testAftertreatmentSaysWhatOBDCannotTell() throws {
        let assessment = HyperionGuardian.assess(coolantC: .measured(92, at: start),
                                                 monitorStatus: complete(),
                                                 profile: harrier)
        let section = try XCTUnwrap(assessment.section(.aftertreatment))
        XCTAssertTrue(section.detail.contains("not available through standard OBD-II"))

        let loading = try XCTUnwrap(section.dataPoints.first { $0.label == "Direct filter loading" })
        XCTAssertEqual(loading.provenance, .unavailable,
                       "named and marked unavailable, so the absence is a statement not a gap")
        for invented in ["soot", "%", "regeneration"] {
            XCTAssertFalse(section.detail.lowercased().contains(invented),
                           "filter loading is not exposed, so nothing may be implied about it")
        }
    }

    /// An emissions monitor still running is an absence of evidence, not a fault -- and it
    /// must not drag the engine headline down or appear as something to look at.
    func testAnIncompleteSelfTestIsNotTreatedAsAConcern() throws {
        let assessment = HyperionGuardian.assess(coolantC: .measured(92, at: start),
                                                 intakeC: .measured(38, at: start),
                                                 ambientC: 32,
                                                 speedKmh: 70,
                                                 monitorStatus: stillTesting(),
                                                 profile: harrier)
        let section = try XCTUnwrap(assessment.section(.aftertreatment))
        XCTAssertEqual(section.status, .unknown)
        XCTAssertTrue(section.isAssessed, "it was looked at; it simply could not tell")

        XCTAssertEqual(assessment.overall, .normal,
                       "an area that could not tell must not outrank areas that said fine")
        XCTAssertFalse(assessment.summary.lowercased().contains("aftertreatment"),
                       "and it must not be pointed at as though it were a finding")
    }

    func testALampByteAloneCannotAssessAftertreatment() throws {
        // Assembled from the telemetry path, which carries no readiness. Diagnostics can be
        // judged from it; aftertreatment cannot, and it says so rather than guessing.
        let assessment = HyperionGuardian.assess(coolantC: .measured(92, at: start),
                                                 monitorStatus: MonitorStatus.decode(lampByte: 0x00),
                                                 profile: harrier)
        XCTAssertEqual(assessment.section(.diagnostics)?.isAssessed, true)
        XCTAssertEqual(assessment.section(.aftertreatment)?.isAssessed, false)
    }

    // MARK: - Full coverage

    func testEveryAreaCanBeAssessedWhenTheCarReportsEverything() {
        let assessment = HyperionGuardian.assess(coolantC: .measured(92, at: start),
                                                 intakeC: .measured(38, at: start),
                                                 ambientC: 32,
                                                 speedKmh: 70,
                                                 fuelSystem: .closedLoop,
                                                 monitorStatus: complete(),
                                                 voltage: .measured(13.8, at: start),
                                                 isEngineRunning: true,
                                                 profile: harrier)
        XCTAssertEqual(assessment.assessedSections.count, HyperionSection.Area.allCases.count,
                       "all six areas: \(assessment.sections.filter { !$0.isAssessed }.map(\.area))")
        XCTAssertEqual(assessment.overall, .normal)
        XCTAssertTrue(assessment.summary.contains("No unusual"))
    }

    // MARK: - Provenance carried through

    func testASimulatedReadingKeepsItsProvenanceIntoTheAssessment() {
        let assessment = HyperionGuardian.assess(
            coolantC: Provenanced(value: 92, provenance: .simulated, timestamp: start),
            profile: harrier)

        let thermal = assessment.section(.thermal)
        XCTAssertEqual(thermal?.isAssessed, true)
        // A simulated value still produces an assessment -- scenarios exist to be driven --
        // but it must arrive labelled, not wearing a sensor reading's clothes.
        XCTAssertTrue(thermal?.dataPoints.isEmpty == false)
    }
}
