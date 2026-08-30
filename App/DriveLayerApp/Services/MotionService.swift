import Foundation
import CoreMotion

/// Barometric altitude and vertical acceleration.
///
/// The barometer is the reason DriveLayer can talk about gradient at all: GPS
/// altitude is worth about ten metres, which is useless on a 4% slope, while relative
/// barometric altitude resolves to well under a metre.
@MainActor
@Observable
final class MotionService: AltitudeProviding {

    private(set) var latestAltitude: AltitudeSample?
    private(set) var isRunning = false
    private(set) var deviceMountingConfidence: Double?
    /// Impact candidates found during this drive. Recorded, not interpreted.
    private(set) var recentImpacts: [RoadImpactEvent] = []

    private let altimeter = CMAltimeter()
    private let motion = CMMotionManager()
    private var detector = RoadImpactDetector()
    /// All the altitude judgement, in the core where it is tested.
    private var fusion = AltitudeFusion()

    /// Whether road-surface detection runs at all.
    ///
    /// The setting used to gate only *persistence*, in the coordinator, so switching it
    /// off still ran 20 Hz device-motion processing and impact classification for a
    /// whole drive before throwing every result away. Now it stops the sensor.
    var isImpactDetectionEnabled = true {
        didSet {
            guard isRunning, oldValue != isImpactDetectionEnabled else { return }
            if isImpactDetectionEnabled {
                beginDeviceMotion()
            } else {
                motion.stopDeviceMotionUpdates()
                detector.reset()
                recentImpacts.removeAll()
                deviceMountingConfidence = nil
            }
        }
    }

    private nonisolated let continuation: AsyncStream<AltitudeSample>.Continuation
    private nonisolated let stream: AsyncStream<AltitudeSample>

    /// Supplied by the drive coordinator so impact events can be located and speed-gated.
    var currentPoint: GeoPoint?
    var currentSpeedKmh: Double?

    init() {
        let (stream, continuation) = AsyncStream<AltitudeSample>.makeStream(bufferingPolicy: .bufferingNewest(32))
        self.stream = stream
        self.continuation = continuation
    }

    nonisolated var isAvailable: Bool { CMAltimeter.isRelativeAltitudeAvailable() }

    /// Height above sea level, or `nil` when no GPS fix has established one yet.
    ///
    /// Nil rather than a fallback on purpose: before an anchor exists the only number
    /// available is "metres since the barometer started", and presenting that under the
    /// word "altitude" is what the old code did.
    var absoluteAltitudeMetres: Double? { fusion.absoluteAltitudeMetres }

    /// Change since the barometer started. Always available, always honest.
    var elevationChangeMetres: Double { fusion.elevationChangeMetres }

    var hasAbsoluteAltitude: Bool { fusion.hasAbsoluteReference }

    nonisolated var updates: AsyncStream<AltitudeSample> { stream }

    nonisolated func start() {
        Task { @MainActor in self.beginUpdates() }
    }

    nonisolated func stop() {
        Task { @MainActor in
            self.altimeter.stopRelativeAltitudeUpdates()
            self.motion.stopDeviceMotionUpdates()
            self.detector.reset()
            self.isRunning = false
        }
    }

    /// Offers a GPS altitude to the fusion, which decides what to do with it.
    ///
    /// Offered rather than applied: the previous version of this took every fix with
    /// vertical accuracy under fifteen metres and re-anchored to it, once per second,
    /// which made the published altitude GPS altitude with extra steps. See
    /// `AltitudeFusion` for what happens instead.
    func offerGPSAltitude(_ altitude: Double?, accuracyMetres: Double?, isStationary: Bool) {
        let outcome = fusion.offer(gpsAltitude: altitude,
                                   accuracyMetres: accuracyMetres,
                                   isStationary: isStationary)
        // Anchoring changes the absolute height without any barometer movement, so the
        // published sample would otherwise be stale until the next barometer reading -
        // which on a stationary car can be a while.
        switch outcome {
        case .anchored, .reAnchored:
            publishAltitude()
        case .ignored, .corrected:
            break
        }
    }

    /// Forgets the absolute reference, keeping barometric continuity. Used when the
    /// vehicle changes.
    func resetAltitudeReference() {
        fusion.forgetAnchor()
    }

    private func beginUpdates() {
        guard !isRunning else { return }
        isRunning = true

        if CMAltimeter.isRelativeAltitudeAvailable() {
            altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
                guard let self, let data else { return }
                // Only plain values cross into the actor: CoreMotion's objects stay
                // on the queue that produced them.
                let relative = data.relativeAltitude.doubleValue
                Task { @MainActor in self.applyRelativeAltitude(relative) }
            }
        }

        // The barometer is cheap and always wanted; the 20 Hz accelerometer is neither,
        // so it only runs when the feature that needs it is switched on.
        if isImpactDetectionEnabled { beginDeviceMotion() }
    }

    private func beginDeviceMotion() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 20.0
        motion.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            // Project the device's own acceleration onto gravity, so the value means
            // "up and down relative to the road" however the phone happens to be lying.
            let gravity = motion.gravity
            let magnitude = (gravity.x * gravity.x + gravity.y * gravity.y + gravity.z * gravity.z).squareRoot()
            guard magnitude > 0.001 else { return }
            let acceleration = motion.userAcceleration
            let vertical = (acceleration.x * gravity.x + acceleration.y * gravity.y + acceleration.z * gravity.z) / magnitude
            Task { @MainActor in self.consume(verticalG: vertical) }
        }
    }

    private func applyRelativeAltitude(_ relative: Double) {
        fusion.update(relativeAltitude: relative)
        publishAltitude()
    }

    private func publishAltitude() {
        let sample = fusion.sample(at: Date())
        latestAltitude = sample
        continuation.yield(sample)
    }

    private func consume(verticalG: Double) {
        guard isImpactDetectionEnabled else { return }
        let sample = MotionSample(timestamp: Date(), verticalG: verticalG, speedKmh: currentSpeedKmh)
        if let event = detector.consider(sample, location: currentPoint) {
            recentImpacts.insert(event, at: 0)
            if recentImpacts.count > 50 { recentImpacts.removeLast() }
        }
        deviceMountingConfidence = detector.deviceMountingConfidence
    }

    func clearImpacts() {
        recentImpacts.removeAll()
        detector.reset()
    }
}
