import XCTest
@testable import DriveLayerCore

final class BaselineEngineTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let key = BaselineKey(metric: .controlModuleVoltageV, context: .engineOff)

    /// Thirty days of resting voltage drifting slowly downwards.
    private func decliningAggregates() -> [BaselineDailyAggregate] {
        var aggregates: [BaselineDailyAggregate] = []
        for daysAgo in 0..<30 {
            let day = now.addingTimeInterval(-Double(daysAgo) * 86_400)
            let value = 12.20 + Double(daysAgo) * 0.01
            BaselineEngine.accumulate(into: &aggregates, key: key, value: value, at: day)
            BaselineEngine.accumulate(into: &aggregates, key: key, value: value + 0.005, at: day)
        }
        return aggregates
    }

    func testBaselineNeedsEnoughHistoryBeforeItClaimsToKnowNormal() throws {
        var aggregates: [BaselineDailyAggregate] = []
        for daysAgo in 0..<3 {
            BaselineEngine.accumulate(into: &aggregates, key: key, value: 12.5,
                                      at: now.addingTimeInterval(-Double(daysAgo) * 86_400))
        }
        let baseline = try XCTUnwrap(BaselineEngine.build(key: key, from: aggregates, now: now))
        XCTAssertFalse(baseline.isEstablished)
        XCTAssertFalse(baseline.delta(from: 11.0).isSignificant,
                       "without history there is no basis to call anything abnormal")
    }

    func testDetectsASlowDeclineNoSingleReadingWouldShow() throws {
        let baseline = try XCTUnwrap(BaselineEngine.build(key: key, from: decliningAggregates(), now: now))
        XCTAssertTrue(baseline.isEstablished)
        XCTAssertEqual(baseline.dayCount, 30)
        XCTAssertEqual(baseline.observationCount, 60)
        let trend = try XCTUnwrap(baseline.trendOverWindow)
        XCTAssertEqual(trend, -0.30, accuracy: 0.05)
        XCTAssertLessThan(trend, -0.2, "this is the drift the battery insight fires on")
    }

    func testDeltaClassifiesInLineAndOutOfRange() throws {
        let baseline = try XCTUnwrap(BaselineEngine.build(key: key, from: decliningAggregates(), now: now))
        XCTAssertEqual(baseline.delta(from: baseline.median).direction, .inLine)

        let low = baseline.delta(from: 12.0)
        XCTAssertEqual(low.direction, .below)
        XCTAssertTrue(low.isSignificant)
        XCTAssertEqual(low.comparisonPhrase, "lower than your usual range")
    }

    func testOutlierDoesNotMoveTheBaseline() throws {
        var aggregates = decliningAggregates()
        // One day of garbage from a bad adapter.
        BaselineEngine.accumulate(into: &aggregates, key: key, value: 0.0,
                                  at: now.addingTimeInterval(-31 * 3_600))
        let baseline = try XCTUnwrap(BaselineEngine.build(key: key, from: aggregates, now: now))
        XCTAssertEqual(baseline.median, 12.35, accuracy: 0.1)
    }

    func testOtherMetricsAreNotMixedIn() throws {
        var aggregates = decliningAggregates()
        let otherKey = BaselineKey(metric: .coolantTemperatureC, context: .warmedUp)
        BaselineEngine.accumulate(into: &aggregates, key: otherKey, value: 92, at: now)
        let baseline = try XCTUnwrap(BaselineEngine.build(key: key, from: aggregates, now: now))
        XCTAssertLessThan(baseline.median, 13, "coolant readings must not pollute the voltage baseline")
    }

    func testContextClassification() {
        XCTAssertEqual(BaselineEngine.context(speedKmh: 0, engineLoadPercent: 15,
                                              coolantTemperatureC: 90, gradientPercent: 0), .idle)
        XCTAssertEqual(BaselineEngine.context(speedKmh: 0, engineLoadPercent: nil,
                                              coolantTemperatureC: 90, gradientPercent: nil,
                                              isEngineRunning: false), .engineOff,
                       "engine state outranks everything: a resting reading is not an idling one")
        XCTAssertEqual(BaselineEngine.context(speedKmh: 0, engineLoadPercent: nil,
                                              coolantTemperatureC: 30, gradientPercent: nil,
                                              isEngineRunning: false), .engineOff)
        XCTAssertEqual(BaselineEngine.context(speedKmh: 40, engineLoadPercent: 20,
                                              coolantTemperatureC: 40, gradientPercent: 0), .coldEngine)
        XCTAssertEqual(BaselineEngine.context(speedKmh: 55, engineLoadPercent: 75,
                                              coolantTemperatureC: 92, gradientPercent: 6), .climbing)
        XCTAssertEqual(BaselineEngine.context(speedKmh: 95, engineLoadPercent: 38,
                                              coolantTemperatureC: 90, gradientPercent: 0), .cruising)
    }
}

