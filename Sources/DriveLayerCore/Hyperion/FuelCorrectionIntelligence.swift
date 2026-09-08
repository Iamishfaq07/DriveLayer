import Foundation

struct FuelCorrectionAssessment: Sendable, Equatable {
    var status: SemanticStatus
    var headline: String
    var detail: String
    var comparison: String?
    var confidence: InsightConfidence
    var dataPoints: [InsightSourceDatum]
}

/// Interprets fuel trims only after the ECU and engine context make them meaningful.
enum FuelCorrectionIntelligence {
    static func assess(shortTerm: Provenanced<Double>,
                       longTerm: Provenanced<Double>,
                       fuelSystem: FuelSystemStatus,
                       isWarmedCruise: Bool,
                       shortTermBaseline: MetricBaseline?,
                       longTermBaseline: MetricBaseline?) -> FuelCorrectionAssessment? {
        guard fuelSystem.allowsFuelTrimComparison, isWarmedCruise else { return nil }
        let readings: [(String, Provenanced<Double>, MetricBaseline?)] = [
            ("Short-term correction", shortTerm, shortTermBaseline),
            ("Long-term correction", longTerm, longTermBaseline)
        ].filter { $0.1.value != nil }
        guard !readings.isEmpty else { return nil }

        let points = readings.compactMap { label, reading, baseline -> [InsightSourceDatum]? in
            guard let value = reading.value else { return nil }
            var result = [InsightSourceDatum(label: label,
                                             formattedValue: String(format: "%+.1f%%", value),
                                             provenance: reading.provenance)]
            if let baseline, baseline.isEstablished {
                result.append(.learned("Usual \(label.lowercased())",
                                       String(format: "%+.1f to %+.1f%%",
                                              baseline.percentile10, baseline.percentile90)))
            }
            return result
        }.flatMap { $0 }

        let significant = readings.compactMap { label, reading, baseline -> (String, BaselineDelta)? in
            guard let value = reading.value, let baseline else { return nil }
            let delta = baseline.delta(from: value)
            return delta.isSignificant ? (label, delta) : nil
        }
        if let finding = significant.first {
            return FuelCorrectionAssessment(
                status: .watch,
                headline: "Fuel correction is outside your usual range",
                detail: "The ECU is in closed loop and the engine is warm at steady load. This is a trend signal, not a diagnosis of a failed part.",
                comparison: "\(finding.0) is \(finding.1.comparisonPhrase) on comparable warmed cruises.",
                confidence: .medium,
                dataPoints: points + [.measured("Fuel loop", fuelSystem.displayName)]
            )
        }

        let hasEstablishedBaseline = readings.contains { $0.2?.isEstablished == true }
        return FuelCorrectionAssessment(
            status: .normal,
            headline: hasEstablishedBaseline ? "Fuel correction is in your usual range" : "Learning fuel correction",
            detail: hasEstablishedBaseline
                ? "Fuel correction is within the range learned during comparable warmed cruises."
                : "DriveLayer needs more warmed, steady-driving observations before it can compare fuel correction.",
            comparison: nil,
            confidence: hasEstablishedBaseline ? .high : .low,
            dataPoints: points + [.measured("Fuel loop", fuelSystem.displayName)]
        )
    }
}
