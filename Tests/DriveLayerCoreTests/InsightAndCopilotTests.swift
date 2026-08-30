import XCTest
@testable import DriveLayerCore

private let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)
private let harrier = VehicleProfileCatalog.harrier2026AdventureXPlus

private func telemetry(_ values: [VehicleMetric: Double], at time: Date = referenceDate) -> VehicleTelemetry {
    var result = VehicleTelemetry(updatedAt: time)
    for (metric, value) in values { result.set(metric, value: value, at: time) }
    return result
}

private func establishedBaseline(_ metric: VehicleMetric,
                                 _ context: BaselineContext,
                                 dailyValue: (Int) -> Double,
                                 now: Date = referenceDate) -> (BaselineKey, MetricBaseline) {
    let key = BaselineKey(metric: metric, context: context)
    var aggregates: [BaselineDailyAggregate] = []
    for daysAgo in 0..<30 {
        let day = now.addingTimeInterval(-Double(daysAgo) * 86_400)
        BaselineEngine.accumulate(into: &aggregates, key: key, value: dailyValue(daysAgo), at: day)
        BaselineEngine.accumulate(into: &aggregates, key: key, value: dailyValue(daysAgo) + 0.01, at: day)
    }
    return (key, BaselineEngine.build(key: key, from: aggregates, now: now)!)
}

final class InsightRuleTests: XCTestCase {

    func testHighCoolantIsReportedRegardlessOfHabit() throws {
        let context = InsightContext(now: referenceDate,
                                     profile: harrier,
                                     isAdapterConnected: true,
                                     telemetry: telemetry([.coolantTemperatureC: 118]),
                                     isDriving: true)
        let insights = EngineTemperatureRule().evaluate(context)
        let insight = try XCTUnwrap(insights.first)
        XCTAssertEqual(insight.severity, .critical)
        XCTAssertEqual(insight.id, "engine.temperature.high")
        XCTAssertNotNil(insight.recommendedAction)
    }

    func testHotButNormalOnAClimbReadsAsReassurance() throws {
        // A real baseline has spread: this car has run 94–98 °C on climbs.
        let (key, baseline) = establishedBaseline(.coolantTemperatureC, .climbing) { daysAgo in
            94 + Double(daysAgo % 5)
        }
        let context = InsightContext(now: referenceDate,
                                     profile: harrier,
                                     isAdapterConnected: true,
                                     telemetry: telemetry([.coolantTemperatureC: 98.5]),
                                     baselines: [key: baseline],
                                     gradient: GradientEstimate(percent: 7, overDistanceMetres: 400,
                                                                altitudeChangeMetres: 28, confidence: 0.8),
                                     isDriving: true)
        let insight = try XCTUnwrap(EngineTemperatureRule().evaluate(context).first)
        XCTAssertEqual(insight.severity, .normal)
        XCTAssertTrue(insight.summary.contains("normal range for a climb"))
    }

    func testNothingIsSaidWithoutCoolantData() {
        let context = InsightContext(now: referenceDate, profile: harrier, isAdapterConnected: true)
        XCTAssertTrue(EngineTemperatureRule().evaluate(context).isEmpty)
    }

    func testBatteryTrendFiresOnDriftNotOnASingleReading() throws {
        let (key, baseline) = establishedBaseline(.controlModuleVoltageV, .engineOff) { daysAgo in
            12.20 + Double(daysAgo) * 0.01
        }
        let context = InsightContext(now: referenceDate,
                                     profile: harrier,
                                     isAdapterConnected: true,
                                     telemetry: telemetry([.controlModuleVoltageV: 12.4, .engineRPM: 0]),
                                     baselines: [key: baseline])
        let insight = try XCTUnwrap(BatteryHealthRule().evaluate(context).first)
        XCTAssertEqual(insight.id, "battery.declining-trend")
        XCTAssertEqual(insight.severity, .watch)
        XCTAssertTrue(insight.title.contains("BATTERY WATCH"))
        XCTAssertNotNil(insight.details)
    }