final class FuelIntelligenceTests: XCTestCase {

    private let vehicleID = UUID()
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    func testFullToFullEconomy() throws {
        let entries = [
            FuelEntry(vehicleID: vehicleID, date: start, litres: 45, odometerKm: 10_000, isFullTank: true),
            FuelEntry(vehicleID: vehicleID, date: start.addingTimeInterval(86_400 * 7),
                      litres: 40, pricePerLitre: 90, odometerKm: 10_500, isFullTank: true)
        ]
        let results = FuelCalculations.economyResults(from: entries)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].kilometresPerLitre, 12.5, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(results[0].costPerKilometre), 7.2, accuracy: 0.001)
    }

    func testPartialFillsCountTowardsTheNextFullTank() throws {
        let entries = [
            FuelEntry(vehicleID: vehicleID, date: start, litres: 45, odometerKm: 10_000, isFullTank: true),
            FuelEntry(vehicleID: vehicleID, date: start.addingTimeInterval(86_400 * 3),
                      litres: 15, odometerKm: 10_200, isFullTank: false),
            FuelEntry(vehicleID: vehicleID, date: start.addingTimeInterval(86_400 * 7),
                      litres: 25, odometerKm: 10_500, isFullTank: true)
        ]
        let results = FuelCalculations.economyResults(from: entries)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].litres, 40, accuracy: 0.001)
        XCTAssertEqual(results[0].kilometresPerLitre, 12.5, accuracy: 0.001)
    }

    func testEntriesWithoutOdometerProduceNoEconomyRatherThanAGuess() {
        let entries = [
            FuelEntry(vehicleID: vehicleID, date: start, litres: 45, isFullTank: true),
            FuelEntry(vehicleID: vehicleID, date: start.addingTimeInterval(86_400), litres: 40, isFullTank: true)
        ]
        XCTAssertTrue(FuelCalculations.economyResults(from: entries).isEmpty)
    }

    func testRangeExcludesTheUnusableBottomOfTheTank() throws {
        let status = FuelIntelligence.status(levelPercent: .measured(50),
                                             tankCapacityLitres: 50,
                                             economy: (12.5, .fullTankHistory))
        XCTAssertEqual(try XCTUnwrap(status.litresRemaining.value), 25, accuracy: 0.001)
        // 25 litres less the 8% reserve, at 12.5 km/L.
        XCTAssertEqual(try XCTUnwrap(status.estimatedRangeKm.value), 262.5, accuracy: 0.1)
        XCTAssertEqual(status.estimatedRangeKm.provenance, .estimated)
    }

    func testRangeIsUnavailableWithoutTankSize() {
        let status = FuelIntelligence.status(levelPercent: .measured(50),
                                             tankCapacityLitres: nil,
                                             economy: (12.5, .recentTrips))
        XCTAssertFalse(status.estimatedRangeKm.isAvailable)
        XCTAssertNotNil(status.litresRemaining.basis, "the UI needs to explain what's missing")
    }

    func testRangeIsUnavailableWithoutAnEconomyFigure() {
        let status = FuelIntelligence.status(levelPercent: .measured(50),
                                             tankCapacityLitres: 50,
                                             economy: nil)
        XCTAssertTrue(status.litresRemaining.isAvailable)
        XCTAssertFalse(status.estimatedRangeKm.isAvailable)
    }

    func testJourneyVerdicts() {
        let status = FuelIntelligence.status(levelPercent: .measured(50),
                                             tankCapacityLitres: 50,
                                             economy: (12.5, .fullTankHistory))
        guard case let .comfortable(reserve) = FuelIntelligence.assessJourney(distanceKm: 150, status: status) else {
            return XCTFail("150 km on 262 km of range is comfortable")
        }
        XCTAssertEqual(reserve, 112.5, accuracy: 0.1)

        guard case .tight = FuelIntelligence.assessJourney(distanceKm: 250, status: status) else {
            return XCTFail("250 km leaves too little margin to call comfortable")
        }
        guard case let .insufficient(shortfall) = FuelIntelligence.assessJourney(distanceKm: 400, status: status) else {
            return XCTFail("400 km is beyond the estimate")
        }
        XCTAssertEqual(shortfall, 137.5, accuracy: 0.1)
        XCTAssertEqual(FuelIntelligence.assessJourney(distanceKm: 100, status: .unknown), .unknown)
    }

    func testJourneyMessageAlwaysSaysEstimated() {
        let status = FuelIntelligence.status(levelPercent: .measured(50),
                                             tankCapacityLitres: 50,
                                             economy: (12.5, .fullTankHistory))
        XCTAssertTrue(FuelIntelligence.journeyMessage(distanceKm: 150, status: status).contains("estimated"))
    }

    func testEconomySourcePrefersFullTankHistoryOverTrips() throws {
        let entries = [
            FuelEntry(vehicleID: vehicleID, date: start, litres: 45, odometerKm: 10_000, isFullTank: true),
            FuelEntry(vehicleID: vehicleID, date: start.addingTimeInterval(86_400 * 7),
                      litres: 40, odometerKm: 10_500, isFullTank: true)
        ]
        let trip = Trip(vehicleID: vehicleID, startedAt: start, endedAt: start.addingTimeInterval(3_600),
                        distanceMetres: 40_000, fuelUsedLitres: .estimated(5))
        let best = try XCTUnwrap(FuelIntelligence.bestEconomy(fuelEntries: entries, recentTrips: [trip]))
        XCTAssertEqual(best.source, .fullTankHistory)
        XCTAssertEqual(best.value, 12.5, accuracy: 0.001)
    }

    func testEconomyIsUnavailableWithNothingToBaseItOn() {
        XCTAssertNil(FuelIntelligence.bestEconomy(fuelEntries: [], recentTrips: []))
    }
}

