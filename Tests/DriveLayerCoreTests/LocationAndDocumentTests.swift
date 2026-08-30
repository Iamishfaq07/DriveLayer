import XCTest
@testable import DriveLayerCore

private let base = Date(timeIntervalSince1970: 1_700_000_000)

final class GeoTests: XCTestCase {

    private func fix(_ latitude: Double, _ longitude: Double,
                     accuracy: Double = 8, at seconds: Double, altitude: Double? = nil) -> GeoPoint {
        GeoPoint(latitude: latitude, longitude: longitude, altitudeMetres: altitude,
                 horizontalAccuracyMetres: accuracy, verticalAccuracyMetres: 6,
                 speedMetresPerSecond: 20, courseDegrees: 0,
                 timestamp: base.addingTimeInterval(seconds))
    }

    func testDistanceMatchesAKnownSeparation() {
        let metres = Geo.distance(from: fix(12.90, 77.60, at: 0), to: fix(12.91, 77.60, at: 10))
        XCTAssertEqual(metres, 1_112, accuracy: 5)
    }

    func testBearing() {
        XCTAssertEqual(Geo.bearing(from: fix(12.90, 77.60, at: 0), to: fix(12.91, 77.60, at: 1)), 0, accuracy: 0.5)
        XCTAssertEqual(Geo.bearing(from: fix(12.90, 77.60, at: 0), to: fix(12.90, 77.61, at: 1)), 90, accuracy: 0.5)
    }

    func testPathDistanceSkipsInaccurateFixes() {
        let points = [fix(12.90, 77.60, at: 0),
                      fix(12.95, 77.60, accuracy: 400, at: 10),
                      fix(12.91, 77.60, at: 20)]
        XCTAssertEqual(Geo.pathDistance(points), 1_112, accuracy: 5)
    }

    func testPathDistanceRejectsImpossibleJumps() {
        let points = [fix(12.90, 77.60, at: 0),
                      fix(15.60, 77.60, at: 2),
                      fix(12.9001, 77.60, at: 4)]
        XCTAssertLessThan(Geo.pathDistance(points), 100, "a 300 km jump in two seconds is not travel")
    }

    func testUnknownSpeedAndCourseAreNilNotMinusOne() {
        let point = GeoPoint(latitude: 12.9, longitude: 77.6,
                             horizontalAccuracyMetres: 10,
                             speedMetresPerSecond: -1, courseDegrees: -1, timestamp: base)
        XCTAssertNil(point.speedMetresPerSecond)
        XCTAssertNil(point.courseDegrees)
    }

    func testFixWithoutAccuracyIsNotUsedForRouting() {
        let point = GeoPoint(latitude: 12.9, longitude: 77.6, timestamp: base)
        XCTAssertFalse(point.isUsableForRouting)
    }
}

final class GradientTests: XCTestCase {

    private func climbCalculator(risePerStep: Double,
                                 steps: Int,
                                 accuracy: Double = 6,
                                 noise: [Double] = []) -> GradientCalculator {
        var calculator = GradientCalculator()
        var altitude = 300.0
        for step in 0..<steps {
            let point = GeoPoint(latitude: 12.90 + Double(step) * 0.001, longitude: 77.60,
                                 altitudeMetres: nil,
                                 horizontalAccuracyMetres: 8, verticalAccuracyMetres: accuracy,
                                 speedMetresPerSecond: 15, courseDegrees: 0,
                                 timestamp: base.addingTimeInterval(Double(step) * 8))
            let jitter = noise.isEmpty ? 0 : noise[step % noise.count]
            calculator.add(point: point,
                           altitude: AltitudeSample(altitudeMetres: altitude + jitter,
                                                    accuracyMetres: accuracy,
                                                    source: .fused,
                                                    timestamp: point.timestamp))
            altitude += risePerStep
        }
        return calculator
    }

    func testReportsNothingBeforeEnoughTravel() {
        XCTAssertNil(climbCalculator(risePerStep: 5, steps: 2).current)
    }

