import Foundation

/// A single vocabulary for "how is this doing?" used by every subsystem —
/// health, insights, CarPlay, widgets. Colour is never the only carrier of
/// meaning: every case also has a label and an SF Symbol name.
enum SemanticStatus: String, Codable, CaseIterable, Sendable {
    case normal
    case watch
    case attention
    case critical
    /// Not "zero" and not "fine" — we genuinely do not know.
    case unknown

    /// Higher wins when several subsystems roll up into one headline status.
    var rank: Int {
        switch self {
        case .normal: return 0
        case .unknown: return 1
        case .watch: return 2
        case .attention: return 3
        case .critical: return 4
        }
    }

    var label: String {
        switch self {
        case .normal: return "Normal"
        case .watch: return "Watch"
        case .attention: return "Attention"
        case .critical: return "Critical"
        case .unknown: return "Unknown"
        }
    }

    /// SF Symbol name. Shape differs per case so the status is legible without colour.
    var symbolName: String {
        switch self {
        case .normal: return "checkmark.circle.fill"
        case .watch: return "exclamationmark.triangle"
        case .attention: return "exclamationmark.triangle.fill"
        case .critical: return "exclamationmark.octagon.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    /// Rolls several statuses into one. Empty input is `.unknown`, not `.normal`.
    static func rollUp<S: Sequence>(_ statuses: S) -> SemanticStatus where S.Element == SemanticStatus {
        var worst: SemanticStatus?
        for status in statuses {
            if worst == nil || status.rank > worst!.rank { worst = status }
        }
        return worst ?? .unknown
    }
}

extension SemanticStatus: Comparable {
    static func < (lhs: SemanticStatus, rhs: SemanticStatus) -> Bool { lhs.rank < rhs.rank }
}
