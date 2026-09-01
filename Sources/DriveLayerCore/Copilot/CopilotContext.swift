import Foundation

/// The structured summary the copilot reasons over.
///
/// This type exists to enforce a rule: no raw telemetry stream, no route, no
/// coordinates, no registration number and no VIN ever go to a language model. A
/// snapshot is small, summarised and reviewable — a few dozen fields a person could
/// read in full before they were sent anywhere.
struct VehicleContextSnapshot: Sendable, Equatable {

    struct VehicleSummary: Sendable, Equatable {
        var nickname: String
        var profileName: String
        var fuelType: String
        var capabilityLevel: String
        var profileTier: String
        var odometerKm: Double?
    }

    struct HealthSummary: Sendable, Equatable {
        var overall: String
        var systems: [String: String]
        var isLimitedByMissingData: Bool
    }

    struct TripSummary: Sendable, Equatable {
        var startedAt: Date
        var distanceKm: Double
        var durationMinutes: Double
        var idleMinutes: Double
        var economyKmPerLitre: Double?
        var fuelLitres: Double?
        var fuelProvenance: String
        var elevationGainMetres: Double
        var eventCount: Int
    }

    struct PeriodSummary: Sendable, Equatable {
        var label: String
        var tripCount: Int
        var distanceKm: Double
        var shortTripCount: Int
        var medianEconomyKmPerLitre: Double?
        var idleFraction: Double?
    }

    struct FuelSummary: Sendable, Equatable {
        var levelPercent: Double?
        var estimatedRangeKm: Double?
        var economyKmPerLitre: Double?
        var economySource: String
    }

    struct MaintenanceSummary: Sendable, Equatable {
        var nextItemName: String?
        var nextItemSummary: String?
        var overdueCount: Int
        var lastServiceDate: Date?
    }

    struct WeatherSummary: Sendable, Equatable {
        var currentCondition: String?
        var temperatureC: Double?
        var changesAhead: [String]
    }

    struct DieselSummary: Sendable, Equatable {
        var isApplicable: Bool
        var status: String
        var explanation: String
        var shortTripPercent: Double?
        var hasDirectFilterData: Bool
    }

    /// What DriveLayer makes of the Hyperion engine, condensed for a conversation.
    ///
    /// Built from the same `HyperionAssessment` the Hyperion screen and CarPlay read, so
    /// the copilot cannot say something the screen does not. Each area is one sentence -
    /// the headline and, where there is one, the comparison against this car's baseline -
    /// and never a reading. No raw telemetry reaches this type, which is the rule the
    /// whole snapshot exists to enforce.
    struct HyperionSummary: Sendable, Equatable {
        struct Area: Sendable, Equatable {
            var name: String
            var status: String
            var headline: String
            var comparison: String?
            var confidence: String
            /// Set when the area could not be assessed, with the reason. The copilot
            /// says "I can't tell" and why, rather than falling silent about the area.
            var notAssessedReason: String?
        }

        var overall: String
        var summary: String
        var areas: [Area]
        var assessedCount: Int
        var isSilent: Bool

        func area(named name: String) -> Area? {
            areas.first { $0.name.lowercased() == name.lowercased() }
        }
    }

    // Defaults let a caller build a partial snapshot: a phone-only vehicle genuinely
    // has no fuel or health section, and the copilot must handle that.
    var generatedAt: Date
    var vehicle: VehicleSummary?
    var health: HealthSummary?
    var lastTrip: TripSummary?
    var currentTrip: TripSummary?
    var thisWeek: PeriodSummary?
    var thisMonth: PeriodSummary?
    var lastMonth: PeriodSummary?
    var fuel: FuelSummary?
    var maintenance: MaintenanceSummary?
    var weather: WeatherSummary?
    var diesel: DieselSummary?
    var hyperion: HyperionSummary?
    var recentInsights: [String] = []
    var activeTroubleCodes: [String] = []
    var batteryBaselineV: Double?
    var batteryTrendVPerWindow: Double?
    var isDriving: Bool = false
}

/// Builds the snapshot from the same context the insight engine uses.
enum CopilotContextBuilder {