    func testMeasuresASteadyClimb() throws {
        // Steps are about 111 m apart, rising 5 m each: a 4.5% climb.
        let estimate = try XCTUnwrap(climbCalculator(risePerStep: 5, steps: 10).current)
        XCTAssertEqual(estimate.percent, 4.5, accuracy: 0.4)
        XCTAssertTrue(estimate.isClimb)
        XCTAssertGreaterThan(estimate.confidence, 0.5)
        XCTAssertTrue(estimate.shortDescription.contains("climb"))
    }

    func testMeasuresADescent() throws {
        let estimate = try XCTUnwrap(climbCalculator(risePerStep: -7, steps: 10).current)
        XCTAssertTrue(estimate.isDescent)
        XCTAssertLessThan(estimate.percent, 0)
    }

    func testNoisyFlatGroundIsNotReportedAsAClimb() throws {
        let estimate = try XCTUnwrap(climbCalculator(risePerStep: 0, steps: 12,
                                                     accuracy: 12,
                                                     noise: [1.5, -2.0, 0.5, -1.0, 2.0]).current)
        XCTAssertFalse(estimate.isClimb)
        XCTAssertLessThan(estimate.confidence, 0.5, "GPS drift must not be announced as terrain")
    }

    func testResetClearsHistory() {
        var calculator = climbCalculator(risePerStep: 5, steps: 10)
        calculator.reset()
        XCTAssertNil(calculator.current)
    }
}

final class ElevationAccumulatorTests: XCTestCase {

    func testHysteresisIgnoresSmallWobbles() {
        var accumulator = ElevationAccumulator(thresholdMetres: 4)
        for altitude in [300.0, 302, 305, 301, 310] {
            accumulator.add(altitudeMetres: altitude)
        }
        XCTAssertEqual(accumulator.gainMetres, 14, accuracy: 0.001)
        XCTAssertEqual(accumulator.lossMetres, 4, accuracy: 0.001)
        XCTAssertEqual(accumulator.netMetres, 10, accuracy: 0.001)
    }

    func testPureNoiseAccumulatesNothing() {
        var accumulator = ElevationAccumulator(thresholdMetres: 4)
        for step in 0..<200 {
            accumulator.add(altitudeMetres: 300 + (step % 2 == 0 ? 1.5 : -1.5))
        }
        XCTAssertEqual(accumulator.gainMetres, 0, accuracy: 0.001)
        XCTAssertEqual(accumulator.lossMetres, 0, accuracy: 0.001)
    }
}

final class TerrainAnalyserTests: XCTestCase {

    private func profile(flatPoints: Int, climbPoints: Int, risePerStep: Double) -> [ElevationPoint] {
        var points: [ElevationPoint] = []
        var altitude = 300.0
        for index in 0..<(flatPoints + climbPoints) {
            points.append(ElevationPoint(distanceMetres: Double(index) * 250, altitudeMetres: altitude))
            if index >= flatPoints - 1 { altitude += risePerStep }
        }
        return points
    }

    func testFindsASustainedClimb() throws {
        let features = TerrainAnalyser.features(in: profile(flatPoints: 8, climbPoints: 20, risePerStep: 13.75))
        let climb = try XCTUnwrap(features.first)
        XCTAssertEqual(climb.kind, .climb)
        XCTAssertEqual(climb.averageGradientPercent, 5.5, accuracy: 0.2)
        XCTAssertEqual(climb.lengthMetres, 5_000, accuracy: 300)
        XCTAssertTrue(climb.detail().contains("km"))
    }

    func testIgnoresShortUndulations() {
        var points: [ElevationPoint] = []
        for index in 0..<40 {
            points.append(ElevationPoint(distanceMetres: Double(index) * 250,
                                         altitudeMetres: 300 + sin(Double(index) * 1.5) * 6))
        }
        XCTAssertTrue(TerrainAnalyser.features(in: points).isEmpty,
                      "a driver does not need to hear about every bridge")
    }

