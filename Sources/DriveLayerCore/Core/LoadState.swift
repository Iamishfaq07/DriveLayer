import Foundation

/// Every feature surface has to answer all of these, so they are modelled once.
/// `.success` carries partial-data information rather than pretending a partial
/// snapshot is complete.
enum LoadState<Value>: Sendable where Value: Sendable {
    case idle
    case loading
    case success(Value, isPartial: Bool)
    case empty(message: String)
    /// The capability exists but this vehicle/phone/permission set cannot provide it.
    case unavailable(reason: UnavailabilityReason)
    case failure(message: String, isRetryable: Bool)

    var value: Value? {
        if case let .success(value, _) = self { return value }
        return nil
    }

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}

/// Why something is not available. Each case maps to a specific, honest empty state.
enum UnavailabilityReason: Equatable, Sendable {
    case obdNotConnected
    case pidNotSupportedByVehicle(String)
    case locationPermissionDenied
    case locationPermissionNotDetermined
    case motionPermissionDenied
    case weatherServiceUnconfigured
    case offline
    case noVehicleSelected
    case notEnoughHistory(needed: Int, have: Int)
    case featureRequiresValidatedProfile
    /// No destination set, or no road route to one.
    case noDestination
    case routeUnavailable
    /// A route exists but is shorter than the spacing weather is sampled at, so
    /// there is no "ahead" to forecast.
    case routeTooShortForForecast
    /// Location is permitted, but no fix has arrived yet. Distinct from a permission
    /// problem: nothing is wrong and there is nothing for the driver to do.
    case waitingForLocationFix

    var title: String {
        switch self {
        case .obdNotConnected: return "Vehicle data not connected"
        case .pidNotSupportedByVehicle: return "Not reported by this vehicle"
        case .locationPermissionDenied: return "Location access is off"
        case .locationPermissionNotDetermined: return "Location access needed"
        case .motionPermissionDenied: return "Motion access is off"
        case .weatherServiceUnconfigured: return "Weather is not configured"
        case .offline: return "You're offline"
        case .noVehicleSelected: return "No vehicle selected"
        case .notEnoughHistory: return "Still learning your car"
        case .featureRequiresValidatedProfile: return "Not available for this vehicle"
        case .noDestination: return "No destination set"
        case .routeUnavailable: return "No route available"
        case .routeTooShortForForecast: return "Too close to forecast"
        case .waitingForLocationFix: return "Finding your location"
        }
    }

    var message: String {
        switch self {
        case .obdNotConnected:
            return "Connect a supported Bluetooth OBD-II adapter to unlock live engine and vehicle information."
        case let .pidNotSupportedByVehicle(name):
            return "\(name) isn't reported by this vehicle's OBD-II interface, so DriveLayer leaves it out rather than guessing."
        case .locationPermissionDenied:
            return "DriveLayer needs location access to record trips, terrain and road context. You can turn it on in Settings."
        case .locationPermissionNotDetermined:
            return "Allow location access to record trips, terrain and road context."
        case .motionPermissionDenied:
            return "Motion access lets DriveLayer detect drive starts and road surface events."
        case .weatherServiceUnconfigured:
            return "Weather needs a configured weather provider. Everything else keeps working."
        case .offline:
            return "Weather and road context need a connection. Trips, engine data and history keep recording."
        case .noVehicleSelected:
            return "Add a vehicle to your garage to get started."
        case let .notEnoughHistory(needed, have):
            return "DriveLayer needs about \(needed) drives to learn what's normal for this car. It has \(have) so far."
        case .featureRequiresValidatedProfile:
            return "This needs vehicle-specific data that hasn't been validated for your car. DriveLayer won't guess."
        case .noDestination:
            return "Set where you're heading and DriveLayer will tell you what the weather does along the way."
        case .routeUnavailable:
            return "DriveLayer couldn't work out a road route to there, so it won't guess what the weather is along one."
        case .routeTooShortForForecast:
            return "The drive is short enough that the weather where you are is the weather when you arrive."
        case .waitingForLocationFix:
            return "Waiting for a GPS fix. This usually takes a few seconds outdoors."
        }
    }
}
