import Foundation
import CoreLocation

/// What CoreLocation is doing, as opposed to what was requested of it.
///
/// Three states rather than a Boolean because the middle one is real and useful:
/// significant-change monitoring is not tracking in the drive sense, but it is very much
/// not off either -- it is the thing that notices a drive starting.
enum LocationTrackingState: String, Sendable, Equatable {
    case stopped
    case significantChange
    case continuous
}

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

    /// What the app has asked for, whether or not iOS was willing at the time.
    ///
    /// Deliberately separate from `trackingState`. A request made before the driver has
    /// answered the permission prompt is real intent, and it has to survive until it can
    /// be honoured. One flag doing both jobs is what made a grant arriving after launch
    /// do nothing: the replay was gated on tracking already being active, which the
    /// authorization guard had just prevented from happening.
    private(set) var requestedFidelity: LocationFidelity?

    /// What CoreLocation is actually doing right now.
    private(set) var trackingState: LocationTrackingState = .stopped

    /// The fidelity currently in force, or `.idle` when nothing is running.
    var fidelity: LocationFidelity { activeFidelity ?? .idle }
    private var activeFidelity: LocationFidelity?

    /// Updates are flowing at drive fidelity.
    var isTracking: Bool { trackingState == .continuous }

    /// Updates of any kind are flowing, significant-change included. This is the honest
    /// answer to "will a drive be noticed", because significant-change monitoring is
    /// exactly what notices one.
    var isMonitoring: Bool { trackingState != .stopped }

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
            // Intent is cleared too: this is the app saying it no longer wants updates,
            // as distinct from iOS refusing to provide them.
            self.requestedFidelity = nil
            self.activeFidelity = nil
            self.trackingState = .stopped
        }
    }

    private func beginUpdates(fidelity: LocationFidelity) {
        // Recorded before the guard, not after it. Everything below can be refused by
        // iOS; the request itself cannot, and forgetting it is the bug.
        requestedFidelity = fidelity

        guard authorization.allowsTracking else {
            activeFidelity = nil
            trackingState = .stopped
            return
        }

        activeFidelity = fidelity
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
        trackingState = fidelity == .idle ? .significantChange : .continuous
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
            // Replayed from what was *asked for*, not from whether tracking happens to be
            // running. The old condition could never be true on the path that mattered: a
            // request refused for want of permission left tracking stopped, so the grant
            // arriving seconds later found nothing to resume. The first call at launch is
            // `.idle`, so this is also what makes drive detection work at all for a driver
            // who allows location the first time they are asked.
            if let requested = self.requestedFidelity, self.authorization.allowsTracking {
                self.beginUpdates(fidelity: requested)
            } else if !self.authorization.allowsTracking {
                // Permission withdrawn while running: stop claiming otherwise.
                self.activeFidelity = nil
                self.trackingState = .stopped
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