    /// - Parameter hyperion: the current engine assessment. Passed alongside rather than
    ///   through `InsightContext` because it is a product of analysis, not an input to it,
    ///   and the copilot is the third consumer of it after the Hyperion screen and CarPlay.
    static func build(from context: InsightContext,
                      health: VehicleHealthReport?,
                      insights: [DriveInsight],
                      hyperion: HyperionAssessment? = nil,
                      calendar: Calendar = .current) -> VehicleContextSnapshot {

        let vehicleSummary = context.vehicle.map { vehicle in
            VehicleContextSnapshot.VehicleSummary(
                nickname: vehicle.nickname,
                profileName: context.profile?.displayName ?? "Unknown profile",
                fuelType: context.profile?.fuelType.displayName ?? "Unknown",
                capabilityLevel: VehicleCapabilityLevel.current(profile: context.profile,
                                                                isAdapterConnected: context.isAdapterConnected).title,
                profileTier: context.profile?.validationTier.label ?? ProfileValidationTier.generic.label,
                odometerKm: vehicle.odometerKm
            )
        }

        let healthSummary = health.map { report in
            VehicleContextSnapshot.HealthSummary(
                overall: report.headline,
                systems: Dictionary(uniqueKeysWithValues: report.systems.map { ($0.kind.displayName, $0.status.label) }),
                isLimitedByMissingData: report.isLimitedByMissingData
            )
        }

        let completed = context.recentTrips.filter(\.isComplete)
        let lastTrip = completed.max(by: { $0.startedAt < $1.startedAt }).map(summarise)

        let week = completed.within(days: 7, of: context.now, calendar: calendar)
        let month = completed.within(days: 30, of: context.now, calendar: calendar)
        let previousMonth = completed.filter { trip in
            guard let start = calendar.date(byAdding: .day, value: -60, to: context.now),
                  let end = calendar.date(byAdding: .day, value: -30, to: context.now) else { return false }
            return trip.startedAt >= start && trip.startedAt < end
        }

        return VehicleContextSnapshot(
            generatedAt: context.now,
            vehicle: vehicleSummary,
            health: healthSummary,
            lastTrip: lastTrip,
            currentTrip: context.currentTrip.map(summarise),
            thisWeek: period("this week", trips: week),
            thisMonth: period("the last 30 days", trips: month),
            lastMonth: period("the 30 days before that", trips: previousMonth),
            fuel: context.fuelStatus.map { status in
                VehicleContextSnapshot.FuelSummary(
                    levelPercent: status.levelPercent.value,
                    estimatedRangeKm: status.estimatedRangeKm.value,
                    economyKmPerLitre: status.economyKmPerLitre,
                    economySource: status.economySource.explanation
                )
            },
            maintenance: maintenanceSummary(context),
            weather: VehicleContextSnapshot.WeatherSummary(
                currentCondition: context.currentWeather?.condition.displayName,
                temperatureC: context.currentWeather?.temperatureC,
                changesAhead: context.weatherChanges.map { "\($0.headline): \($0.detail)" }
            ),
            diesel: context.dieselAssessment.map { assessment in
                VehicleContextSnapshot.DieselSummary(
                    isApplicable: assessment.isApplicable,
                    status: assessment.status.label,
                    explanation: assessment.explanation,
                    shortTripPercent: assessment.shortTripFraction.value.map { $0 * 100 },
                    hasDirectFilterData: assessment.dpf.hasAnyValue
                )
            },
            hyperion: hyperion.map(summarise),
            recentInsights: insights.prefix(5).map { "\($0.title): \($0.summary)" },
            activeTroubleCodes: context.troubleCodes.map(\.code),
            batteryBaselineV: context.bestBaseline(.controlModuleVoltageV, preferring: .engineOff)?.median,
            batteryTrendVPerWindow: context.bestBaseline(.controlModuleVoltageV, preferring: .engineOff)?.trendOverWindow,
            isDriving: context.isDriving
        )
    }

    /// Condenses the assessment to sentences. Data points are deliberately dropped: the
    /// snapshot carries judgements, and the readings behind them stay on the screen.
    static func summarise(_ assessment: HyperionAssessment) -> VehicleContextSnapshot.HyperionSummary {
        VehicleContextSnapshot.HyperionSummary(
            overall: assessment.overall.label,
            summary: assessment.summary,
            areas: assessment.sections.map { section in
                .init(name: section.area.displayName,
                      status: section.status.label,
                      headline: section.headline,
                      comparison: section.comparison,
                      confidence: section.confidence.displayName,
                      notAssessedReason: section.notAssessedReason)
            },
            assessedCount: assessment.assessedSections.count,
            isSilent: assessment.isSilent
        )
    }

    private static func summarise(_ trip: Trip) -> VehicleContextSnapshot.TripSummary {
        VehicleContextSnapshot.TripSummary(
            startedAt: trip.startedAt,
            distanceKm: trip.distanceKm,
            durationMinutes: trip.totalDurationSeconds / 60,
            idleMinutes: trip.idleDurationSeconds / 60,
            economyKmPerLitre: trip.economyKmPerLitre,
            fuelLitres: trip.fuelUsedLitres.value,
            fuelProvenance: trip.fuelUsedLitres.provenance.label,
            elevationGainMetres: trip.elevationGainMetres,
            eventCount: trip.events.count
        )
    }

    private static func period(_ label: String, trips: [Trip]) -> VehicleContextSnapshot.PeriodSummary? {
        guard !trips.isEmpty else { return nil }
        let analytics = TripAnalytics.summarise(trips)
        return VehicleContextSnapshot.PeriodSummary(
            label: label,
            tripCount: analytics.tripCount,
            distanceKm: analytics.totalDistanceKm,
            shortTripCount: analytics.shortTripCount,
            medianEconomyKmPerLitre: analytics.medianEconomyKmPerLitre,
            idleFraction: analytics.idleFraction
        )
    }

    private static func maintenanceSummary(_ context: InsightContext) -> VehicleContextSnapshot.MaintenanceSummary? {
        guard !context.maintenanceStatuses.isEmpty else { return nil }
        let next = context.maintenanceStatuses.first { $0.status != .unknown }
        return VehicleContextSnapshot.MaintenanceSummary(
            nextItemName: next?.item.name,
            nextItemSummary: next?.summary,
            overdueCount: context.maintenanceStatuses.filter(\.isOverdue).count,
            lastServiceDate: context.maintenanceStatuses.compactMap { $0.item.lastDoneDate }.max()
        )
    }
}