final class MaintenanceTests: XCTestCase {

    private let vehicleID = UUID()
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testDueByDistanceAndTime() {
        let calendar = Calendar(identifier: .gregorian)
        let lastDone = calendar.date(byAdding: .month, value: -11, to: now)!
        let item = MaintenanceItem(vehicleID: vehicleID, kind: .periodicService,
                                   intervalDistanceKm: 15_000, intervalMonths: 12,
                                   lastDoneDate: lastDone, lastDoneOdometerKm: 30_000)

        let status = MaintenanceEngine.status(for: item, currentOdometerKm: 43_880, now: now, calendar: calendar)
        XCTAssertEqual(try XCTUnwrap(status.remainingKm), 1_120, accuracy: 0.001)
        XCTAssertTrue(abs(try XCTUnwrap(status.remainingDays) - 30) <= 2,
                      "roughly a month of the twelve-month interval is left")
        XCTAssertEqual(status.status, .watch)
        XCTAssertTrue(status.summary.contains("1120 km") || status.summary.contains("1,120 km"))
    }

    func testOverdueIsReportedAsSuch() {
        let item = MaintenanceItem(vehicleID: vehicleID, kind: .periodicService,
                                   intervalDistanceKm: 15_000,
                                   lastDoneOdometerKm: 30_000)
        let status = MaintenanceEngine.status(for: item, currentOdometerKm: 46_000, now: now)
        XCTAssertTrue(status.isOverdue)
        XCTAssertEqual(status.status, .attention)
        XCTAssertTrue(status.summary.lowercased().contains("overdue"))
    }

    func testWithoutOdometerOrHistoryStatusIsUnknownNotNormal() {
        let item = MaintenanceItem(vehicleID: vehicleID, kind: .periodicService, intervalDistanceKm: 15_000)
        let status = MaintenanceEngine.status(for: item, currentOdometerKm: nil, now: now)
        XCTAssertEqual(status.status, .unknown)
        XCTAssertNil(status.remainingKm)
    }