    func testFlatRoadHasNoFeatures() {
        let points = (0..<30).map { ElevationPoint(distanceMetres: Double($0) * 250, altitudeMetres: 300) }
        XCTAssertTrue(TerrainAnalyser.features(in: points).isEmpty)
    }

    func testTooFewPointsIsNotAnError() {
        XCTAssertTrue(TerrainAnalyser.features(in: [ElevationPoint(distanceMetres: 0, altitudeMetres: 300)]).isEmpty)
    }

    func testPicksOneFeatureToShow() throws {
        let features = profile(flatPoints: 1, climbPoints: 25, risePerStep: 13.75)
        let chosen = try XCTUnwrap(TerrainAnalyser.mostRelevantFeature(in: features))
        XCTAssertEqual(chosen.kind, .climb)
        XCTAssertTrue(chosen.isUnderway)
        XCTAssertEqual(chosen.headline, "Long climb")
    }

    func testMockProviderIsOnlyEverAMock() async throws {
        let provider = MockElevationProvider(shape: .longClimb)
        let points = try await provider.elevationProfile(along: [])
        XCTAssertFalse(points.isEmpty)
        let feature = try XCTUnwrap(TerrainAnalyser.mostRelevantFeature(in: points))
        XCTAssertEqual(feature.kind, .climb)
    }
}

final class RoadImpactTests: XCTestCase {

    private func normalRoad(count: Int, from index: Int = 0) -> [MotionSample] {
        (index..<(index + count)).map { step in
            MotionSample(timestamp: base.addingTimeInterval(Double(step) * 0.1),
                         verticalG: 0.01 + Double(step % 5) * 0.01,
                         speedKmh: 60)
        }
    }

    func testQuietRoadProducesNoEvents() {
        var detector = RoadImpactDetector()
        for sample in normalRoad(count: 100) {
            XCTAssertNil(detector.consider(sample, location: nil))
        }
    }

    func testStrongJoltAtRoadSpeedIsRecorded() throws {
        var detector = RoadImpactDetector()
        for sample in normalRoad(count: 60) { _ = detector.consider(sample, location: nil) }

        let jolt = MotionSample(timestamp: base.addingTimeInterval(6.1), verticalG: 0.9, speedKmh: 60)
        let event = try XCTUnwrap(detector.consider(jolt, location: nil))
        XCTAssertEqual(event.peakVerticalG, 0.9, accuracy: 0.001)
        XCTAssertEqual(event.classification, .possibleSurfaceIrregularity)
        XCTAssertGreaterThan(event.confidence, 0.5)
        XCTAssertGreaterThan(event.deviceMountingConfidence, 0.6)
    }

    func testTheSameBumpIsNotReportedSixTimes() throws {
        var detector = RoadImpactDetector()
        for sample in normalRoad(count: 60) { _ = detector.consider(sample, location: nil) }

        _ = try XCTUnwrap(detector.consider(
            MotionSample(timestamp: base.addingTimeInterval(6.1), verticalG: 0.9, speedKmh: 60), location: nil))
        XCTAssertNil(detector.consider(
            MotionSample(timestamp: base.addingTimeInterval(6.5), verticalG: 0.85, speedKmh: 60), location: nil),
                     "the refractory period must collapse one bump into one event")
    }

    func testJoltAtWalkingPaceIsRecordedButNotClassified() throws {
        var detector = RoadImpactDetector()
        for sample in normalRoad(count: 60) { _ = detector.consider(sample, location: nil) }

        let jolt = MotionSample(timestamp: base.addingTimeInterval(6.1), verticalG: 0.9, speedKmh: 4)
        let event = try XCTUnwrap(detector.consider(jolt, location: nil))
        XCTAssertEqual(event.classification, .unclassified,
                       "a phone being picked up looks exactly like this")
        XCTAssertLessThanOrEqual(event.confidence, 0.4)
    }

    func testNoEventsBeforeABaselineExists() {
        var detector = RoadImpactDetector()
        let jolt = MotionSample(timestamp: base, verticalG: 1.2, speedKmh: 60)
        XCTAssertNil(detector.consider(jolt, location: nil))
    }

