import Foundation
import SwiftData

/// Realistic sample data for SwiftUI previews, screenshots and the simulator.
///
/// It exists so every screen can be developed and reviewed without a car, and it is
/// deliberately built from the same types the app uses at runtime — the demo trips go
/// through `TripAnalytics`, the demo insights come out of the real rules engine — so
/// a preview that looks right is evidence the production path is right too.
///
/// Nothing here is used in a release build: it is only referenced from previews and
/// from the in-memory preview container below.
enum DemoData {

    static let vehicleID = UUID(uuidString: "00000000-0000-0000-0000-00000000CAFE")!
    static let profile = VehicleProfileCatalog.harrier2026AdventureXPlus

    static var vehicle: Vehicle {
        Vehicle(id: vehicleID,
                nickname: "Harrier",
                profileID: profile.id,
                modelYear: 2026,
                odometerKm: 43_880,
                odometerUpdatedAt: Date(),
                isPrimary: true)
    }

    static var now: Date { Date() }

    /// Live values matching the demo described in the product brief.
    static var telemetry: VehicleTelemetry {
        var telemetry = VehicleTelemetry(updatedAt: now)
        telemetry.set(.coolantTemperatureC, value: 92, at: now)
        telemetry.set(.controlModuleVoltageV, value: 12.6, at: now)
        telemetry.set(.engineRPM, value: 1_820, at: now)
        telemetry.set(.vehicleSpeedKmh, value: 78, at: now)
        telemetry.set(.engineLoadPercent, value: 41, at: now)
        telemetry.set(.fuelLevelPercent, value: 58, at: now)
        telemetry.set(.fuelRateLitresPerHour, value: 5.9, at: now)
        telemetry.set(.intakeAirTemperatureC, value: 34, at: now)
        telemetry.set(.ambientAirTemperatureC, value: 29, at: now)
        return telemetry
    }

    static var capabilities: OBDCapabilityReport {
        OBDCapabilityReport(supportedCodes: SimulatedVehicleModel.defaultSupportedCodes,
                            storedDTCSupport: .supported,
                            pendingDTCSupport: .supported,
                            permanentDTCSupport: .unknown,
                            discoveredAt: now)
    }

    static var fuelStatus: FuelStatus {
        FuelIntelligence.status(levelPercent: .measured(58, at: now),
                                tankCapacityLitres: 50,
                                economy: (12.8, .recentTrips))
    }

    /// Thirty days of drives: a mix of commutes and longer runs, with a repeated
    /// route so trip comparison has something to compare.
    static var trips: [Trip] {
        var result: [Trip] = []
        for day in 0..<30 {
            let start = now.addingTimeInterval(-Double(day) * 86_400 - 8 * 3_600)
            let isCommute = day % 3 != 0
            let distance = isCommute ? 11_200.0 : 42_600.0
            let minutes = isCommute ? Double(41 + (day % 4) * 2) : 63
            let litres = isCommute ? 0.88 + Double(day % 3) * 0.04 : 3.3
            result.append(Trip(vehicleID: vehicleID,
                               startedAt: start,
                               endedAt: start.addingTimeInterval(minutes * 60),
                               endReason: .stoppedMoving,
                               distanceMetres: distance,
                               movingDurationSeconds: minutes * 60 * 0.8,
                               idleDurationSeconds: minutes * 60 * 0.2,
                               elevationGainMetres: isCommute ? 62 : 410,
                               elevationLossMetres: isCommute ? 58 : 395,
                               maximumAltitudeMetres: isCommute ? 940 : 1_320,
                               minimumAltitudeMetres: 880,
                               maximumSpeedKmh: isCommute ? 64 : 98,
                               averageMovingSpeedKmh: isCommute ? 26 : 62,
                               fuelUsedLitres: .estimated(litres, basis: "Integrated from the fuel rate your vehicle reported during the drive."),
                               startLatitude: 12.9010, startLongitude: 77.6010,
                               endLatitude: isCommute ? 12.9700 : 13.3400,
                               endLongitude: isCommute ? 77.6400 : 77.1000,
                               events: day == 0 ? [
                                   TripEvent(kind: .longIdle, timestamp: start.addingTimeInterval(1_200),
                                             severity: .watch, note: "Stationary with the engine running for about 6 minutes.")
                               ] : [],
                               telemetrySampleCount: 340,
                               peakCoolantTemperatureC: isCommute ? 94 : 99,
                               averageEngineLoadPercent: isCommute ? 38 : 52,
                               minimumControlModuleVoltage: 12.4))
        }
        return result
    }

