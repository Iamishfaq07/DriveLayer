import XCTest
@testable import DriveLayerCore

/// Ask Harrier answers engine questions from the Hyperion assessment - the same object
/// the Hyperion screen and CarPlay read - so the copilot cannot describe an engine the
/// screen does not show. These tests pin two things: that the summary actually reaches
/// the snapshot through the real builder, and that the answers never say more than the
/// assessment does.
final class AskHarrierTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// A realistic assessment: two areas judged, four not yet.
    private func assessment(overall: SemanticStatus = .normal) -> HyperionAssessment {
        HyperionAssessment(
            overall: overall,
            sections: [
                HyperionSection(area: .thermal, status: .normal,
                                headline: "At operating temperature",
                                detail: "Coolant reached its working range 6 minutes in.",
                                comparison: "About a minute quicker than your usual warm-up.",
                                confidence: .medium, dataPoints: []),
                HyperionSection(area: .airAndTurbo, status: overall == .watch ? .watch : .normal,
                                headline: overall == .watch ? "Intake running warm" : "Intake tracking ambient",
                                detail: "Intake air is 12 °C above ambient.",
                                comparison: nil,
                                confidence: .low, dataPoints: []),
                .notAssessed(.fuelSystem, because: "This vehicle is not reporting a fuel system state DriveLayer recognises."),
                .notAssessed(.aftertreatment, because: "Readiness has not been read yet."),
                .notAssessed(.battery, because: "Voltage isn't being reported."),
                .notAssessed(.diagnostics, because: "DriveLayer hasn't been able to read the vehicle's self-test status.")
            ],
            summary: overall == .watch ? "Worth a look: air & turbo." : "No unusual Hyperion behaviour detected in what DriveLayer can read so far."
        )
    }

    private func snapshot(with assessment: HyperionAssessment?) -> VehicleContextSnapshot {
        var snapshot = VehicleContextSnapshot(generatedAt: now)
        snapshot.hyperion = assessment.map(CopilotContextBuilder.summarise)
        return snapshot
    }

    // MARK: - The summary reaches the snapshot

    /// Through the real builder, not by assignment: this is the wiring the brief asks for.
    func testHyperionSummaryReachesTheSnapshotThroughTheBuilder() throws {
        let vehicle = Vehicle(nickname: "Harrier",
                              profileID: VehicleProfileCatalog.harrier2026AdventureXPlusID)
        let context = InsightContext(now: now, vehicle: vehicle, isAdapterConnected: true)

        let snapshot = CopilotContextBuilder.build(from: context, health: nil, insights: [],
                                                   hyperion: assessment())

        let summary = try XCTUnwrap(snapshot.hyperion)
        XCTAssertEqual(summary.overall, "Normal")
        XCTAssertEqual(summary.areas.count, 6)
        XCTAssertEqual(summary.assessedCount, 2)
        XCTAssertFalse(summary.isSilent)
        XCTAssertEqual(summary.area(named: "Engine state")?.headline, "At operating temperature")
    }

    /// The summary carries judgements and never readings. `dataPoints` are dropped on
    /// purpose: no raw telemetry crosses into the conversation.
    func testSummaryCarriesNoDataPoints() {
        var judged = assessment()
        judged.sections[0].dataPoints = [.measured("Coolant", "92 °C")]

        let summary = CopilotContextBuilder.summarise(judged)

        XCTAssertFalse(String(describing: summary).contains("92"), "readings must not reach the copilot")
        XCTAssertTrue(String(describing: summary).contains("operating temperature"), "judgements must")
    }

    /// Without an assessment the snapshot has no Hyperion section at all - not an empty
    /// one that could be read as "everything normal".
    func testNoAssessmentMeansNoSummary() {
        let vehicle = Vehicle(nickname: "Harrier",
                              profileID: VehicleProfileCatalog.harrier2026AdventureXPlusID)
        let context = InsightContext(now: now, vehicle: vehicle, isAdapterConnected: false)
        let snapshot = CopilotContextBuilder.build(from: context, health: nil, insights: [])
        XCTAssertNil(snapshot.hyperion)
    }

    // MARK: - The answers say what the assessment says, and no more

    func testEngineAnswerNamesTheUnassessedAreasAsALimitation() throws {
        let answer = LocalCopilot.respond(to: "How's the engine?", snapshot: snapshot(with: assessment()))

        XCTAssertTrue(answer.wasUnderstood)
        XCTAssertTrue(answer.detailedText.lowercased().contains("operating temperature"))
        let limitation = try XCTUnwrap(answer.limitationNote)
        XCTAssertTrue(limitation.contains("fuel system"), "an unassessed area must be named, not omitted")
        XCTAssertTrue(limitation.contains("diagnostics"))
    }

    /// The comparison against this car's own baseline is an inference, and is labelled
    /// as one - it is the sentence most likely to be read as a diagnosis.
    func testBaselineComparisonIsLabelledAsAnInference() throws {
        let answer = LocalCopilot.respond(to: "Is the engine warmed up?", snapshot: snapshot(with: assessment()))

        let inference = try XCTUnwrap(answer.statements.first { $0.claim == .inference })
        XCTAssertTrue(inference.text.contains("quicker than your usual"))
        XCTAssertTrue(answer.statements.contains { $0.claim == .fact && $0.text.lowercased().contains("operating temperature") })
    }

    func testTurboQuestionAnswersFromTheAirAndTurboArea() {
        let answer = LocalCopilot.respond(to: "How's the turbo?", snapshot: snapshot(with: assessment(overall: .watch)))

        XCTAssertTrue(answer.detailedText.lowercased().contains("intake running warm"))
        XCTAssertNotNil(answer.limitationNote, "low confidence must be said, not hidden")
        XCTAssertFalse(answer.detailedText.lowercased().contains("failing"), "never a diagnosis")
    }

    /// An unassessed area is answered with the reason, not with silence or a guess.
    func testUnassessedAreaExplainsWhy() {
        let answer = LocalCopilot.respond(to: "How is the fuel system?", snapshot: snapshot(with: assessment()))

        XCTAssertTrue(answer.detailedText.contains("can't assess fuel system yet"))
        XCTAssertTrue(answer.detailedText.contains("not reporting a fuel system state"))
    }

    /// The failure this guards against was in the first draft of the answer: with no
    /// codes and no diagnostics area, it said "the warning light is off". Nobody had
    /// read the lamp. An absent area means unread, and the answer must say unread.
    func testFaultsAnswerNeverClaimsTheLampIsOffWithoutReadingIt() {
        var silent = VehicleContextSnapshot(generatedAt: now)
        silent.hyperion = nil
        silent.activeTroubleCodes = []

        let answer = LocalCopilot.respond(to: "Any faults?", snapshot: silent)

        XCTAssertFalse(answer.detailedText.lowercased().contains("light is off"))
        XCTAssertTrue(answer.detailedText.contains("haven't been able to check"))
    }

    func testFaultsAnswerListsStoredCodes() {
        var snapshot = snapshot(with: assessment())
        snapshot.activeTroubleCodes = ["P0420", "P0171"]

        let answer = LocalCopilot.respond(to: "Any faults?", snapshot: snapshot)

        XCTAssertTrue(answer.detailedText.contains("P0420"))
        XCTAssertTrue(answer.detailedText.contains("2 stored codes"))
    }

    /// Every example question must route to an intent. A suggestion chip that returns
    /// "I didn't understand" is a broken promise on the first screen.
    func testEveryExampleQuestionIsUnderstood() {
        for question in LocalCopilot.exampleQuestions {
            XCTAssertNotNil(LocalCopilot.bestIntent(for: question.lowercased()),
                            "\"\(question)\" is offered as an example but matches no intent")
        }
    }
}
