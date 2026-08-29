import Foundation

/// The three honest capability levels the onboarding explains and the whole app
/// keys off. Nothing in DriveLayer may promise level 3 for a vehicle whose profile
/// is not `.validated` and has at least one usable manufacturer capability.
enum VehicleCapabilityLevel: Int, Codable, CaseIterable, Sendable, Comparable {
    case phoneOnly = 1
    case obdConnected = 2
    case enhancedProfile = 3

    static func < (lhs: VehicleCapabilityLevel, rhs: VehicleCapabilityLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var title: String {
        switch self {
        case .phoneOnly: return "Phone"
        case .obdConnected: return "Connected"
        case .enhancedProfile: return "Enhanced profile"
        }
    }

    var summary: String {
        switch self {
        case .phoneOnly:
            return "Trips, terrain, weather, fuel, maintenance and documents — using only your iPhone."
        case .obdConnected:
            return "Adds live engine data, battery voltage, fuel readings and trouble codes from a Bluetooth OBD-II adapter."
        case .enhancedProfile:
            return "Adds vehicle-specific read-only data that has been verified for your exact model."
        }
    }

    /// What the app can currently do, given a profile and whether an adapter is live.
    static func current(profile: VehicleProfile?, isAdapterConnected: Bool) -> VehicleCapabilityLevel {
        guard isAdapterConnected else { return .phoneOnly }
        guard let profile,
              profile.validationTier == .validated,
              !profile.usableManufacturerCapabilities.isEmpty else { return .obdConnected }
        return .enhancedProfile
    }
}