    func testLowVoltageWithEngineRunningIsAnImmediateFinding() throws {
        let context = InsightContext(now: referenceDate,
                                     profile: harrier,
                                     isAdapterConnected: true,
                                     telemetry: telemetry([.controlModuleVoltageV: 11.5, .engineRPM: 1_500]))
        let insight = try XCTUnwrap(BatteryHealthRule().evaluate(context).first)
        XCTAssertEqual(insight.id, "battery.out-of-range")
        XCTAssertGreaterThanOrEqual(insight.severity, .attention)
    }

    func testHighLoadOnAClimbIsNotAlarming() throws {
        let (key, baseline) = establishedBaseline(.engineLoadPercent, .climbing) { _ in 60 }
        let context = InsightContext(now: referenceDate,
                                     profile: harrier,
                                     isAdapterConnected: true,
                                     telemetry: telemetry([.engineLoadPercent: 85]),
                                     baselines: [key: baseline],
                                     gradient: GradientEstimate(percent: 6, overDistanceMetres: 400,
                                                                altitudeChangeMetres: 24, confidence: 0.8),
                                     isDriving: true)
        let insight = try XCTUnwrap(EngineLoadRule().evaluate(context).first)
        XCTAssertEqual(insight.severity, .normal)
        XCTAssertTrue(insight.summary.contains("expected on a gradient"))
    }

    func testTroubleCodeInsightUsesTheWorstCode() throws {
        let context = InsightContext(now: referenceDate,
                                     profile: harrier,
                                     isAdapterConnected: true,
                                     troubleCodes: [
                                        DiagnosticTroubleCode(code: "P0420", system: .powertrain, status: .stored),
                                        DiagnosticTroubleCode(code: "P0300", system: .powertrain, status: .stored)
                                     ])
        let insight = try XCTUnwrap(TroubleCodeRule().evaluate(context).first)
        XCTAssertTrue(insight.summary.hasPrefix("P0300"), "the misfire outranks the catalyst code")
        XCTAssertEqual(insight.severity, .critical)
        XCTAssertTrue(insight.summary.contains("1 other code"))
    }

    func testUnknownCodeCarriesLowerConfidence() throws {
        let context = InsightContext(now: referenceDate, isAdapterConnected: true,
                                     troubleCodes: [DiagnosticTroubleCode(code: "P1234", system: .powertrain, status: .stored)])
        let insight = try XCTUnwrap(TroubleCodeRule().evaluate(context).first)
        XCTAssertLessThanOrEqual(insight.confidence, 0.6)
    }

    func testMaintenanceFromAGenericDefaultIsMarkedAsSuch() throws {
        let item = MaintenanceItem(vehicleID: UUID(), kind: .airFilter,
                                   intervalDistanceKm: 30_000, lastDoneOdometerKm: 10_000,
                                   source: .genericDefault)
        let due = MaintenanceEngine.status(for: item, currentOdometerKm: 39_500, now: referenceDate)
        let context = InsightContext(now: referenceDate, maintenanceStatuses: [due])
        let insight = try XCTUnwrap(MaintenanceRule().evaluate(context).first)
        XCTAssertFalse(insight.isDrivingSafeToDisplay, "maintenance reading is for when parked")
        XCTAssertLessThanOrEqual(insight.confidence, 0.6)
        XCTAssertTrue(try XCTUnwrap(insight.details).contains("generic default"))
    }
}

final class InsightEngineTests: XCTestCase {

    private struct StubRule: InsightRule {
        let identifier: String
        let insights: [DriveInsight]
        func evaluate(_ context: InsightContext) -> [DriveInsight] { insights }
    }