    /// Battery voltage drifting down over a month — the case the battery insight exists for.
    static var baselineAggregates: [BaselineDailyAggregate] {
        var aggregates: [BaselineDailyAggregate] = []
        for daysAgo in 0..<30 {
            let day = now.addingTimeInterval(-Double(daysAgo) * 86_400)
            BaselineEngine.accumulate(into: &aggregates,
                                      key: BaselineKey(metric: .controlModuleVoltageV, context: .engineOff),
                                      value: 12.20 + Double(daysAgo) * 0.011, at: day)
            BaselineEngine.accumulate(into: &aggregates,
                                      key: BaselineKey(metric: .controlModuleVoltageV, context: .engineOff),
                                      value: 12.23 + Double(daysAgo) * 0.011, at: day)
            BaselineEngine.accumulate(into: &aggregates,
                                      key: BaselineKey(metric: .coolantTemperatureC, context: .warmedUp),
                                      value: 90 + Double(daysAgo % 5), at: day)
            BaselineEngine.accumulate(into: &aggregates,
                                      key: BaselineKey(metric: .engineLoadPercent, context: .cruising),
                                      value: 36 + Double(daysAgo % 7), at: day)
        }
        return aggregates
    }

    static var baselines: [BaselineKey: MetricBaseline] {
        BaselineEngine.buildAll(from: baselineAggregates, now: now)
    }

    static var maintenanceItems: [MaintenanceItem] {
        [
            MaintenanceItem(vehicleID: vehicleID, kind: .periodicService,
                            intervalDistanceKm: 15_000, intervalMonths: 12,
                            lastDoneDate: now.addingTimeInterval(-331 * 86_400),
                            lastDoneOdometerKm: 30_000,
                            source: .publishedSpecification),
            MaintenanceItem(vehicleID: vehicleID, kind: .tyreRotation,
                            intervalDistanceKm: 10_000,
                            lastDoneOdometerKm: 38_000,
                            source: .genericDefault)
        ]
    }

    static var documents: [DocumentRecord] {
        [
            DocumentRecord(vehicleID: vehicleID, kind: .insurance,
                           title: "Insurance", provider: "Demo Insurer",
                           expiryDate: now.addingTimeInterval(38 * 86_400)),
            DocumentRecord(vehicleID: vehicleID, kind: .pollutionCertificate,
                           title: "PUC certificate",
                           expiryDate: now.addingTimeInterval(120 * 86_400))
        ]
    }

    static var weather: WeatherSnapshot {
        WeatherSnapshot(timestamp: now, condition: .partlyCloudy, temperatureC: 29,
                        apparentTemperatureC: 31,
                        precipitationIntensityMillimetresPerHour: 0,
                        precipitationChance: 0.35,
                        windSpeedKmh: 14, visibilityMetres: 12_000, humidityFraction: 0.6)
    }

    static var routeWeather: [RouteWeatherPoint] {
        MockWeatherProvider(scenario: .rainAhead, now: { now })
            .routeWeather(distances: [5_000, 12_000, 22_000, 30_000, 45_000])
    }

    static var terrainFeature: TerrainFeature? {
        TerrainAnalyser.mostRelevantFeature(in: (0..<60).map { index in
            ElevationPoint(distanceMetres: Double(index) * 250,
                           altitudeMetres: 880 + max(0, Double(index) - 32) * 13.75)
        })
    }

    /// A full context, so previews render insights produced by the real rules.
    static var insightContext: InsightContext {
        InsightContext(now: now,
                       vehicle: vehicle,
                       profile: profile,
                       isAdapterConnected: true,
                       telemetry: telemetry,
                       capabilities: capabilities,
                       currentTrip: nil,
                       recentTrips: trips,
                       baselines: baselines,
                       gradient: GradientEstimate(percent: 5.4, overDistanceMetres: 240,
                                                  altitudeChangeMetres: 13, confidence: 0.82),
                       terrainFeature: terrainFeature,
                       currentWeather: weather,
                       weatherChanges: RouteWeatherAnalyser.changes(current: weather, along: routeWeather),
                       troubleCodes: [],
                       maintenanceStatuses: MaintenanceEngine.statuses(for: maintenanceItems,
                                                                       currentOdometerKm: 43_880,
                                                                       now: now),
                       documents: documents,
                       fuelStatus: fuelStatus,
                       dieselAssessment: DieselGuardian.assess(trips: trips, profile: profile, now: now),
                       isDriving: false)
    }

    static var insights: [DriveInsight] {
        InsightEngine().evaluate(insightContext)
    }

    static var health: VehicleHealthReport {
        VehicleHealthEvaluator.evaluate(insightContext)
    }

    static var copilotSnapshot: VehicleContextSnapshot {
        CopilotContextBuilder.build(from: insightContext, health: health, insights: insights)
    }

    /// An in-memory container seeded with the demo vehicle, for previews.
    @MainActor
    static func previewContainer() -> ModelContainer {
        let schema = Schema(DriveLayerSchema.models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        guard let container = try? ModelContainer(for: schema, configurations: [configuration]) else {
            fatalError("Could not build the preview container")
        }
        let context = ModelContext(container)
        if let record = try? StoredVehicle(vehicle: vehicle) { context.insert(record) }
        for trip in trips {
            if let record = try? StoredTrip(trip: trip) { context.insert(record) }
        }
        for item in maintenanceItems {
            if let record = try? StoredMaintenanceItem(item: item) { context.insert(record) }
        }
        for document in documents {
            if let record = try? StoredDocument(document: document) { context.insert(record) }
        }
        for aggregate in baselineAggregates {
            context.insert(StoredBaselineAggregate(vehicleID: vehicleID, aggregate: aggregate))
        }
        try? context.save()
        return container
    }
}