    func testClassificationHasNoPotholeCase() {
        XCTAssertEqual(Set(RoadImpactEvent.Classification.allCases.map(\.rawValue)),
                       ["unclassified", "possibleSurfaceIrregularity"],
                       "DriveLayer must not claim to have identified a pothole")
    }
}

final class DocumentExtractionTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_780_000_000)   // mid-2026

    func testExtractsInsuranceFields() throws {
        let lines = [
            "MOTOR INSURANCE POLICY",
            "Policy No: POL9876543210",
            "Issue Date: 01/04/2026",
            "Valid Until: 31/03/2027"
        ]
        let extraction = DocumentFieldExtractor().extract(fromRecognisedLines: lines, now: now)
        XCTAssertEqual(extraction.suggestedKind, .insurance)
        XCTAssertEqual(extraction.referenceNumber, "POL9876543210")
        XCTAssertNotNil(extraction.expiryDate)
        XCTAssertNotNil(extraction.issueDate)
        XCTAssertGreaterThan(extraction.expiryDate ?? .distantPast, now)
        XCTAssertLessThan(extraction.issueDate ?? .distantFuture, now)
        XCTAssertGreaterThan(extraction.confidence, 0.5)
        XCTAssertLessThanOrEqual(extraction.confidence, 0.9, "extraction is never certain")
    }

    func testEmptyScanExtractsNothingRatherThanGuessing() {
        let extraction = DocumentFieldExtractor().extract(fromRecognisedLines: [], now: now)
        XCTAssertEqual(extraction, .empty)
        XCTAssertEqual(extraction.confidence, 0)
    }

    func testUnrecognisableTextYieldsLowConfidence() {
        let extraction = DocumentFieldExtractor().extract(fromRecognisedLines: ["blurred", "scan"], now: now)
        XCTAssertNil(extraction.suggestedKind)
        XCTAssertNil(extraction.referenceNumber)
        XCTAssertEqual(extraction.confidence, 0, accuracy: 0.001)
    }

    func testDatesAreNotMistakenForReferenceNumbers() {
        XCTAssertNil(DocumentFieldExtractor.referenceNumber(in: ["Issue Date: 01/04/2026"]))
        XCTAssertNil(DocumentFieldExtractor.referenceNumber(in: ["Date 2026-04-01"]))
    }

    func testRecognisesPollutionCertificate() {
        let extraction = DocumentFieldExtractor().extract(
            fromRecognisedLines: ["POLLUTION UNDER CONTROL CERTIFICATE", "Valid Until: 30/09/2026"], now: now)
        XCTAssertEqual(extraction.suggestedKind, .pollutionCertificate)
    }
}

final class VehicleProfileTests: XCTestCase {

    private let harrier = VehicleProfileCatalog.harrier2026AdventureXPlus

    func testReferenceProfileIsHonestAboutWhatIsVerified() {
        XCTAssertEqual(harrier.validationTier, .experimental,
                       "no Tata-specific telemetry has been validated, so it cannot claim `validated`")
        XCTAssertTrue(harrier.usableManufacturerCapabilities.isEmpty)
        XCTAssertTrue(harrier.expectedStandardPIDs.isEmpty,
                      "what a car reports is decided by discovery, not by a guess in a profile")
        XCTAssertFalse(harrier.notes.isEmpty)
    }

    /// The reference vehicle now declares no extension points at all, so asserting
    /// its usable set is empty proves nothing on its own. This keeps the real rule
    /// under test: a declared but unvalidated capability is never usable.
    func testDeclaredButUnvalidatedCapabilitiesAreNeverUsable() {
        let diesel = VehicleProfileCatalog.genericDiesel
        XCTAssertFalse(diesel.manufacturerCapabilities.isEmpty,
                       "this test needs a profile that actually declares extension points")
        XCTAssertTrue(diesel.usableManufacturerCapabilities.isEmpty)
    }

