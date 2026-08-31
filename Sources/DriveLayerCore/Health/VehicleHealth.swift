import Foundation

/// One system in the health view. Systems, not sensors: a driver wants to know the
/// engine is fine, not to read nine numbers and work it out.
struct VehicleHealthSystem: Sendable, Equatable, Identifiable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case engine, battery, fuelSystem, diagnostics, dieselUsage, maintenance

        var displayName: String {
            switch self {
            case .engine: return "Engine"
            case .battery: return "Battery"
            case .fuelSystem: return "Fuel system"
            case .diagnostics: return "Diagnostics"
            case .dieselUsage: return "Diesel usage"
            case .maintenance: return "Maintenance"
            }
        }

        var symbolName: String {
            switch self {
            case .engine: return "engine.combustion"
            case .battery: return "minus.plus.batteryblock"
            case .fuelSystem: return "fuelpump"
            case .diagnostics: return "stethoscope"
            case .dieselUsage: return "smoke"
            case .maintenance: return "wrench.and.screwdriver"
            }
        }
    }

    var id: String { kind.rawValue }
    var kind: Kind
    var status: SemanticStatus
    /// One line, in plain language.
    var headline: String
    var detail: String?
    var dataPoints: [InsightSourceDatum]
    /// Set when the status is `.unknown` for a reason the driver can act on.
    var unavailability: UnavailabilityReason?
}

struct VehicleHealthReport: Sendable, Equatable {
    var overall: SemanticStatus
    var systems: [VehicleHealthSystem]
    var generatedAt: Date
    /// True when at least one system could not be assessed.
    var isLimitedByMissingData: Bool

    var headline: String {
        switch overall {
        case .normal: return "Healthy"
        case .watch: return "Watch"
        case .attention: return "Attention"
        case .critical: return "Attention needed"
        case .unknown: return "Not enough data"
        }
    }

    func system(_ kind: VehicleHealthSystem.Kind) -> VehicleHealthSystem? {
        systems.first { $0.kind == kind }
    }
}

/// Rolls telemetry, baselines, codes and maintenance up into a handful of systems.
enum VehicleHealthEvaluator {

    static func evaluate(_ context: InsightContext) -> VehicleHealthReport {
        var systems: [VehicleHealthSystem] = [
            engine(context),
            battery(context),
            fuelSystem(context),
            diagnostics(context)
        ]
        if let diesel = dieselUsage(context) { systems.append(diesel) }
        systems.append(maintenance(context))

        // An unknown system does not make the car unhealthy, but it does mean the
        // overall verdict is qualified rather than a confident "healthy".
        let assessed = systems.map(\.status).filter { $0 != .unknown }
        let overall = assessed.isEmpty ? .unknown : SemanticStatus.rollUp(assessed)

        return VehicleHealthReport(overall: overall,
                                   systems: systems,
                                   generatedAt: context.now,
                                   isLimitedByMissingData: systems.contains { $0.status == .unknown })
    }

    private static func engine(_ context: InsightContext) -> VehicleHealthSystem {
        guard context.isAdapterConnected else {
            return VehicleHealthSystem(kind: .engine, status: .unknown,
                                       headline: "Connect an adapter to see engine data",
                                       detail: nil, dataPoints: [],
                                       unavailability: .obdNotConnected)
        }
        guard let coolant = context.value(.coolantTemperatureC, freshWithin: 300) else {
            return VehicleHealthSystem(kind: .engine, status: .unknown,
                                       headline: "This vehicle doesn't report coolant temperature",
                                       detail: nil, dataPoints: [],
                                       unavailability: .pidNotSupportedByVehicle("Coolant temperature"))
        }

        let range = context.profile?.operatingRange(for: .coolantTemperatureC, condition: .warmedUp)
        let status = range?.status(for: coolant) ?? .unknown
        var points: [InsightSourceDatum] = [.measured("Coolant", String(format: "%.0f °C", coolant))]
        if let load = context.value(.engineLoadPercent, freshWithin: 60) {
            points.append(.measured("Engine load", String(format: "%.0f%%", load)))
        }

        let headline: String
        switch status {
        case .normal: headline = "Operating temperature is normal"
        case .watch: headline = "Slightly outside the usual band"
        case .attention: headline = "Running hotter than it should"
        case .critical: headline = "Temperature is too high"
        case .unknown: headline = "Not enough information to judge"
        }

        return VehicleHealthSystem(kind: .engine, status: status, headline: headline,
                                   detail: nil, dataPoints: points, unavailability: nil)
    }

