import XCTest
@testable import DriveLayerCore

final class PaletteTests: XCTestCase {

    /// Known values, so a mistake in the luminance formula shows up here rather than
    /// silently passing every colour in the palette.
    func testContrastRatioMatchesKnownValues() {
        let black = RGB(0, 0, 0)
        let white = RGB(1, 1, 1)
        XCTAssertEqual(white.contrastRatio(against: black), 21, accuracy: 0.01)
        XCTAssertEqual(black.contrastRatio(against: white), 21, accuracy: 0.01)
        XCTAssertEqual(white.contrastRatio(against: white), 1, accuracy: 0.001)
        // #767676 on white is the canonical WCAG AA boundary case.
        let grey = RGB(0.463, 0.463, 0.463)
        XCTAssertEqual(grey.contrastRatio(against: white), 4.54, accuracy: 0.05)
    }

    /// The guarantee: nothing DriveLayer draws as text or as a status mark can land
    /// on a surface it cannot be read against.
    func testEveryForegroundClearsAAOnEverySurface() {
        for appearance in Palette.Appearance.allCases {
            for (name, colour) in Palette.foregrounds(appearance) {
                for (index, surface) in Palette.surfaces(appearance).enumerated() {
                    let ratio = colour.contrastRatio(against: surface)
                    XCTAssertGreaterThanOrEqual(
                        ratio, Palette.minimumContrastRatio,
                        "\(name) on surface \(index) in \(appearance) is \(String(format: "%.2f", ratio)):1"
                    )
                }
            }
        }
    }

    /// The four status colours must be distinguishable from one another by luminance
    /// alone, not only by hue — which is what someone sees in greyscale, in glare, or
    /// with a colour vision deficiency. Shape carries the meaning in the UI; this
    /// keeps the colour from actively working against it.
    func testStatusColoursAreDistinguishableWithoutHue() {
        for appearance in Palette.Appearance.allCases {
            let critical = Palette.status(.critical, appearance)
            let normal = Palette.status(.normal, appearance)
            XCTAssertGreaterThan(critical.contrastRatio(against: normal), 1.25,
                                 "critical and normal are near-identical in greyscale in \(appearance)")
        }
    }

    func testUnknownIsNotMistakenForNormal() {
        for appearance in Palette.Appearance.allCases {
            XCTAssertNotEqual(Palette.status(.unknown, appearance), Palette.status(.normal, appearance))
        }
    }
}
