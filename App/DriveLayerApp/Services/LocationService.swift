import Foundation
import CoreLocation

/// CoreLocation, behind the core's `LocationProviding` protocol.
///
/// Accuracy is raised and lowered with what the app is doing rather than left at
/// "best" for the whole drive: a three-hour journey at full GPS fidelity is a
/// meaningful share of a phone's battery, and DriveLayer is meant to be left running.
@MainActor
@Observable
final class LocationService: NSObject, LocationProviding {

    private(set) var authorization: LocationAuthorization = .notDetermined
    private(set) var latest: GeoPoint?
    private(set) var fidelity: LocationFidelity = .idle
    private(set) var isTracking = false

    private let manager = CLLocationManager()
    // Sendable, and needed from the delegate's nonisolated callbacks, so both are
    // deliberately outside the main actor's isolation.
    private nonisolated let continuation: AsyncStream<GeoPoint>.Continuation
    private nonisolated let stream: AsyncStream<GeoPoint>

    override init() {
        let (stream, continuation) = AsyncStream<GeoPoint>.makeStream(bufferingPolicy: .bufferingNewest(64))
        self.stream = stream
        self.continuation = continuation
        super.init()
        manager.delegate = self
        manager.pausesLocationUpdatesAutomatically = false
        authorization = Self.map(manager.authorizationStatus)
    }

    /// Single-consumer by design: the drive coordinator owns it.
    nonisolated var updates: AsyncStream<GeoPoint> { stream }

    func requestAuthorization() async {
        manager.requestWhenInUseAuthorization()
    }

    /// Asks for background location. Only called when the driver turns on automatic
    /// trip recording, and the reason is explained on that screen first.
    func requestAlwaysAuthorization() {
        manager.requestAlwaysAuthorization()
    }

    nonisolated func start(fidelity: LocationFidelity) {
        Task { @MainActor in self.beginUpdates(fidelity: fidelity) }
    }

    nonisolated func stop() {
        Task { @MainActor in
            self.manager.stopUpdatingLocation()
            self.manager.stopMonitoringSignificantLocationChanges()
            self.isTracking = false
        }
    }

    private func beginUpdates(fidelity: LocationFidelity) {
        guard authorization.allowsTracking else { return }
        self.fidelity = fidelity
        manager.distanceFilter = fidelity.distanceFilterMetres

        switch fidelity {
        case .idle:
            // Waiting for a drive: significant-change monitoring costs almost nothing.
            manager.stopUpdatingLocation()
            manager.startMonitoringSignificantLocationChanges()
        case .driving:
            manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
            manager.stopMonitoringSignificantLocationChanges()
            manager.startUpdatingLocation()
        case .active:
            manager.desiredAccuracy = kCLLocationAccuracyBest
            manager.stopMonitoringSignificantLocationChanges()
            manager.startUpdatingLocation()
        }

        if authorization == .always {
            manager.allowsBackgroundLocationUpdates = (fidelity != .idle)
            manager.showsBackgroundLocationIndicator = true
        }
        isTracking = fidelity != .idle
    }

    private static func map(_ status: CLAuthorizationStatus) -> LocationAuthorization {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorizedWhenInUse: return .whenInUse
        case .authorizedAlways: return .always
        @unknown default: return .notDetermined
        }
    }

    /// Nonisolated because it is pure and is called from the delegate's nonisolated
    /// callbacks; leaving it main-actor-isolated silently drops the isolation when
    /// passed as a function value, which is an error under Swift 6.
    private nonisolated static func convert(_ location: CLLocation) -> GeoPoint {
        GeoPoint(latitude: location.coordinate.latitude,
                 longitude: location.coordinate.longitude,
                 altitudeMetres: location.verticalAccuracy > 0 ? location.altitude : nil,
                 horizontalAccuracyMetres: location.horizontalAccuracy,
                 verticalAccuracyMetres: location.verticalAccuracy > 0 ? location.verticalAccuracy : nil,
                 speedMetresPerSecond: location.speed,
                 courseDegrees: location.course,
                 timestamp: location.timestamp)
    }
}

extension LocationService: CLLocationManagerDelegate {

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorization = Self.map(status)
            if self.authorization.allowsTracking, self.isTracking {
                self.beginUpdates(fidelity: self.fidelity)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let points = locations.map(Self.convert)
        for point in points { continuation.yield(point) }
        Task { @MainActor in
            self.latest = points.last
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // A transient failure is normal in a tunnel or a car park; it is logged
        // without precise coordinates and without interrupting the drive.
        PrivacyLog.logger(.location).notice("Location update failed")
    }
}