    private func insight(_ id: String,
                         _ severity: SemanticStatus,
                         drivingSafe: Bool = true,
                         expiresIn: TimeInterval? = 600,
                         createdAt: Date = referenceDate) -> DriveInsight {
        DriveInsight(id: id, category: .vehicle, severity: severity, title: id, summary: id,
                     createdAt: createdAt,
                     expiresAt: expiresIn.map { createdAt.addingTimeInterval($0) },
                     isDrivingSafeToDisplay: drivingSafe)
    }

    func testSortsBySeverityThenConfidence() {
        let engine = InsightEngine(rules: [StubRule(identifier: "s", insights: [
            insight("a", .normal), insight("b", .critical), insight("c", .watch)
        ])])
        let result = engine.evaluate(InsightContext(now: referenceDate))
        XCTAssertEqual(result.map(\.id), ["b", "c", "a"])
    }

    func testExpiredInsightsAreDropped() {
        let stale = insight("old", .attention, expiresIn: 60, createdAt: referenceDate.addingTimeInterval(-3_600))
        let engine = InsightEngine(rules: [])
        XCTAssertTrue(engine.evaluate(InsightContext(now: referenceDate), existing: [stale]).isEmpty)
    }

    func testStillValidInsightsAreCarriedForward() {
        let existing = insight("carried", .watch, expiresIn: 3_600)
        let engine = InsightEngine(rules: [])
        XCTAssertEqual(engine.evaluate(InsightContext(now: referenceDate), existing: [existing]).map(\.id), ["carried"])
    }

    func testRegeneratedInsightReplacesRatherThanDuplicates() {
        let fresh = insight("same", .watch, createdAt: referenceDate.addingTimeInterval(10))
        let old = insight("same", .watch, createdAt: referenceDate)
        let engine = InsightEngine(rules: [StubRule(identifier: "s", insights: [fresh])])
        let result = engine.evaluate(InsightContext(now: referenceDate.addingTimeInterval(20)), existing: [old])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.createdAt, fresh.createdAt)
    }

    func testDrivingViewIsShortAndFiltered() {
        let insights = [
            insight("a", .critical), insight("b", .attention),
            insight("c", .watch, drivingSafe: false), insight("d", .watch), insight("e", .normal)
        ]
        let driving = InsightEngine.forDriving(insights)
        XCTAssertEqual(driving.count, 3)
        XCTAssertFalse(driving.contains { $0.id == "c" })
        XCTAssertEqual(InsightEngine.headline(insights)?.id, "a")
    }

    func testConfidenceIsCappedByTheWeakestEvidence() {
        let inferred = DriveInsight(id: "x", category: .diesel, severity: .watch, title: "T", summary: "S",
                                    confidence: 0.95,
                                    sourceData: [.measured("A", "1"), .inferred("B", "2")],
                                    createdAt: referenceDate)
        XCTAssertLessThanOrEqual(inferred.confidence, DataProvenance.inferred.confidenceCeiling)
    }
}

final class VehicleHealthTests: XCTestCase {

    func testDisconnectedAdapterYieldsUnknownNotHealthy() throws {
        let report = VehicleHealthEvaluator.evaluate(InsightContext(now: referenceDate, profile: harrier))
        let engine = try XCTUnwrap(report.system(.engine))
        XCTAssertEqual(engine.status, .unknown)
        XCTAssertEqual(engine.unavailability, .obdNotConnected)
        XCTAssertTrue(report.isLimitedByMissingData)
        XCTAssertNotEqual(report.overall, .normal)
    }

    func testUnsupportedSensorIsExplainedRatherThanShownAsZero() throws {
        let context = InsightContext(now: referenceDate, profile: harrier, isAdapterConnected: true,
                                     telemetry: telemetry([.engineRPM: 1_500]))
        let report = VehicleHealthEvaluator.evaluate(context)
        let engine = try XCTUnwrap(report.system(.engine))
        XCTAssertEqual(engine.unavailability, .pidNotSupportedByVehicle("Coolant temperature"))
    }