    func testDefaultItemsCarryTheProfilesSpecSource() throws {
        let vehicle = Vehicle(nickname: "Harrier", profileID: VehicleProfileCatalog.harrier2026AdventureXPlusID)
        let items = MaintenanceEngine.defaultItems(for: vehicle,
                                                   profile: VehicleProfileCatalog.harrier2026AdventureXPlus)
        let service = try XCTUnwrap(items.first { $0.kind == .periodicService })
        XCTAssertEqual(service.intervalDistanceKm, 15_000)
        XCTAssertEqual(service.source, .publishedSpecification)

        let airFilter = try XCTUnwrap(items.first { $0.kind == .airFilter })
        XCTAssertEqual(airFilter.source, .genericDefault,
                       "a generic default must not be presented as a manufacturer figure")
    }

    func testMostUrgentItemSortsFirst() {
        let overdue = MaintenanceItem(vehicleID: vehicleID, kind: .engineOil,
                                      intervalDistanceKm: 10_000, lastDoneOdometerKm: 30_000)
        let distant = MaintenanceItem(vehicleID: vehicleID, kind: .brakePads,
                                      intervalDistanceKm: 60_000, lastDoneOdometerKm: 30_000)
        let statuses = MaintenanceEngine.statuses(for: [distant, overdue], currentOdometerKm: 41_000, now: now)
        XCTAssertEqual(statuses.first?.item.kind, .engineOil)
    }

    func testDocumentExpiryEscalates() {
        let calendar = Calendar(identifier: .gregorian)
        func document(daysFromNow: Int) -> DocumentRecord {
            DocumentRecord(kind: .insurance,
                           expiryDate: calendar.date(byAdding: .day, value: daysFromNow, to: now)!)
        }
        XCTAssertEqual(document(daysFromNow: 200).status(now: now, calendar: calendar), .normal)
        XCTAssertEqual(document(daysFromNow: 30).status(now: now, calendar: calendar), .watch)
        XCTAssertEqual(document(daysFromNow: 5).status(now: now, calendar: calendar), .attention)
        XCTAssertEqual(document(daysFromNow: -1).status(now: now, calendar: calendar), .critical)
    }

    func testDocumentWithoutExpiryIsUnknownNotNormal() {
        let document = DocumentRecord(kind: .insurance)
        XCTAssertEqual(document.status(now: now), .unknown)
    }

    func testDocumentNumberIsRedactedInDescriptions() {
        let document = DocumentRecord(kind: .insurance, referenceNumber: "POL123456789")
        XCTAssertFalse(document.redactedDescription.contains("POL123456789"))
        XCTAssertTrue(document.redactedDescription.hasSuffix("6789)"))
    }
}

final class DieselGuardianTests: XCTestCase {

    private let vehicleID = UUID()
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let profile = VehicleProfileCatalog.harrier2026AdventureXPlus

    private func trip(daysAgo: Int, km: Double, minutes: Double, peakCoolant: Double?) -> Trip {
        let start = now.addingTimeInterval(-Double(daysAgo) * 86_400)
        return Trip(vehicleID: vehicleID,
                    startedAt: start,
                    endedAt: start.addingTimeInterval(minutes * 60),
                    endReason: .stoppedMoving,
                    distanceMetres: km * 1_000,
                    peakCoolantTemperatureC: peakCoolant)
    }

    func testNotApplicableToPetrolVehicles() {
        let assessment = DieselGuardian.assess(trips: [], profile: VehicleProfileCatalog.genericPetrol, now: now)
        XCTAssertFalse(assessment.isApplicable)
    }

    func testSaysItIsStillLearningRatherThanJudgingEarly() {
        let trips = [trip(daysAgo: 1, km: 3, minutes: 8, peakCoolant: 58)]
        let assessment = DieselGuardian.assess(trips: trips, profile: profile, now: now)
        XCTAssertEqual(assessment.status, .unknown)
        XCTAssertFalse(assessment.shortTripFraction.isAvailable)
        XCTAssertTrue(assessment.explanation.contains("needs"))
    }