    /// The reference vehicle is a 1.5-litre TGDi petrol, so nothing about it may be
    /// described in diesel terms — and the figures carried over from the diesel
    /// variant must not be labelled as published for this engine.
    func testReferenceProfileIsThePetrolEngine() {
        XCTAssertEqual(harrier.fuelType, .petrol)
        XCTAssertEqual(harrier.engine.displacementLitres, 1.5)
        XCTAssertNil(harrier.engine.ratedPowerPS,
                     "an unsourced brochure figure is worse than no figure")
        XCTAssertNil(harrier.engine.ratedTorqueNm)
        XCTAssertTrue(harrier.manufacturerCapabilities.isEmpty,
                      "DPF and exhaust-temperature extension points belong to a diesel")
    }

    func testSpecSourcesAreRecorded() throws {
        XCTAssertEqual(harrier.tankCapacityLitres, 50)
        XCTAssertEqual(harrier.tankCapacitySource, .genericDefault,
                       "50 L is the diesel variant's published figure, carried over unverified")
        XCTAssertFalse(harrier.tankCapacitySource.isVehicleSpecific)
        let genericInterval = try XCTUnwrap(harrier.serviceInterval(id: "air-filter"))
        XCTAssertEqual(genericInterval.source, .genericDefault)
        XCTAssertFalse(genericInterval.source.isVehicleSpecific)
    }

    func testOperatingRangesAreScopedToAnEngineCondition() throws {
        let running = try XCTUnwrap(harrier.operatingRange(for: .controlModuleVoltageV, condition: .engineRunning))
        let off = try XCTUnwrap(harrier.operatingRange(for: .controlModuleVoltageV, condition: .engineOff))
        XCTAssertEqual(running.status(for: 14.1), .normal)
        XCTAssertEqual(off.status(for: 14.1), .watch, "14.1 V with the engine off is not normal")
        XCTAssertEqual(off.status(for: 12.5), .normal)
    }

    func testRangeWithNoBandsIsUnknownNotNormal() {
        let range = OperatingRangeSpec(metric: .engineRPM, source: .genericDefault)
        XCTAssertEqual(range.status(for: 2_000), .unknown)
    }

    func testRangeEscalatesOutermostFirst() {
        let range = OperatingRangeSpec(metric: .coolantTemperatureC,
                                       normalLow: 78, normalHigh: 103,
                                       watchHigh: 108, criticalHigh: 115,
                                       source: .genericDefault)
        XCTAssertEqual(range.status(for: 90), .normal)
        XCTAssertEqual(range.status(for: 105), .watch)
        XCTAssertEqual(range.status(for: 110), .attention)
        XCTAssertEqual(range.status(for: 120), .critical)
    }

    func testVehicleOverrideBeatsTheProfile() {
        var vehicle = Vehicle(nickname: "Harrier", profileID: harrier.id)
        XCTAssertEqual(vehicle.tankCapacityLitres(profile: harrier), 50)
        vehicle.tankCapacityOverrideLitres = 45
        XCTAssertEqual(vehicle.tankCapacityLitres(profile: harrier), 45)
        XCTAssertEqual(vehicle.tankCapacitySource(profile: harrier), .userProvided)
    }

    /// Clearing the override returns to the profile's figure. A driver who mistypes
    /// their tank size must be able to get back out of it — range is estimated from
    /// this number, so being stuck with a wrong one means a wrong distance on every
    /// screen that shows range.
    func testClearingTheOverrideFallsBackToTheProfile() {
        var vehicle = Vehicle(nickname: "Harrier", profileID: harrier.id,
                              tankCapacityOverrideLitres: 45)
        XCTAssertEqual(vehicle.tankCapacityLitres(profile: harrier), 45)

        vehicle.tankCapacityOverrideLitres = nil
        XCTAssertEqual(vehicle.tankCapacityLitres(profile: harrier), 50)
        XCTAssertEqual(vehicle.tankCapacitySource(profile: harrier), harrier.tankCapacitySource)

        // A typed zero is not a tank size either.
        vehicle.tankCapacityOverrideLitres = 0
        XCTAssertEqual(vehicle.tankCapacityLitres(profile: harrier), 50)
        XCTAssertEqual(vehicle.tankCapacitySource(profile: harrier), harrier.tankCapacitySource)
    }

