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
    private var anchorAltitude: Double?
    private var relativeAtAnchor: Double = 0

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

    /// Anchors relative barometric altitude to a GPS altitude, so the fused value is
    /// an absolute height that still moves with barometric sensitivity.
    func anchorAltitude(toGPS altitude: Double) {
        anchorAltitude = altitude - relativeAtAnchor
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

        guard motion.isDeviceMotionAvailable else { return }
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
        relativeAtAnchor = relative
        let absolute = (anchorAltitude ?? 0) + relative
        let sample = AltitudeSample(altitudeMetres: absolute,
                                    accuracyMetres: anchorAltitude == nil ? 10 : 3,
                                    source: anchorAltitude == nil ? .barometricRelative : .fused,
                                    timestamp: Date())
        latestAltitude = sample
        continuation.yield(sample)
    }

    private func consume(verticalG: Double) {
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