    func testShortColdDrivesRaiseAttention() throws {
        var trips = (1...6).map { trip(daysAgo: $0, km: 4, minutes: 9, peakCoolant: 58) }
        trips += (7...8).map { trip(daysAgo: $0, km: 40, minutes: 45, peakCoolant: 92) }

        let assessment = DieselGuardian.assess(trips: trips, profile: profile, now: now)
        XCTAssertEqual(assessment.status, .attention)
        XCTAssertEqual(try XCTUnwrap(assessment.shortTripFraction.value), 0.75, accuracy: 0.001)
        XCTAssertEqual(assessment.shortTripFraction.provenance, .measured)
        XCTAssertEqual(try XCTUnwrap(assessment.warmUpCompletionRate.value), 0.25, accuracy: 0.001)
        XCTAssertEqual(assessment.warmUpCompletionRate.provenance, .measured)
    }

    func testLongDrivesReadAsNormal() {
        let trips = (1...8).map { trip(daysAgo: $0, km: 45, minutes: 50, peakCoolant: 92) }
        XCTAssertEqual(DieselGuardian.assess(trips: trips, profile: profile, now: now).status, .normal)
    }

    func testWarmUpIsInferredWhenCoolantIsNotReported() throws {
        let trips = (1...8).map { trip(daysAgo: $0, km: 40, minutes: 45, peakCoolant: nil) }
        let assessment = DieselGuardian.assess(trips: trips, profile: profile, now: now)
        XCTAssertEqual(assessment.warmUpCompletionRate.provenance, .inferred,
                       "without coolant data this can only be inferred from duration")
        XCTAssertEqual(try XCTUnwrap(assessment.warmUpCompletionRate.value), 1.0, accuracy: 0.001)
        XCTAssertTrue(try XCTUnwrap(assessment.warmUpCompletionRate.basis).contains("inferred"))
    }

    func testNeverClaimsFilterConditionWithoutFilterData() throws {
        let trips = (1...8).map { trip(daysAgo: $0, km: 4, minutes: 9, peakCoolant: 58) }
        let assessment = DieselGuardian.assess(trips: trips, profile: profile, now: now)
        XCTAssertFalse(assessment.dpf.hasAnyValue)
        XCTAssertFalse(assessment.dpf.sootLoadPercent.isAvailable)
        XCTAssertTrue(assessment.explanation.contains("can't read your particulate filter"))
        let recommendation = try XCTUnwrap(assessment.recommendation)
        XCTAssertTrue(recommendation.contains("owner's manual"),
                      "guidance must point at the manufacturer, not a made-up procedure")
    }

    func testProfileExtensionPointsCarryNoRequests() {
        for capability in profile.manufacturerCapabilities {
            XCTAssertNil(capability.validatedRequest,
                         "an unvalidated capability must never carry a request to send")
            XCTAssertFalse(capability.isUsable)
        }
        XCTAssertTrue(profile.usableManufacturerCapabilities.isEmpty)
    }

    func testUnvalidatedCapabilityCannotSmuggleInARequest() {
        let capability = ManufacturerCapability(id: "test", kind: .dpfSootLoad, displayName: "Soot load",
                                                validation: .observed,
                                                validatedRequest: OBDPID.current(0x22))
        XCTAssertNil(capability.validatedRequest)
    }
}

