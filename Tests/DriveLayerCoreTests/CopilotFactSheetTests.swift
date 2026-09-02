import XCTest
@testable import DriveLayerCore

private let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)

private let facts = """
Estimated range: 326 km
Fuel level: 58 percent
Usual resting battery voltage: 12.40 volts
Active trouble codes: none
"""

/// The guard is the only thing standing between a language model and this product's
/// central promise, so it is tested from the direction of an attack: what does a
/// plausible-sounding wrong answer look like, and does the guard actually stop it?
final class AnswerGuardTests: XCTestCase {

    func testAnswerRepeatingGivenNumbersIsVerified() {
        XCTAssertTrue(AnswerGuard.isVerified(answer: "You have about 326 km of range left.", against: facts))
    }

    func testAnswerWithNoNumbersIsVerified() {
        XCTAssertTrue(AnswerGuard.isVerified(answer: "Your car looks healthy right now.", against: facts))
    }

    /// 326 rounded to 300 is exactly the plausible-sounding fabrication that must never
    /// reach a driver as though it were measured. This is the case the guard exists for.
    func testRoundedNumberIsRejected() {
        XCTAssertFalse(AnswerGuard.isVerified(answer: "You have roughly 300 km left.", against: facts))
    }

    func testInventedReadingIsRejected() {
        XCTAssertFalse(AnswerGuard.isVerified(answer: "Your coolant is at 92 degrees.", against: facts))
    }

    /// 326 km at 58 percent does not license a full-tank figure: that is a derived
    /// reading DriveLayer never claimed and cannot stand behind.
    func testArithmeticOverTheFactsIsRejected() {
        XCTAssertFalse(AnswerGuard.isVerified(answer: "That is about 562 km on a full tank.", against: facts))
    }

    func testFormattingDifferenceIsNotFabrication() {
        XCTAssertTrue(AnswerGuard.isVerified(answer: "Your usual resting voltage is 12.4 volts.", against: facts))
    }

    func testNumberFromTheQuestionIsAllowedBackInTheAnswer() {
        XCTAssertTrue(AnswerGuard.isVerified(answer: "No, 11 volts would be low.",
                                             against: facts,
                                             question: "is 11 volts low?"))
        // ...but only because they asked. Unprompted, the same answer is rejected.
        XCTAssertFalse(AnswerGuard.isVerified(answer: "No, 11 volts would be low.", against: facts))
    }

    func testSentenceEndingFullStopIsNotPartOfTheNumber() {
        XCTAssertTrue(AnswerGuard.isVerified(answer: "Range is 326.", against: facts))
    }

    func testVerdictNamesTheNumbersItCouldNotVerify() {
        let verdict = AnswerGuard.check(answer: "Range is 300 and coolant is 92.", against: facts)
        XCTAssertEqual(verdict, .unverifiedNumbers(["300", "92"]))
    }

    func testNumbersAreExtractedFromOrdinaryProse() {
        let found = AnswerGuard.numbers(in: "12.4 volts, 326 km, and -3 degrees.")
        XCTAssertEqual(found.map(\.text), ["12.4", "326", "-3"])
    }
}

final class CopilotFactSheetTests: XCTestCase {

    /// A model shown "Range: unknown" answers around it; a model shown nothing about
    /// range has nothing to work with and says so, which is the honest answer.
    func testAbsentReadingIsOmittedRatherThanDescribedAsUnknown() {
        let snapshot = VehicleContextSnapshot(generatedAt: referenceDate)
        let text = CopilotFactSheet.text(from: snapshot)
        XCTAssertFalse(text.contains("Estimated range"))
        XCTAssertFalse(text.lowercased().contains("unknown"))
    }

    func testPresentReadingsAppearWithTheirValues() {
        var snapshot = VehicleContextSnapshot(generatedAt: referenceDate)
        snapshot.fuel = VehicleContextSnapshot.FuelSummary(levelPercent: 58,
                                                           estimatedRangeKm: 326,
                                                           economyKmPerLitre: 12.8,
                                                           economySource: "measured full-to-full")
        let text = CopilotFactSheet.text(from: snapshot)
        XCTAssertTrue(text.contains("326"))
        XCTAssertTrue(text.contains("58"))
    }

    /// If this ever fails, the number formatting in the sheet has drifted from what the
    /// guard can parse — and every model answer would be rejected as fabricated.
    func testFactSheetVerifiesItsOwnNumbers() {
        var snapshot = VehicleContextSnapshot(generatedAt: referenceDate)
        snapshot.fuel = VehicleContextSnapshot.FuelSummary(levelPercent: 58,
                                                           estimatedRangeKm: 326,
                                                           economyKmPerLitre: 12.8,
                                                           economySource: "measured")
        let sheet = CopilotFactSheet.text(from: snapshot)
        XCTAssertTrue(AnswerGuard.isVerified(answer: "Range is 326 km and the tank is 58 percent.", against: sheet))
    }

    func testTroubleCodesAreStatedAsNoneRatherThanLeftOut() {
        let snapshot = VehicleContextSnapshot(generatedAt: referenceDate)
        XCTAssertTrue(CopilotFactSheet.text(from: snapshot).contains("Active trouble codes: none"))
    }
}