    func testHealthyVehicleRollsUpToNormal() throws {
        let context = InsightContext(now: referenceDate,
                                     profile: harrier,
                                     isAdapterConnected: true,
                                     telemetry: telemetry([.coolantTemperatureC: 90,
                                                           .controlModuleVoltageV: 14.1,
                                                           .engineRPM: 1_600,
                                                           .engineLoadPercent: 38]),
                                     maintenanceStatuses: [],
                                     fuelStatus: FuelIntelligence.status(levelPercent: .measured(58),
                                                                        tankCapacityLitres: 50,
                                                                        economy: (12.8, .recentTrips)))
        let report = VehicleHealthEvaluator.evaluate(context)
        XCTAssertEqual(try XCTUnwrap(report.system(.engine)).status, .normal)
        XCTAssertEqual(try XCTUnwrap(report.system(.battery)).status, .normal)
        XCTAssertEqual(try XCTUnwrap(report.system(.fuelSystem)).status, .normal)
        XCTAssertEqual(try XCTUnwrap(report.system(.diagnostics)).status, .normal)
    }

    func testWorstSystemDrivesTheOverallVerdict() {
        let context = InsightContext(now: referenceDate,
                                     profile: harrier,
                                     isAdapterConnected: true,
                                     // Above the petrol profile's critical coolant
                                     // band. The point of the test is the roll-up,
                                     // not the threshold, so it uses a value no
                                     // sane band would call anything but critical.
                                     telemetry: telemetry([.coolantTemperatureC: 121,
                                                           .controlModuleVoltageV: 14.1,
                                                           .engineRPM: 1_600]))
        XCTAssertEqual(VehicleHealthEvaluator.evaluate(context).overall, .critical)
    }
}

final class RouteWeatherTests: XCTestCase {

    private func routePoint(_ km: Double, condition: WeatherConditionKind,
                            intensity: Double? = nil, visibility: Double? = 12_000,
                            temperature: Double = 24) -> RouteWeatherPoint {
        RouteWeatherPoint(distanceMetres: km * 1_000,
                          expectedAt: referenceDate.addingTimeInterval(km * 45),
                          snapshot: WeatherSnapshot(timestamp: referenceDate,
                                                    condition: condition,
                                                    temperatureC: temperature,
                                                    precipitationIntensityMillimetresPerHour: intensity,
                                                    visibilityMetres: visibility))
    }

    func testReportsWhereRainStartsNotEveryPoint() throws {
        let clear = WeatherSnapshot(timestamp: referenceDate, condition: .clear,
                                    temperatureC: 26, precipitationIntensityMillimetresPerHour: 0)
        let route = [
            routePoint(5, condition: .clear, intensity: 0),
            routePoint(14, condition: .clear, intensity: 0),
            routePoint(22, condition: .rain, intensity: 3.4),
            routePoint(30, condition: .rain, intensity: 3.6),
            routePoint(38, condition: .heavyRain, intensity: 12)
        ]
        let changes = RouteWeatherAnalyser.changes(current: clear, along: route)
        XCTAssertEqual(changes.count, 1, "one onset, not a card every few kilometres")
        XCTAssertEqual(changes[0].kind, .precipitationStarting)
        XCTAssertEqual(changes[0].distanceMetres, 22_000, accuracy: 1)
        XCTAssertTrue(changes[0].detail.contains("22 km"))
    }

    func testFogAheadIsCalledOut() throws {
        let clear = WeatherSnapshot(timestamp: referenceDate, condition: .clear, temperatureC: 18,
                                    precipitationIntensityMillimetresPerHour: 0, visibilityMetres: 15_000)
        let route = [routePoint(4, condition: .clear, intensity: 0),
                     routePoint(9, condition: .fog, intensity: 0, visibility: 300)]
        let change = try XCTUnwrap(RouteWeatherAnalyser.changes(current: clear, along: route).first)
        XCTAssertEqual(change.kind, .fogRisk)
        XCTAssertEqual(change.severity, .attention)
    }

