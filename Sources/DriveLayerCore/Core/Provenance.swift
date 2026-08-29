import Foundation

/// Where a number came from. This is a first-class part of the data model, not a
/// presentation detail: DriveLayer must never let an inference masquerade as a
/// sensor reading.
enum DataProvenance: String, Codable, CaseIterable, Sendable {
    /// Read from the vehicle or a device sensor.
    case measured
    /// Derived arithmetically from measured values (e.g. litres from fuel level × tank size).
    case estimated
    /// Concluded from patterns rather than computed from a reading (e.g. DPF loading risk).
    case inferred
    /// We have no basis for a value. Render as "—", never as 0.
    case unavailable

    var label: String {
        switch self {
        case .measured: return "Measured"
        case .estimated: return "Estimated"
        case .inferred: return "Inferred"
        case .unavailable: return "Unavailable"
        }
    }

    /// Short qualifier for user-facing copy. Measured values need no hedge.
    var userFacingQualifier: String? {
        switch self {
        case .measured: return nil
        case .estimated: return "estimated"
        case .inferred: return "inferred from your driving pattern"
        case .unavailable: return "unavailable"
        }
    }

    /// Confidence ceiling a value of this provenance may claim.
    var confidenceCeiling: Double {
        switch self {
        case .measured: return 1.0
        case .estimated: return 0.8
        case .inferred: return 0.6
        case .unavailable: return 0.0
        }
    }
}

/// A value that knows where it came from and when. `nil` value + `.unavailable`
/// is the only correct way to express "we don't have this".
struct Provenanced<Value: Sendable & Equatable>: Equatable, Sendable {
    var value: Value?
    var provenance: DataProvenance
    var timestamp: Date?
    /// Optional short note explaining the derivation, shown in "how do you know this?" UI.
    var basis: String?

    init(value: Value?, provenance: DataProvenance, timestamp: Date? = nil, basis: String? = nil) {
        // A missing value can only ever be `.unavailable`; a present one never is.
        if value == nil {
            self.value = nil
            self.provenance = .unavailable
        } else {
            self.value = value
            self.provenance = provenance == .unavailable ? .estimated : provenance
        }
        self.timestamp = timestamp
        self.basis = basis
    }

    static func unavailable(basis: String? = nil) -> Provenanced<Value> {
        Provenanced(value: nil, provenance: .unavailable, timestamp: nil, basis: basis)
    }

    static func measured(_ value: Value, at timestamp: Date? = nil) -> Provenanced<Value> {
        Provenanced(value: value, provenance: .measured, timestamp: timestamp)
    }

    static func estimated(_ value: Value, at timestamp: Date? = nil, basis: String? = nil) -> Provenanced<Value> {
        Provenanced(value: value, provenance: .estimated, timestamp: timestamp, basis: basis)
    }

    static func inferred(_ value: Value, at timestamp: Date? = nil, basis: String? = nil) -> Provenanced<Value> {
        Provenanced(value: value, provenance: .inferred, timestamp: timestamp, basis: basis)
    }

    var isAvailable: Bool { value != nil }
}
