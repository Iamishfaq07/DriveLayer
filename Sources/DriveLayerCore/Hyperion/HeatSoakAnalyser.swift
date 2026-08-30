import Foundation

/// What the intake air temperature is doing relative to the air outside.
///
/// On a turbocharged engine sitting in traffic, intake temperature climbs well above
/// ambient: the engine bay is hot, there is no airflow through the intercooler, and heat
/// migrates into the intake. Then it falls again as the car moves. That is the system
/// working, not a fault.
///
/// So the point of this file is as much about *not* raising an alarm as raising one. A
/// 25 °C rise over ambient after ten minutes of crawling is normal and DriveLayer should
/// say so plainly, because a driver who sees a big number and no explanation invents a
/// worse story than the truth.
enum HeatSoakPhase: String, Codable, CaseIterable, Sendable {
    /// Intake close to ambient: nothing to discuss.
    case normal
    /// Well above ambient and still climbing.
    case soaking
    /// Above ambient but falling as airflow increases.
    case recovering
    /// No intake or ambient reading.
    case unknown

    var displayName: String {
        switch self {
        case .normal: return "Normal"
        case .soaking: return "Heat soak"
        case .recovering: return "Cooling"
        case .unknown: return "Unknown"
        }
    }
}

struct HeatSoakAssessment: Sendable, Equatable {
    var phase: HeatSoakPhase
    var intakeC: Provenanced<Double>
    var ambientC: Provenanced<Double>
    /// Intake minus ambient. The number that actually means something.
    var deltaC: Provenanced<Double>
    var status: SemanticStatus
    var headline: String
    var detail: String
    var comparison: String?
    var confidence: InsightConfidence
    var dataPoints: [InsightSourceDatum]

    static let unknown = HeatSoakAssessment(
        phase: .unknown,
        intakeC: .unavailable(),
        ambientC: .unavailable(),
        deltaC: .unavailable(),
        status: .unknown,
        headline: "Intake temperature unavailable",
        detail: "This vehicle isn't reporting both intake and ambient air temperature, so "
              + "DriveLayer can't tell how much heat the intake is picking up.",
        comparison: nil,
        confidence: .low,
        dataPoints: []
    )
}

enum HeatSoakAnalyser {

    /// Below this, intake and ambient are close enough that there is nothing to say.
    static let normalDeltaC: Double = 12
    /// Above this the intake is meaningfully hotter than the air outside.
    static let elevatedDeltaC: Double = 25
    /// Speed above which there is real airflow through the intercooler.
    static let airflowSpeedKmh: Double = 35
    /// A fall of at least this much since the peak counts as recovering.
    static let recoveryDeltaC: Double = 3

    /// Assesses intake temperature against ambient.
    ///
    /// - Parameters:
    ///   - peakDeltaC: the highest delta seen recently, so a fall can be recognised.
    ///   - baseline: this car's learned delta for comparable conditions, if any.
    static func assess(intakeC: Provenanced<Double>,
                       ambientC: Provenanced<Double>,
                       speedKmh: Double?,
                       idleSeconds: TimeInterval?,
                       peakDeltaC: Double?,
                       baseline: MetricBaseline?) -> HeatSoakAssessment {
        guard let intake = intakeC.value, let ambient = ambientC.value else {
            return .unknown
        }

        let delta = intake - ambient
        let hasAirflow = (speedKmh ?? 0) >= airflowSpeedKmh
        let isFalling = peakDeltaC.map { delta <= $0 - recoveryDeltaC } ?? false

        let phase: HeatSoakPhase
        if delta < normalDeltaC {
            phase = .normal
        } else if isFalling || (hasAirflow && delta < elevatedDeltaC) {
            phase = .recovering
        } else if delta >= elevatedDeltaC {
            phase = .soaking
        } else {
            phase = .normal
        }

        var points: [InsightSourceDatum] = [
            .measured("Intake", String(format: "%.0f °C", intake)),
            .measured("Ambient", String(format: "%.0f °C", ambient)),
            .estimated("Above ambient", String(format: "%+.0f °C", delta))
        ]
        if let speedKmh {
            points.append(.measured("Speed", String(format: "%.0f km/h", speedKmh)))
        }

        return HeatSoakAssessment(
            phase: phase,
            intakeC: intakeC,
            ambientC: ambientC,
            // Estimated, not measured: it is a subtraction of two measurements, and the
            // distinction is the whole provenance model.
            deltaC: .estimated(delta, basis: "Intake air temperature minus ambient air temperature."),
            // Never worse than a watch. Heat soak is a normal operating condition, and
            // this project does not manufacture alarm out of physics.
            status: phase == .soaking ? .watch : .normal,
            headline: headline(for: phase),
            detail: describe(phase: phase,
                             delta: delta,
                             hasAirflow: hasAirflow,
                             idleSeconds: idleSeconds),
            comparison: compare(delta: delta, baseline: baseline),
            confidence: baseline?.isEstablished == true ? .high : .medium,
            dataPoints: points
        )
    }

    private static func headline(for phase: HeatSoakPhase) -> String {
        switch phase {
        case .normal: return "INTAKE NORMAL"
        case .soaking: return "HEAT SOAK"
        case .recovering: return "INTAKE COOLING"
        case .unknown: return "INTAKE UNAVAILABLE"
        }
    }

    private static func describe(phase: HeatSoakPhase,
                                 delta: Double,
                                 hasAirflow: Bool,
                                 idleSeconds: TimeInterval?) -> String {
        let amount = String(format: "%.0f °C", delta)
        switch phase {
        case .normal:
            // The reason is only offered when it is actually the reason. Sitting still
            // with a cool intake is equally normal, and telling a stationary driver that
            // air is moving through their engine bay is a small lie that costs trust.
            let text = "Intake air is within \(amount) of the air outside, which is what "
            return hasAirflow ? text + "it should be with air moving through the engine bay."
                              : text + "it should be."
        case .soaking:
            var text = "Intake air is about \(amount) hotter than the air outside"
            if let idleSeconds, idleSeconds > 120 {
                text += String(format: ", after roughly %.0f minutes of very slow going", idleSeconds / 60)
            }
            text += ". That is what a turbocharged engine does in traffic: the engine bay "
                  + "is hot and there is no airflow through the intercooler to carry it away. "
                  + "It falls again once you are moving."
            return text
        case .recovering:
            var text = "Intake air is \(amount) above ambient and falling"
            text += hasAirflow ? " as airflow increases." : "."
            return text
        case .unknown:
            return HeatSoakAssessment.unknown.detail
        }
    }

    private static func compare(delta: Double, baseline: MetricBaseline?) -> String? {
        guard let baseline, baseline.isEstablished else { return nil }
        let comparison = baseline.delta(from: delta)
        guard comparison.isOutsideUsualRange else { return nil }
        let direction = comparison.absolute > 0 ? "higher" : "lower"
        return String(format: "This is %.0f °C %@ than your usual intake-to-ambient difference "
                            + "in comparable conditions. Worth noting, not worth acting on by itself.",
                      abs(comparison.absolute), direction)
    }

    /// Tracks the peak delta of a drive so recovery can be recognised.
    ///
    /// Decays rather than latching: a peak from an hour ago says nothing about now, and a
    /// latched maximum would report "cooling" for the rest of a long drive.
    static func updatedPeak(current: Double?, delta: Double, decayPerSample: Double = 0.05) -> Double {
        guard let current else { return delta }
        if delta >= current { return delta }
        return max(delta, current - decayPerSample)
    }
}