    func testNearFreezingWithMoistureFlagsPossibleIce() throws {
        var snapshot = WeatherSnapshot(timestamp: referenceDate, condition: .cloudy, temperatureC: 1,
                                       precipitationIntensityMillimetresPerHour: 0.5)
        snapshot.humidityFraction = 0.95
        let route = [RouteWeatherPoint(distanceMetres: 8_000,
                                       expectedAt: referenceDate.addingTimeInterval(400),
                                       snapshot: snapshot)]
        let clear = WeatherSnapshot(timestamp: referenceDate, condition: .clear, temperatureC: 8,
                                    precipitationIntensityMillimetresPerHour: 0)
        let changes = RouteWeatherAnalyser.changes(current: clear, along: route)
        XCTAssertTrue(changes.contains { $0.kind == .iceRisk })
        XCTAssertTrue(try XCTUnwrap(changes.first { $0.kind == .iceRisk }).detail.contains("may be slippery"))
    }

    func testNothingChangingProducesNoNoise() {
        let clear = WeatherSnapshot(timestamp: referenceDate, condition: .clear, temperatureC: 26,
                                    precipitationIntensityMillimetresPerHour: 0)
        let route = (1...6).map { routePoint(Double($0) * 8, condition: .clear, intensity: 0) }
        XCTAssertTrue(RouteWeatherAnalyser.changes(current: clear, along: route).isEmpty)
    }

    func testChangesTooCloseToActOnAreIgnored() {
        let clear = WeatherSnapshot(timestamp: referenceDate, condition: .clear, temperatureC: 26,
                                    precipitationIntensityMillimetresPerHour: 0)
        let route = [routePoint(0.5, condition: .heavyRain, intensity: 12)]
        XCTAssertTrue(RouteWeatherAnalyser.changes(current: clear, along: route).isEmpty)
    }

    func testAtMostTwoChangesWhileDriving() {
        let clear = WeatherSnapshot(timestamp: referenceDate, condition: .clear, temperatureC: 1,
                                    precipitationIntensityMillimetresPerHour: 0)
        var wet = WeatherSnapshot(timestamp: referenceDate, condition: .heavyRain, temperatureC: 1,
                                  precipitationIntensityMillimetresPerHour: 12, visibilityMetres: 200)
        wet.windGustKmh = 80
        wet.humidityFraction = 0.98
        let route = [RouteWeatherPoint(distanceMetres: 10_000,
                                       expectedAt: referenceDate.addingTimeInterval(500),
                                       snapshot: wet)]
        XCTAssertLessThanOrEqual(RouteWeatherAnalyser.changes(current: clear, along: route).count, 2)
    }

    func testPrecipitationBands() {
        func band(_ intensity: Double) -> PrecipitationBand {
            WeatherSnapshot(timestamp: referenceDate,
                            precipitationIntensityMillimetresPerHour: intensity).precipitationBand
        }
        XCTAssertEqual(band(0), .none)
        XCTAssertEqual(band(1.0), .light)
        XCTAssertEqual(band(4.0), .moderate)
        XCTAssertEqual(band(20), .heavy)
        XCTAssertEqual(WeatherSnapshot(timestamp: referenceDate).precipitationBand, .none,
                       "missing data is not rain")
    }

    // MARK: - The horizon, and distances that keep up with the driver

    /// A straight run north from the equator, a vertex roughly every 1.1 km.
    private func straightPolyline(vertexCount: Int, stepDegrees: Double = 0.01) -> [GeoPoint] {
        (0..<vertexCount).map { index in
            GeoPoint(latitude: Double(index) * stepDegrees, longitude: 0, timestamp: referenceDate)
        }
    }

    private func distanceAlong(_ polyline: [GeoPoint], to index: Int) -> Double {
        guard index > 0 else { return 0 }
        return (1...index).reduce(0.0) { $0 + Geo.distance(from: polyline[$1 - 1], to: polyline[$1]) }
    }