    // MARK: - Product scope

    /// DriveLayer offers one car at the moment. These pin the scope so that widening
    /// it is a deliberate edit rather than something that happens by accident.
    func testOnlyTheReferenceVehicleIsOffered() {
        XCTAssertEqual(SupportedVehicles.offeredProfileIDs, [harrier.id])
        XCTAssertTrue(SupportedVehicles.isSingleVehicle)
        XCTAssertEqual(SupportedVehicles.only?.id, harrier.id)
    }

    /// A typo in an offered ID would leave the app with an empty picker and no way to
    /// add a car, which is the kind of failure that only shows up on a device.
    func testEveryOfferedProfileExistsInTheCatalog() {
        XCTAssertEqual(SupportedVehicles.offered.count, SupportedVehicles.offeredProfileIDs.count,
                       "an offered profile ID does not resolve in the catalog")
        XCTAssertNotNil(VehicleProfileCatalog.profile(id: SupportedVehicles.defaultProfileID))
    }

    /// Narrowing what is offered must not narrow the catalog: the generic profiles
    /// are what a second car gets built on, and the diesel one is the fixture the
    /// Diesel Guardian tests depend on.
    func testCatalogStillCarriesTheProfilesThatAreNotOffered() {
        XCTAssertNotNil(VehicleProfileCatalog.profile(id: VehicleProfileCatalog.genericDieselID))
        XCTAssertNotNil(VehicleProfileCatalog.profile(id: VehicleProfileCatalog.genericPetrolID))
        XCTAssertGreaterThan(VehicleProfileCatalog.all.count, SupportedVehicles.offered.count)
    }

    func testVehicleDescriptionNeverLeaksIdentifiers() {
        let vehicle = Vehicle(nickname: "Harrier", profileID: harrier.id,
                              registrationNumber: "KA01AB1234", vin: "MAT123456789")
        XCTAssertFalse(vehicle.redactedDescription.contains("KA01AB1234"))
        XCTAssertFalse(vehicle.redactedDescription.contains("MAT123456789"))
    }

    func testCatalogueProfilesAreInternallyConsistent() {
        for profile in VehicleProfileCatalog.all {
            XCTAssertFalse(profile.id.isEmpty)
            XCTAssertFalse(profile.displayName.isEmpty)
            for capability in profile.manufacturerCapabilities where !capability.isUsable {
                XCTAssertNil(capability.validatedRequest)
            }
            if profile.validationTier != .validated {
                XCTAssertTrue(profile.usableManufacturerCapabilities.isEmpty,
                              "only a validated profile may expose manufacturer data")
            }
        }
    }
}

final class UnitTests: XCTestCase {

    func testEconomyConversions() throws {
        XCTAssertEqual(try XCTUnwrap(EconomyUnit.kilometresPerLitre.value(fromKilometresPerLitre: 12.5)), 12.5, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(EconomyUnit.litresPer100km.value(fromKilometresPerLitre: 12.5)), 8.0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(EconomyUnit.milesPerGallonUS.value(fromKilometresPerLitre: 12.5)), 29.4, accuracy: 0.05)
    }

    func testZeroEconomyIsNilNotInfinity() {
        XCTAssertNil(EconomyUnit.litresPer100km.value(fromKilometresPerLitre: 0))
        XCTAssertNil(EconomyUnit.kilometresPerLitre.value(fromKilometresPerLitre: -3))
    }

    func testSpeedConversionRoundTrips() {
        XCTAssertEqual(Convert.kmh(fromMetresPerSecond: Convert.metresPerSecond(fromKmh: 95)), 95, accuracy: 0.0001)
    }

    func testGradientNeedsARunToDivideBy() {
        XCTAssertNil(Convert.gradientPercent(rise: 5, run: 0))
        XCTAssertEqual(try XCTUnwrap(Convert.gradientPercent(rise: 5, run: 100)), 5, accuracy: 0.001)
    }
}
