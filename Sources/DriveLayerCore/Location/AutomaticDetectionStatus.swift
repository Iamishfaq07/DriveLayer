import Foundation

/// What automatic drive detection is actually doing, as opposed to what the switch says.
///
/// The switch used to be the whole story: flipping it set a boolean and nothing asked
/// iOS for anything. A driver could turn it on, be told drives would be recorded
/// automatically, and get nothing — because the permission it needs was never
/// requested, or had been refused.
///
/// So the honest answer is a function of two things, and this is where they meet. The
/// distinction that matters most is the middle one: "when in use" is not a failure, but
/// it is not what was asked for either, and saying so is better than either claiming
/// success or reporting an error.
enum AutomaticDetectionStatus: Equatable, Sendable {

    /// The driver has not asked for it.
    case off
    /// Asked for, and iOS has not been asked yet.
    case awaitingPermission
    /// Granted, but only while DriveLayer is on screen, so drives that start while the
    /// phone is in a pocket will be missed.
    case foregroundOnly
    /// Working as intended.
    case active
    /// Permitted, and nevertheless not running.
    ///
    /// Should be transient: the moment between a permission being granted and updates
    /// being started. If it persists it is a bug, and the point of having the case is
    /// that the driver is told so rather than shown "Active" over a service that was
    /// never started.
    case permittedButNotStarted
    /// Asked for, and iOS will not allow it.
    case blocked(UnavailabilityReason)

    /// - Parameter isReceivingUpdates: whether CoreLocation is actually delivering
    ///   anything, significant-change monitoring included. Defaults to true so callers
    ///   reasoning only about permissions read unchanged; the coordinator passes the real
    ///   value, because permission granted and updates running are different claims.
    static func resolve(isEnabled: Bool,
                        authorization: LocationAuthorization,
                        isReceivingUpdates: Bool = true) -> AutomaticDetectionStatus {
        guard isEnabled else { return .off }
        switch authorization {
        case .notDetermined: return .awaitingPermission
        case .denied: return .blocked(.locationPermissionDenied)
        case .restricted: return .blocked(.locationPermissionDenied)
        case .whenInUse: return isReceivingUpdates ? .foregroundOnly : .permittedButNotStarted
        case .always: return isReceivingUpdates ? .active : .permittedButNotStarted
        }
    }

    /// Whether drives will actually be detected without the driver opening the app.
    var detectsInBackground: Bool { self == .active }

    /// Whether the driver needs to do something in iOS Settings.
    var needsSettingsApp: Bool {
        if case .blocked = self { return true }
        return false
    }

    /// Short label for the row under the switch. Never says "on" when it is not.
    var summary: String {
        switch self {
        case .off: return "Off"
        case .awaitingPermission: return "Waiting for permission"
        case .foregroundOnly: return "Only while DriveLayer is open"
        case .active: return "Active"
        case .permittedButNotStarted: return "Not running"
        case .blocked: return "Needs location permission"
        }
    }

    /// The explanation shown when the switch and reality disagree. `nil` when they do not.
    var explanation: String? {
        switch self {
        case .off, .active:
            return nil
        case .permittedButNotStarted:
            return "Location access is allowed, but DriveLayer is not receiving updates "
                + "yet. Reopening the app will start them."
        case .awaitingPermission:
            return "DriveLayer is waiting for you to allow location access."
        case .foregroundOnly:
            return "iOS has granted location only while DriveLayer is open, so drives that "
                + "start with the app closed won't be recorded. Choose \"Always\" in iOS "
                + "Settings to record them, or start drives from the Drive tab."
        case let .blocked(reason):
            return reason.message
        }
    }
}