    func testWaypointsStopAtTheForecastHorizon() {
        // About 340 km of road, against a horizon of 60 km.
        let polyline = straightPolyline(vertexCount: 306)
        let waypoints = RouteWeatherAnalyser.waypoints(along: polyline,
                                                       from: referenceDate,
                                                       averageSpeedKmh: 90)
        XCTAssertFalse(waypoints.isEmpty)
        XCTAssertLessThanOrEqual(waypoints.count, 6,
                                 "one lookup per 10 km of the horizon, not of the whole road")
        for waypoint in waypoints {
            XCTAssertLessThanOrEqual(waypoint.distanceMetres, RouteWeatherAnalyser.horizonMetres,
                                     "a waypoint past the horizon is a network call whose result changes() discards")
        }
    }

    func testWaypointsStillReachTheHorizonTheyAreCappedAt() throws {
        let polyline = straightPolyline(vertexCount: 306)
        let waypoints = RouteWeatherAnalyser.waypoints(along: polyline,
                                                       from: referenceDate,
                                                       averageSpeedKmh: 90)
        let furthest = try XCTUnwrap(waypoints.last)
        XCTAssertGreaterThan(furthest.distanceMetres,
                             RouteWeatherAnalyser.horizonMetres - 10_000,
                             "capping must not cost the far end of the horizon")
    }

    func testRemeasuredSubtractsWhatTheDriverHasAlreadyCovered() throws {
        let polyline = straightPolyline(vertexCount: 61)
        let driverIndex = 18
        let travelled = distanceAlong(polyline, to: driverIndex)
        let points = [routePoint(30, condition: .rain, intensity: 4),
                      routePoint(50, condition: .rain, intensity: 4)]

        let remeasured = RouteWeatherAnalyser.remeasured(points,
                                                        along: polyline,
                                                        from: polyline[driverIndex])

        XCTAssertEqual(remeasured.count, 2)
        XCTAssertEqual(remeasured[0].distanceMetres, 30_000 - travelled, accuracy: 200)
        XCTAssertEqual(remeasured[1].distanceMetres, 50_000 - travelled, accuracy: 200)
        XCTAssertEqual(remeasured[0].snapshot, points[0].snapshot,
                       "the distance is re-measured; the forecast is not re-invented")
        XCTAssertEqual(remeasured[0].expectedAt, points[0].expectedAt)
    }

    func testRemeasuredDropsWhatIsAlreadyBehindTheDriver() {
        let polyline = straightPolyline(vertexCount: 61)
        let points = [routePoint(5, condition: .rain, intensity: 4),
                      routePoint(40, condition: .rain, intensity: 4)]

        // About 33 km along, so the 5 km point is well behind them.
        let remeasured = RouteWeatherAnalyser.remeasured(points, along: polyline, from: polyline[30])

        XCTAssertEqual(remeasured.count, 1, "rain already driven through is not rain ahead")
        XCTAssertLessThan(remeasured[0].distanceMetres, 40_000)
    }

    func testRemeasuringIsWhatLetsTheTooCloseFilterFire() {
        let clear = WeatherSnapshot(timestamp: referenceDate, condition: .clear,
                                    temperatureC: 26, precipitationIntensityMillimetresPerHour: 0)
        let polyline = straightPolyline(vertexCount: 61)
        let points = [routePoint(20, condition: .rain, intensity: 4)]

        // As fetched, with the driver at the start: rain 20 km ahead, worth saying.
        XCTAssertFalse(RouteWeatherAnalyser.changes(current: clear, along: points).isEmpty)

        // Now about 19 km along, so it is roughly 1 km away - inside
        // minimumWarningDistanceMetres, where there is no useful action left to take.
        let remeasured = RouteWeatherAnalyser.remeasured(points, along: polyline, from: polyline[17])
        XCTAssertTrue(RouteWeatherAnalyser.changes(current: clear, along: remeasured).isEmpty,
                      "a warning frozen at 20 km while the driver closes on it is a stale warning")
    }

