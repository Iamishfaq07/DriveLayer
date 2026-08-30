import Foundation

/// How much weight a conclusion deserves.
///
/// `DriveInsight` already carries a numeric `confidence`, which is right for ranking and
/// wrong for talking to a driver: nobody wants to be told a finding is 0.62. This is the
/// same quantity in the three bands the UI and the copilot can actually use, and it
/// converts both ways so there is one source of truth rather than two.
///
/// The reason it exists at all is hysteresis. A single abnormal sample must not produce a
/// confident warning, and the way to guarantee that is to make the number of corroborating
/// observations an explicit input to how loudly DriveLayer speaks.
enum InsightConfidence: String, Codable, CaseIterable, Sendable, Comparable {
    case low
    case medium
    case high

    private var rank: Int {
        switch self {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        }
    }

    static func < (lhs: InsightConfidence, rhs: InsightConfidence) -> Bool {
        lhs.rank < rhs.rank
    }

    /// The numeric value `DriveInsight` ranks by.
    var numericValue: Double {
        switch self {
        case .low: return 0.35
        case .medium: return 0.65
        case .high: return 0.9
        }
    }

    init(numericValue: Double) {
        switch numericValue {
        case ..<0.5: self = .low
        case ..<0.8: self = .medium
        default: self = .high
        }
    }

    var displayName: String {
        switch self {
        case .low: return "Low confidence"
        case .medium: return "Moderate confidence"
        case .high: return "High confidence"
        }
    }

    /// Hedging that matches the confidence, so the wording and the number cannot disagree.
    var qualifier: String {
        switch self {
        case .low: return "an early sign, on limited data"
        case .medium: return "a pattern worth watching"
        case .high: return "a consistent pattern"
        }
    }

    /// Whether this is strong enough to interrupt a driver mid-drive.
    ///
    /// Low-confidence findings belong on the Hyperion screen while parked, not on Drive
    /// Mode at 100 km/h. A guess is not worth a glance away from the road.
    var warrantsInterruption: Bool { self == .high }

    // MARK: - Deriving confidence

    /// Confidence from how much corroboration there is.
    ///
    /// - Parameters:
    ///   - observations: how many comparable observations back the finding.
    ///   - required: how many are needed before it is worth saying at all.
    ///   - sensorProvenance: caps the result. An inference cannot be high confidence
    ///     however many times it is repeated, because repeating an inference does not
    ///     turn it into a measurement.
    static func from(observations: Int,
                     required: Int,
                     sensorProvenance: DataProvenance = .measured) -> InsightConfidence {
        let base: InsightConfidence
        switch observations {
        case ..<required: base = .low
        case required..<(required * 3): base = .medium
        default: base = .high
        }
        return min(base, ceiling(for: sensorProvenance))
    }

    /// The most confidence a given kind of data can support.
    static func ceiling(for provenance: DataProvenance) -> InsightConfidence {
        switch provenance {
        case .measured, .userEntered: return .high
        case .estimated: return .medium
        case .inferred: return .medium
        case .unavailable: return .low
        }
    }

    /// The weakest link across several inputs.
    ///
    /// A conclusion is only as good as the worst thing it rests on, so this is a `min`
    /// rather than an average - averaging would let two strong inputs disguise one that
    /// is missing.
    static func weakest(_ confidences: [InsightConfidence]) -> InsightConfidence {
        confidences.min() ?? .low
    }
}
