import Foundation

/// What the 12V system is doing, from control module voltage.
///
/// The logic here is not new — `VehicleHealthEvaluator.battery` already did it, and did it
/// well: thresholds from the vehicle profile per engine condition, comparison against the
/// learned baseline, and a downward trend raised as a watch. It has been lifted out so both
/// the health view and the Hyperion assessment read the same implementation.
///
/// That mattered more than tidiness. The pattern this project has already been bitten by is
/// two subsystems thresholding the same metric independently — `EngineTemperatureRule` still
/// does its own coolant comparison alongside `EngineThermalModel` — and the failure mode is
/// two screens disagreeing about the same car.
struct BatteryAssessment: Sendable, Equatable {
    var status: SemanticStatus
    var headline: String
    var detail: String?
    var dataPoints: [InsightSourceDatum]
    var confidence: InsightConfidence
    /// Set when there is no voltage to judge, so a caller can explain rather than blank.
    var unavailability: UnavailabilityReason?

    var isAvailable: Bool { unavailability == nil }
}

enum BatteryIntelligence {

    /// A fall of at least this much across the baseline window counts as a trend.
    ///
    /// Inherited from the health evaluator rather than re-chosen, so lifting the logic out
    /// did not quietly change what the app reports.
    static let trendWatchThresholdV: Double = -0.2

    /// - Parameters:
    ///   - isEngineRunning: nil when unknown. Treated as running, because charging voltage
    ///     is the common case while an adapter is connected and judging a charging voltage
    ///     against resting thresholds would report a healthy car as over-voltage.
    ///   - baseline: this car's learned voltage, ideally in the engine-off context. Resting
    ///     and charging voltage are different measurements and comparing one against the
    ///     other says nothing.
    static func assess(voltage: Provenanced<Double>,
                       isEngineRunning: Bool?,
                       baseline: MetricBaseline?,
                       profile: VehicleProfile?,
                       isAdapterConnected: Bool = true) -> BatteryAssessment {
        guard let value = voltage.value else {
            return BatteryAssessment(
                status: .unknown,
                headline: isAdapterConnected
                    ? "This vehicle doesn't report system voltage"
                    : "Connect an adapter to see battery voltage",
                detail: nil,
                dataPoints: [],
                confidence: .low,
                unavailability: isAdapterConnected
                    ? .pidNotSupportedByVehicle("Control module voltage")
                    : .obdNotConnected)
        }

        let condition: OperatingCondition = isEngineRunning == false ? .engineOff : .engineRunning
        var status = profile?.operatingRange(for: .controlModuleVoltageV, condition: condition)?
            .status(for: value) ?? .unknown
        var points: [InsightSourceDatum] = [
            InsightSourceDatum(label: "Voltage",
                               formattedValue: String(format: "%.2f V", value),
                               provenance: voltage.provenance)
        ]
        var detail: String?

        if let baseline, baseline.isEstablished {
            points.append(.measured("Your usual", String(format: "%.2f V", baseline.median)))
            if let trend = baseline.trendOverWindow, trend <= trendWatchThresholdV {
                status = max(status, .watch)
                detail = String(format: "Readings have been trending about %.2f V lower over %d days. "
                                      + "If that continues, a battery test before a long trip is worth having.",
                                trend, baseline.windowDays)
                points.append(.estimated("Trend", String(format: "%.2f V / %d days", trend, baseline.windowDays)))
            }
        }

        return BatteryAssessment(status: status,
                                 headline: headline(for: status),
                                 detail: detail,
                                 dataPoints: points,
                                 // An established baseline is what turns a single reading
                                 // into a trend, so it is what earns the confidence.
                                 confidence: baseline?.isEstablished == true ? .high : .medium,
                                 unavailability: nil)
    }

    /// Deliberately says nothing about battery health as a percentage.
    ///
    /// Generic OBD gives control module voltage, which is not a state of charge and not a
    /// state of health. A number invented from it would be the most confidently wrong thing
    /// in the app.
    private static func headline(for status: SemanticStatus) -> String {
        switch status {
        case .normal: return "Charging and resting voltage look normal"
        case .watch: return "Voltage is drifting from your usual"
        case .attention, .critical: return "Voltage is outside the normal band"
        case .unknown: return "Not enough information to judge"
        }
    }
}