    func testRemeasuredWithoutARouteLeavesThePointsAlone() {
        let points = [routePoint(20, condition: .rain, intensity: 4)]
        XCTAssertEqual(RouteWeatherAnalyser.remeasured(points, along: [], from: GeoPoint(
            latitude: 0, longitude: 0, timestamp: referenceDate)), points,
                       "no road to measure along is a reason to leave the numbers as they were")
    }
}

final class CopilotTests: XCTestCase {

    private func snapshot(configure: (inout VehicleContextSnapshot) -> Void = { _ in }) -> VehicleContextSnapshot {
        var snapshot = VehicleContextSnapshot(generatedAt: referenceDate)
        snapshot.health = .init(overall: "Healthy",
                                systems: ["Engine": "Normal", "Battery": "Watch"],
                                isLimitedByMissingData: false)
        snapshot.fuel = .init(levelPercent: 58, estimatedRangeKm: 326,
                              economyKmPerLitre: 12.8, economySource: "your recent drives")
        configure(&snapshot)
        return snapshot
    }

    func testExplainsATroubleCodeWithoutClaimingAFailedPart() throws {
        let answer = LocalCopilot.respond(to: "What does P2002 mean?", snapshot: snapshot())
        XCTAssertTrue(answer.wasUnderstood)
        XCTAssertTrue(answer.detailedText.contains("particulate filter"))
        XCTAssertTrue(try XCTUnwrap(answer.limitationNote).contains("not which part has failed"))
    }

    func testUnknownCodeIsMarkedAsAnInference() throws {
        let answer = LocalCopilot.respond(to: "what does P1234 mean", snapshot: snapshot())
        let first = try XCTUnwrap(answer.statements.first)
        XCTAssertEqual(first.claim, .inference)
    }

    func testRefusesToInventRegenerationData() throws {
        let answer = LocalCopilot.respond(to: "when was the last likely DPF regeneration?", snapshot: snapshot { snapshot in
            snapshot.diesel = .init(isApplicable: true, status: "Watch",
                                    explanation: "Most journeys this week were short.",
                                    shortTripPercent: 72, hasDirectFilterData: false)
        })
        XCTAssertTrue(answer.detailedText.contains("won't guess"))
        XCTAssertNotNil(answer.limitationNote)
        XCTAssertFalse(answer.detailedText.contains("%"), "no invented soot-load percentage")
        XCTAssertTrue(answer.statements.contains { $0.claim == .inference })
    }

    func testBatteryAnswerSeparatesMeasurementFromInference() throws {
        let answer = LocalCopilot.respond(to: "is my battery getting weak?", snapshot: snapshot { snapshot in
            snapshot.batteryBaselineV = 12.54
            snapshot.batteryTrendVPerWindow = -0.31
        })
        XCTAssertTrue(answer.statements.contains { $0.claim == .fact })
        let inference = try XCTUnwrap(answer.statements.first { $0.claim == .inference })
        XCTAssertTrue(inference.text.contains("0.31"))
    }

    func testRangeAnswerIsLabelledAsAnEstimate() throws {
        let answer = LocalCopilot.respond(to: "how far can I go on this tank?", snapshot: snapshot())
        let estimate = try XCTUnwrap(answer.statements.first { $0.claim == .estimate })
        XCTAssertTrue(estimate.text.contains("estimated range"))
        XCTAssertTrue(estimate.text.contains("326"))
    }

    func testTripFuelRefusesToEstimateFromDistanceAlone() throws {
        let answer = LocalCopilot.respond(to: "how much fuel did this trip use?", snapshot: snapshot { snapshot in
            snapshot.lastTrip = .init(startedAt: referenceDate, distanceKm: 42.6, durationMinutes: 47,
                                      idleMinutes: 14, economyKmPerLitre: nil, fuelLitres: nil,
                                      fuelProvenance: DataProvenance.unavailable.label,
                                      elevationGainMetres: 120, eventCount: 1)
        })
        XCTAssertTrue(answer.detailedText.contains("didn't report"))
        XCTAssertTrue(try XCTUnwrap(answer.limitationNote).contains("guess"))
    }

