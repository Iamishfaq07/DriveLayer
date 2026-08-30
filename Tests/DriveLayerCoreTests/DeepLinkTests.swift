import XCTest
@testable import DriveLayerCore

final class DeepLinkTests: XCTestCase {

    func testEveryLinkRoundTripsThroughItsURL() {
        for link in DeepLink.allCases {
            XCTAssertEqual(DeepLink(url: link.url), link, "\(link.rawValue) did not survive its own URL")
        }
    }

    func testHostAndPathFormsAreBothAccepted() throws {
        let host = try XCTUnwrap(URL(string: "drivelayer://maintenance"))
        let path = try XCTUnwrap(URL(string: "drivelayer:///maintenance"))
        XCTAssertEqual(DeepLink(url: host), .maintenance)
        XCTAssertEqual(DeepLink(url: path), .maintenance)
    }

    func testSchemeIsCaseInsensitive() throws {
        let url = try XCTUnwrap(URL(string: "DriveLayer://Fuel"))
        XCTAssertEqual(DeepLink(url: url), .fuel)
    }

    /// A link DriveLayer does not recognise opens nothing. Falling back to a default
    /// screen would mean a mistyped link silently takes the driver somewhere.
    func testUnknownDestinationIsRejected() throws {
        let url = try XCTUnwrap(URL(string: "drivelayer://tune-engine"))
        XCTAssertNil(DeepLink(url: url))
    }

    func testForeignSchemesAreRejected() throws {
        let https = try XCTUnwrap(URL(string: "https://drivelayer.app/maintenance"))
        let other = try XCTUnwrap(URL(string: "someotherapp://maintenance"))
        XCTAssertNil(DeepLink(url: https))
        XCTAssertNil(DeepLink(url: other))
    }

    func testBareSchemeIsRejected() throws {
        let url = try XCTUnwrap(URL(string: "drivelayer://"))
        XCTAssertNil(DeepLink(url: url))
    }
}
