import Foundation

enum LocationAuthorization: String, Codable, CaseIterable, Sendable {
    case notDetermined
    case denied
    case restricted
    case whenInUse
    case always

    var allowsTracking: Bool { self == .whenInUse || self == .always }

    var unavailabilityReason: UnavailabilityReason? {
        switch self {
        case .notDetermined: return .locationPermissionNotDetermined
        case .denied, .restricted: return .locationPermissionDenied
        case .whenInUse, .always: return nil
        }
    }
}

/// How aggressively to sample location. Drives GPS accuracy and therefore battery use.
enum LocationFidelity: String, Codable, CaseIterable, Sendable {
    /// Waiting for a drive to begin: significant-change level only.
    case idle
    /// Recording a trip.
    case driving
    /// Drive screen visible and the user is looking at it.
    case active

    var distanceFilterMetres: Double {
        switch self {
        case .idle: return 500
        case .driving: return 20
        case .active: return 10
        }
    }
}

/// Location as DriveLayer needs it. CoreLocation lives behind this in the app target.
///
/// Main-actor isolated because every implementation and every consumer is: a
/// nonisolated protocol here would only mean each conformance has to opt out of the
/// isolation it actually has.
@MainActor
protocol LocationProviding: AnyObject, Sendable {
    var authorization: LocationAuthorization { get }
    func requestAuthorization() async
    func start(fidelity: LocationFidelity)
    func stop()
    /// Fixes as they arrive.
    var updates: AsyncStream<GeoPoint> { get }
}

/// Barometric altitude, which is far better than GPS for detecting a climb.
@MainActor
protocol AltitudeProviding: AnyObject, Sendable {
    var isAvailable: Bool { get }
    func start()
    func stop()
    var updates: AsyncStream<AltitudeSample> { get }
}