    func testShortDriveCountIsAnswered() {
        let answer = LocalCopilot.respond(to: "how many short drives did I do this week?", snapshot: snapshot { snapshot in
            snapshot.thisWeek = .init(label: "this week", tripCount: 9, distanceKm: 61,
                                      shortTripCount: 7, medianEconomyKmPerLitre: 11.4, idleFraction: 0.2)
        })
        XCTAssertTrue(answer.detailedText.contains("9 drives"))
        XCTAssertTrue(answer.detailedText.contains("7 of them"))
    }

    func testSpokenAnswerStaysShortForDriving() {
        let answer = LocalCopilot.respond(to: "how is the car?", snapshot: snapshot())
        XCTAssertLessThanOrEqual(answer.statements.prefix(2).count, 2)
        XCTAssertLessThan(answer.spokenText.count, 240)
        XCTAssertLessThanOrEqual(answer.spokenText.count, answer.detailedText.count)
    }

    func testUnrecognisedQuestionOffersExamplesRatherThanGuessing() {
        let answer = LocalCopilot.respond(to: "what is the meaning of life", snapshot: snapshot())
        XCTAssertFalse(answer.wasUnderstood)
        XCTAssertTrue(answer.detailedText.contains("You can ask me"))
    }

    func testMissingSectionsAreAnsweredHonestly() {
        var empty = VehicleContextSnapshot(generatedAt: referenceDate)
        empty.health = nil
        let answer = LocalCopilot.respond(to: "how is my engine doing?", snapshot: empty)
        XCTAssertTrue(answer.detailedText.contains("can't see engine data"))
    }

    func testSnapshotBuilderExcludesSensitiveAndRawData() throws {
        let vehicle = Vehicle(nickname: "Harrier",
                              profileID: VehicleProfileCatalog.harrier2026AdventureXPlusID,
                              registrationNumber: "KA01AB1234",
                              vin: "MAT123456789",
                              odometerKm: 43_880)
        let trip = Trip(vehicleID: vehicle.id, startedAt: referenceDate.addingTimeInterval(-3_600),
                        endedAt: referenceDate, endReason: .stoppedMoving,
                        distanceMetres: 42_600,
                        startLatitude: 12.9010, startLongitude: 77.6010,
                        endLatitude: 12.9700, endLongitude: 77.6400)
        let context = InsightContext(now: referenceDate, vehicle: vehicle, profile: harrier,
                                     isAdapterConnected: true,
                                     telemetry: telemetry([.coolantTemperatureC: 92]),
                                     recentTrips: [trip])
        let snapshot = CopilotContextBuilder.build(from: context,
                                                   health: VehicleHealthEvaluator.evaluate(context),
                                                   insights: [])

        let mirrored = String(describing: snapshot)
        XCTAssertFalse(mirrored.contains("KA01AB1234"), "registration must never reach the copilot")
        XCTAssertFalse(mirrored.contains("MAT123456789"), "VIN must never reach the copilot")
        XCTAssertFalse(mirrored.contains("77.60"), "coordinates must never reach the copilot")
        XCTAssertEqual(try XCTUnwrap(snapshot.lastTrip).distanceKm, 42.6, accuracy: 0.001)
        XCTAssertEqual(snapshot.vehicle?.capabilityLevel, VehicleCapabilityLevel.obdConnected.title)
    }

    func testCapabilityLevelNeverPromisesEnhancedForAnUnvalidatedProfile() {
        XCTAssertEqual(VehicleCapabilityLevel.current(profile: harrier, isAdapterConnected: true), .obdConnected)
        XCTAssertEqual(VehicleCapabilityLevel.current(profile: harrier, isAdapterConnected: false), .phoneOnly)
        XCTAssertEqual(VehicleCapabilityLevel.current(profile: nil, isAdapterConnected: true), .obdConnected)
    }
}
