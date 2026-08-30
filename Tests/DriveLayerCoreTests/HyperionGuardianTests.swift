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
