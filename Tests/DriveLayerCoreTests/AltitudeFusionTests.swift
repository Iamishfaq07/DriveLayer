import XCTest
@testable import DriveLayerCore

/// The old code re-anchored to GPS on every fix it liked, once per second, so its
/// output was GPS altitude with extra steps and the barometer contributed nothing to
/// the one number it was chosen for. These pin the behaviour that replaced it.
final class AltitudeFusionTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Before any reference exists

    func testRelativeAltitudeIsNotPresentedAsAbsolute() {
        var fusion = AltitudeFusion()
        fusion.update(relativeAltitude: 7)

        XCTAssertNil(fusion.absoluteAltitudeMetres,
                     "7 m since the app launched is not 7 m above sea level, and the "
                     + "caller must not be able to confuse the two")
        XCTAssertEqual(fusion.elevationChangeMetres, 7)
        XCTAssertFalse(fusion.hasAbsoluteReference)
        XCTAssertEqual(fusion.source, .barometricRelative)
    }

    func testFirstUsableFixAnchors() {
        var fusion = AltitudeFusion()
        fusion.update(relativeAltitude: 7)

        XCTAssertEqual(fusion.offer(gpsAltitude: 500, accuracyMetres: 8, now: now), .anchored)
        XCTAssertEqual(try XCTUnwrap(fusion.absoluteAltitudeMetres), 500, accuracy: 0.001)
        XCTAssertEqual(fusion.source, .fused)
        // The anchor is the height where relative read zero, i.e. 7 m below here.
        XCTAssertEqual(try XCTUnwrap(fusion.anchorMetres), 493, accuracy: 0.001)
    }

    func testInaccurateFixesAreIgnored() {
        var fusion = AltitudeFusion()
        XCTAssertEqual(fusion.offer(gpsAltitude: 500, accuracyMetres: 40, now: now), .ignored)
        XCTAssertFalse(fusion.hasAbsoluteReference)
    }

    func testFixWithoutAccuracyIsIgnored() {
        var fusion = AltitudeFusion()
        XCTAssertEqual(fusion.offer(gpsAltitude: 500, accuracyMetres: nil, now: now), .ignored)
        // CoreLocation reports a negative vertical accuracy when it has none, which
        // would otherwise sail through a "less than fifteen" check.
        XCTAssertEqual(fusion.offer(gpsAltitude: 500, accuracyMetres: -1, now: now), .ignored)
        XCTAssertFalse(fusion.hasAbsoluteReference)
    }

    func testFixWithoutAnAltitudeIsIgnored() {
        var fusion = AltitudeFusion()
        XCTAssertEqual(fusion.offer(gpsAltitude: nil, accuracyMetres: 5, now: now), .ignored)
    }

    // MARK: - The bug this exists to prevent

    /// The regression test named in the brief: repeated GPS readings must not keep
    /// hard-resetting the barometric anchor.
    func testRepeatedFixesDoNotHardResetTheAnchor() throws {
        var fusion = AltitudeFusion()
        fusion.update(relativeAltitude: 0)
        fusion.offer(gpsAltitude: 500, accuracyMetres: 8, now: now)
        let anchorAfterFirst = try XCTUnwrap(fusion.anchorMetres)

        // Sixty seconds of GPS noise around the truth, the barometer holding still.
        let noise: [Double] = [508, 494, 503, 497, 506, 492, 501, 499]
        for (index, altitude) in noise.enumerated() {
            let outcome = fusion.offer(gpsAltitude: altitude, accuracyMetres: 8,
                                       now: now.addingTimeInterval(Double(index + 1)))
            guard case .corrected = outcome else {
                return XCTFail("expected a small correction, got \(outcome)")
            }
        }

        let anchorAfterNoise = try XCTUnwrap(fusion.anchorMetres)
        XCTAssertEqual(anchorAfterNoise, anchorAfterFirst, accuracy: 2.0,
                       "eight noisy fixes should move the origin by metres, not tens of metres")
        XCTAssertEqual(fusion.correctionCount, noise.count)
    }

    /// The property the barometer was chosen for: a climb must read as the climb, not
    /// as the climb plus GPS noise.
    func testBarometricChangeSurvivesNoisyGPS() throws {
        var fusion = AltitudeFusion()
        fusion.offer(gpsAltitude: 500, accuracyMetres: 8, now: now)

        // Climb 40 m by the barometer while GPS reports nonsense within its accuracy.
        var reported: [Double] = []
        for step in 1...40 {
            fusion.update(relativeAltitude: Double(step))
            fusion.offer(gpsAltitude: 500 + Double(step) + (step % 2 == 0 ? 9 : -9),
                         accuracyMetres: 8,
                         now: now.addingTimeInterval(Double(step)))
            reported.append(try XCTUnwrap(fusion.absoluteAltitudeMetres))
        }

        // Monotonic, because the barometer was: no step may go backwards.
        for (previous, next) in zip(reported, reported.dropFirst()) {
            XCTAssertGreaterThan(next, previous,
                                 "a steady climb must not wobble because GPS did")
        }
        XCTAssertEqual(reported.last! - reported.first!, 39, accuracy: 3,
                       "and the total climb must still be about what the barometer measured")
    }

    // MARK: - Drift correction

    func testSteadyBiasIsCorrectedGraduallyRatherThanAtOnce() throws {
        var fusion = AltitudeFusion()
        fusion.offer(gpsAltitude: 500, accuracyMetres: 5, now: now)

        // The barometer now reads 30 m low, consistently: weather drift, not noise.
        for step in 1...200 {
            fusion.offer(gpsAltitude: 530, accuracyMetres: 5, now: now.addingTimeInterval(Double(step)))
        }

        let corrected = try XCTUnwrap(fusion.absoluteAltitudeMetres)
        XCTAssertEqual(corrected, 530, accuracy: 1.0,
                       "a persistent disagreement should be followed, eventually")
    }

    func testOneFixMovesTheAnswerOnlySlightly() throws {
        var fusion = AltitudeFusion()
        fusion.offer(gpsAltitude: 500, accuracyMetres: 5, now: now)

        let outcome = fusion.offer(gpsAltitude: 530, accuracyMetres: 5,
                                   now: now.addingTimeInterval(1))
        guard case let .corrected(byMetres) = outcome else {
            return XCTFail("expected a correction, got \(outcome)")
        }
        XCTAssertEqual(byMetres, 0.6, accuracy: 0.01, "2% of a 30 m residual")
        XCTAssertEqual(try XCTUnwrap(fusion.absoluteAltitudeMetres), 500.6, accuracy: 0.01)
    }

    func testStationaryCorrectionIsFasterThanDriving() throws {
        var driving = AltitudeFusion()
        driving.offer(gpsAltitude: 500, accuracyMetres: 5, now: now)
        driving.offer(gpsAltitude: 520, accuracyMetres: 5, isStationary: false, now: now)

        var parked = AltitudeFusion()
        parked.offer(gpsAltitude: 500, accuracyMetres: 5, now: now)
        parked.offer(gpsAltitude: 520, accuracyMetres: 5, isStationary: true, now: now)

        XCTAssertGreaterThan(try XCTUnwrap(parked.absoluteAltitudeMetres),
                             try XCTUnwrap(driving.absoluteAltitudeMetres),
                             "with no gradient to protect, there is no reason to creep")
    }

    // MARK: - Re-anchoring

    func testAnImpossibleDisagreementReAnchorsRatherThanCreeping() throws {
        var fusion = AltitudeFusion()
        fusion.offer(gpsAltitude: 500, accuracyMetres: 5, now: now)

        // Out of a long tunnel: the barometer is wrong by more than any plausible drift.
        let outcome = fusion.offer(gpsAltitude: 900, accuracyMetres: 6,
                                   now: now.addingTimeInterval(600))
        guard case let .reAnchored(residual) = outcome else {
            return XCTFail("expected a re-anchor, got \(outcome)")
        }
        XCTAssertEqual(residual, 400, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(fusion.absoluteAltitudeMetres), 900, accuracy: 0.001,
                       "creeping back at 2% a fix would have taken minutes")
        XCTAssertEqual(fusion.correctionCount, 0, "the correction history starts again")
    }

    func testDisagreementJustInsideTheThresholdStillOnlyCorrects() {
        var fusion = AltitudeFusion()
        fusion.offer(gpsAltitude: 500, accuracyMetres: 5, now: now)
        let outcome = fusion.offer(gpsAltitude: 570, accuracyMetres: 5, now: now)
        guard case .corrected = outcome else {
            return XCTFail("70 m is under the 75 m threshold, got \(outcome)")
        }
    }

    // MARK: - Samples and reset

    func testSampleReportsWhichSensorIsAnswering() {
        var fusion = AltitudeFusion()
        fusion.update(relativeAltitude: 12)

        let beforeAnchor = fusion.sample(at: now)
        XCTAssertEqual(beforeAnchor.source, .barometricRelative)
        XCTAssertEqual(beforeAnchor.altitudeMetres, 12, "which is a change, and labelled as one")

        fusion.offer(gpsAltitude: 300, accuracyMetres: 5, now: now)
        let afterAnchor = fusion.sample(at: now)
        XCTAssertEqual(afterAnchor.source, .fused)
        XCTAssertEqual(afterAnchor.altitudeMetres, 300, accuracy: 0.001)
        XCTAssertGreaterThan(afterAnchor.accuracyMetres, beforeAnchor.accuracyMetres,
                             "an anchored height cannot be better than the fix it is tied to")
    }

    func testForgettingTheAnchorKeepsBarometricContinuity() {
        var fusion = AltitudeFusion()
        fusion.update(relativeAltitude: 25)
        fusion.offer(gpsAltitude: 500, accuracyMetres: 5, now: now)

        fusion.forgetAnchor()

        XCTAssertNil(fusion.absoluteAltitudeMetres)
        XCTAssertEqual(fusion.elevationChangeMetres, 25, "the barometer has not moved")
        XCTAssertEqual(fusion.source, .barometricRelative)
    }
}
