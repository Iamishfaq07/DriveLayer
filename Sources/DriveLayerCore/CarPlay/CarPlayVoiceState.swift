import Foundation

/// Deterministic phases for the native CarPlay voice indicator.
///
/// Keeping these identifiers outside the presenter makes transitions testable
/// without a CarPlay head unit and prevents an activation typo from silently
/// leaving the previous state on screen.
public enum CarPlayVoiceState: String, CaseIterable, Sendable {
    case listening
    case understanding
    case answering

    public var titleVariants: [String] {
        switch self {
        case .listening: return ["Listening…", "Listening"]
        case .understanding: return ["Understanding…", "Understanding"]
        case .answering: return ["Answering…", "Answering"]
        }
    }
}