    /// Delegates to `BatteryIntelligence`, which is the same logic this function used to
    /// hold inline. Moved so the Hyperion assessment and this view cannot drift into
    /// disagreeing about the same car -- the failure mode this project already has an
    /// example of, in coolant.
    private static func battery(_ context: InsightContext) -> VehicleHealthSystem {
        let voltage = context.value(.controlModuleVoltageV, freshWithin: 600)
        let assessment = BatteryIntelligence.assess(
            voltage: voltage.map { .measured($0, at: context.now) } ?? .unavailable(),
            isEngineRunning: context.telemetry?.isEngineRunning(now: context.now),
            baseline: context.bestBaseline(.controlModuleVoltageV, preferring: .engineOff),
            profile: context.profile,
            isAdapterConnected: context.isAdapterConnected)

        return VehicleHealthSystem(kind: .battery,
                                   status: assessment.status,
                                   headline: assessment.headline,
                                   detail: assessment.detail,
                                   dataPoints: assessment.dataPoints,
                                   unavailability: assessment.unavailability)
    }

    private static func fuelSystem(_ context: InsightContext) -> VehicleHealthSystem {
        guard let status = context.fuelStatus, let level = status.levelPercent.value else {
            return VehicleHealthSystem(kind: .fuelSystem, status: .unknown,
                                       headline: context.isAdapterConnected
                                           ? "This vehicle doesn't report tank level"
                                           : "Connect an adapter to see fuel level",
                                       detail: nil, dataPoints: [],
                                       unavailability: context.isAdapterConnected
                                           ? .pidNotSupportedByVehicle("Fuel tank level")
                                           : .obdNotConnected)
        }
        var points: [InsightSourceDatum] = [
            InsightSourceDatum(label: "Tank level", formattedValue: String(format: "%.0f%%", level),
                               provenance: status.levelPercent.provenance)
        ]
        if let range = status.estimatedRangeKm.value {
            points.append(.estimated("Estimated range", String(format: "%.0f km", range)))
        }
        let semantic: SemanticStatus = status.isLow ? .watch : .normal
        return VehicleHealthSystem(kind: .fuelSystem,
                                   status: semantic,
                                   headline: status.isLow ? "Running low" : "Normal",
                                   detail: nil, dataPoints: points, unavailability: nil)
    }

    private static func diagnostics(_ context: InsightContext) -> VehicleHealthSystem {
        guard context.isAdapterConnected else {
            return VehicleHealthSystem(kind: .diagnostics, status: .unknown,
                                       headline: "Connect an adapter to read trouble codes",
                                       detail: nil, dataPoints: [], unavailability: .obdNotConnected)
        }
        guard !context.troubleCodes.isEmpty else {
            return VehicleHealthSystem(kind: .diagnostics, status: .normal,
                                       headline: "No active trouble codes",
                                       detail: nil, dataPoints: [], unavailability: nil)
        }
        let explanations = context.troubleCodes.map { DTCCatalog.explanation(for: $0.code) }
        let worst = explanations.map(\.seriousness.status).max() ?? .watch
        let count = context.troubleCodes.count
        return VehicleHealthSystem(
            kind: .diagnostics,
            status: worst,
            headline: "\(count) code\(count == 1 ? "" : "s") stored",
            detail: context.troubleCodes.map(\.code).joined(separator: ", "),
            dataPoints: context.troubleCodes.prefix(3).map {
                .measured($0.code, $0.status.displayName)
            },
            unavailability: nil
        )
    }

    private static func dieselUsage(_ context: InsightContext) -> VehicleHealthSystem? {
        guard let assessment = context.dieselAssessment, assessment.isApplicable else { return nil }
        var points: [InsightSourceDatum] = []
        if let fraction = assessment.shortTripFraction.value {
            points.append(InsightSourceDatum(label: "Short drives",
                                             formattedValue: "\(Int((fraction * 100).rounded()))%",
                                             provenance: assessment.shortTripFraction.provenance))
        }
        if let warmUp = assessment.warmUpCompletionRate.value {
            points.append(InsightSourceDatum(label: "Warmed up",
                                             formattedValue: "\(Int((warmUp * 100).rounded()))% of drives",
                                             provenance: assessment.warmUpCompletionRate.provenance))
        }
        return VehicleHealthSystem(kind: .dieselUsage,
                                   status: assessment.status,
                                   headline: assessment.headline,
                                   detail: assessment.explanation,
                                   dataPoints: points,
                                   unavailability: nil)
    }

    private static func maintenance(_ context: InsightContext) -> VehicleHealthSystem {
        guard !context.maintenanceStatuses.isEmpty else {
            return VehicleHealthSystem(kind: .maintenance, status: .unknown,
                                       headline: "No maintenance items set up yet",
                                       detail: nil, dataPoints: [], unavailability: nil)
        }
        let assessable = context.maintenanceStatuses.filter { $0.status != .unknown }
        guard !assessable.isEmpty else {
            return VehicleHealthSystem(kind: .maintenance, status: .unknown,
                                       headline: "Add your last service to track what's due",
                                       detail: nil, dataPoints: [], unavailability: nil)
        }
        let worst = SemanticStatus.rollUp(assessable.map(\.status))
        let next = assessable.first
        return VehicleHealthSystem(kind: .maintenance,
                                   status: worst,
                                   headline: next.map { "\($0.item.name): \($0.summary)" } ?? "Nothing due",
                                   detail: nil,
                                   dataPoints: [],
                                   unavailability: nil)
    }
}
