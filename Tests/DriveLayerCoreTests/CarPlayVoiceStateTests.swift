import XCTest
@testable import DriveLayerCore

final class CarPlayVoiceStateTests: XCTestCase {
    func testVoiceStatesHaveStableUniqueIdentifiersAndDisplayTitles() {
        XCTAssertEqual(CarPlayVoiceState.allCases.map(\.rawValue), ["listening", "understanding", "answering"])
        XCTAssertEqual(Set(CarPlayVoiceState.allCases.map(\.rawValue)).count, 3)
        XCTAssertTrue(CarPlayVoiceState.allCases.allSatisfy { !($0.titleVariants.first ?? "").isEmpty })
    }
}