final class ReminderPlannerTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let calendar = Calendar(identifier: .gregorian)
    private let vehicleID = UUID()

    private func document(kind: DocumentKind, expiresInDays: Int?) -> DocumentRecord {
        DocumentRecord(vehicleID: vehicleID,
                       kind: kind,
                       referenceNumber: "POL9876543210",
                       expiryDate: expiresInDays.flatMap { calendar.date(byAdding: .day, value: $0, to: now) })
    }

    func testSchedulesTheFullLadderBeforeExpiry() {
        let reminders = ReminderPlanner.documentReminders([document(kind: .insurance, expiresInDays: 90)],
                                                          now: now, calendar: calendar)
        XCTAssertEqual(reminders.count, 3, "30 days, 7 days, and the day itself")
        XCTAssertEqual(Set(reminders.map(\.kind)), [.documentExpiry, .documentExpired])
        XCTAssertTrue(reminders.allSatisfy { $0.fireDate > now })
    }

    func testDropsLeadTimesThatHaveAlreadyPassed() {
        let reminders = ReminderPlanner.documentReminders([document(kind: .insurance, expiresInDays: 10)],
                                                          now: now, calendar: calendar)
        // The 30-day lead is in the past; only the 7-day and the day itself remain.
        XCTAssertEqual(reminders.count, 2)
        XCTAssertTrue(reminders.allSatisfy { $0.fireDate > now })
    }

    func testAlreadyExpiredDocumentSchedulesNothing() {
        let reminders = ReminderPlanner.documentReminders([document(kind: .insurance, expiresInDays: -5)],
                                                          now: now, calendar: calendar)
        XCTAssertTrue(reminders.isEmpty, "a reminder that would fire in the past is noise")
    }

    func testDocumentsThatDoNotExpireAreIgnored() {
        let reminders = ReminderPlanner.documentReminders([document(kind: .serviceInvoice, expiresInDays: 40)],
                                                          now: now, calendar: calendar)
        XCTAssertTrue(reminders.isEmpty)
    }

    func testDocumentWithoutAnExpiryDateIsIgnored() {
        let reminders = ReminderPlanner.documentReminders([document(kind: .insurance, expiresInDays: nil)],
                                                          now: now, calendar: calendar)
        XCTAssertTrue(reminders.isEmpty)
    }

    func testReminderCopyNeverLeaksTheReferenceNumber() {
        let reminders = ReminderPlanner.documentReminders([document(kind: .insurance, expiresInDays: 90)],
                                                          now: now, calendar: calendar)
        for reminder in reminders {
            XCTAssertFalse(reminder.body.contains("POL9876543210"),
                           "a lock-screen banner is visible to whoever holds the phone")
            XCTAssertFalse(reminder.title.contains("POL9876543210"))
        }
    }

    func testIdentifiersAreStableSoReschedulingReplaces() {
        let record = document(kind: .insurance, expiresInDays: 90)
        let first = ReminderPlanner.documentReminders([record], now: now, calendar: calendar)
        let second = ReminderPlanner.documentReminders([record],
                                                       now: now.addingTimeInterval(3_600),
                                                       calendar: calendar)
        XCTAssertEqual(Set(first.map(\.id)), Set(second.map(\.id)))
    }

    // MARK: - Maintenance

    private func dueStatus(remainingDays: Int?, remainingKm: Double?) -> MaintenanceDueStatus {
        let item = MaintenanceItem(vehicleID: vehicleID, kind: .periodicService,
                                   intervalDistanceKm: remainingKm == nil ? nil : 15_000,
                                   intervalMonths: remainingDays == nil ? nil : 12,
                                   lastDoneDate: remainingDays == nil ? nil : now,
                                   lastDoneOdometerKm: remainingKm == nil ? nil : 30_000)
        return MaintenanceDueStatus(item: item,
                                    remainingKm: remainingKm,
                                    remainingDays: remainingDays,
                                    status: (remainingDays ?? 1) < 0 ? .attention : .watch)
    }

    func testDistanceOnlyItemsScheduleNothing() {
        let reminders = ReminderPlanner.maintenanceReminders([dueStatus(remainingDays: nil, remainingKm: 400)],
                                                             now: now, calendar: calendar)
        XCTAssertTrue(reminders.isEmpty,
                      "there is no date to fire on, and DriveLayer will not invent one")
    }

    func testDatedItemSchedulesAheadOfTheDueDate() throws {
        let reminders = ReminderPlanner.maintenanceReminders([dueStatus(remainingDays: 30, remainingKm: nil)],
                                                             now: now, calendar: calendar)
        let reminder = try XCTUnwrap(reminders.first)
        XCTAssertEqual(reminder.kind, .maintenanceDue)
        let daysAhead = calendar.dateComponents([.day], from: now, to: reminder.fireDate).day ?? 0
        XCTAssertTrue((22...24).contains(daysAhead), "a week before it is due, got \(daysAhead)")
    }

    func testOverdueItemGetsOneNudgeNotADailyDrumbeat() {
        let reminders = ReminderPlanner.maintenanceReminders([dueStatus(remainingDays: -12, remainingKm: nil)],
                                                             now: now, calendar: calendar)
        XCTAssertEqual(reminders.count, 1)
        XCTAssertEqual(reminders.first?.kind, .maintenanceOverdue)
    }

    func testDistantItemsAreNotScheduledYet() {
        let reminders = ReminderPlanner.maintenanceReminders([dueStatus(remainingDays: 300, remainingKm: nil)],
                                                             now: now, calendar: calendar)
        XCTAssertTrue(reminders.isEmpty)
    }
}
