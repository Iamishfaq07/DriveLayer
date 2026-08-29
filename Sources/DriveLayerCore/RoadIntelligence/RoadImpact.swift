import Foundation

/// One vertical acceleration sample from the device.
struct MotionSample: Sendable, Equatable {
    var timestamp: Date
    /// Vertical acceleration in g, with gravity already removed.
    var verticalG: Double
    var speedKmh: Double?
}

/// A moment when the device measured an unusually strong vertical acceleration.
///
/// This is not called a pothole, and the model does not have a `pothole` case. A
/// phone in a cupholder produces the same signal when a passenger picks it up. All
/// DriveLayer can honestly record is that something happened, how confident it is,
/// and how well mounted the device appeared to be. Turning these into road quality
/// data needs corroboration across drives and drivers, which is a later phase.
struct RoadImpactEvent: Sendable, Equatable, Identifiable, Codable {
    enum Classification: String, Sendable, Codable, CaseIterable {
        /// Recorded, not interpreted.
        case unclassified
        /// Strong, brief, and while moving at road speed with a well-mounted device.
        case possibleSurfaceIrregularity
    }

    var id: UUID
    var timestamp: Date
    var latitude: Double?
    var longitude: Double?
    var peakVerticalG: Double
    var speedKmh: Double?
    /// 0...1, how strongly this stands out from the recent baseline.
    var confidence: Double
    /// 0...1, how stable the device appeared before the event.
    var deviceMountingConfidence: Double
    var classification: Classification

    init(id: UUID = UUID(),
         timestamp: Date,
         latitude: Double? = nil,
         longitude: Double? = nil,
         peakVerticalG: Double,
         speedKmh: Double? = nil,
         confidence: Double,
         deviceMountingConfidence: Double,
         classification: Classification = .unclassified) {
        self.id = id
        self.timestamp = timestamp
        self.latitude = latitude
        self.longitude = longitude
        self.peakVerticalG = peakVerticalG
        self.speedKmh = speedKmh
        self.confidence = confidence
        self.deviceMountingConfidence = deviceMountingConfidence
        self.classification = classification
    }
}

/// Judges how steadily the device is being held or mounted.
///
/// A cradled phone has low vertical variance between road inputs; one being handled
/// has high variance. Impacts detected while mounting confidence is low are recorded
/// but never promoted beyond `.unclassified`.
struct DeviceMountingEstimator: Sendable {
    private var recentAbsolute: [Double] = []
    private let capacity = 120

    mutating func add(_ sample: MotionSample) {
        recentAbsolute.append(abs(sample.verticalG))
        if recentAbsolute.count > capacity { recentAbsolute.removeFirst(recentAbsolute.count - capacity) }
    }

    mutating func reset() { recentAbsolute.removeAll() }

    /// 0...1. `nil` until there is enough signal to judge.
    var confidence: Double? {
        guard recentAbsolute.count >= 30 else { return nil }
        guard let deviation = Statistics.medianAbsoluteDeviation(recentAbsolute) else { return nil }
        // A well-mounted phone sits around 0.02 g of deviation; loose handling is far higher.
        let normalised = Statistics.clamp(1.0 - (deviation - 0.02) / 0.18, 0...1)
        return normalised
    }
}

/// Finds impact candidates in a motion stream.
///
/// Uses a robust baseline (median and median absolute deviation) rather than a mean,
/// because the mean of a bumpy road is dragged around by the very events being looked
/// for. A refractory period stops one pothole becoming six events.
struct RoadImpactDetector: Sendable {

    /// Nothing below this is considered, whatever the baseline says.
    let absoluteFloorG: Double
    /// How many robust deviations above the baseline counts as an impact.
    let deviationMultiplier: Double
    /// Minimum gap between reported events.
    let refractorySeconds: TimeInterval
    /// Below this speed, vertical jolts are far more likely to be handling than road.
    let minimumSpeedKmh: Double

    private var window: [Double] = []
    private let windowCapacity = 200
    private var lastEventAt: Date?
    private var mounting = DeviceMountingEstimator()

    init(absoluteFloorG: Double = 0.35,
         deviationMultiplier: Double = 6.0,
         refractorySeconds: TimeInterval = 1.5,
         minimumSpeedKmh: Double = 15) {
        self.absoluteFloorG = absoluteFloorG
        self.deviationMultiplier = deviationMultiplier
        self.refractorySeconds = refractorySeconds
        self.minimumSpeedKmh = minimumSpeedKmh
    }

    mutating func reset() {
        window.removeAll()
        lastEventAt = nil
        mounting.reset()
    }

    var deviceMountingConfidence: Double? { mounting.confidence }

    /// Feeds one sample and returns an event when this sample is one.
    mutating func consider(_ sample: MotionSample, location: GeoPoint?) -> RoadImpactEvent? {
        mounting.add(sample)
        let magnitude = abs(sample.verticalG)

        defer {
            window.append(magnitude)
            if window.count > windowCapacity { window.removeFirst(window.count - windowCapacity) }
        }

        guard window.count >= 40 else { return nil }
        guard magnitude >= absoluteFloorG else { return nil }
        if let last = lastEventAt, sample.timestamp.timeIntervalSince(last) < refractorySeconds { return nil }

        guard let baseline = Statistics.median(window),
              let deviation = Statistics.medianAbsoluteDeviation(window), deviation > 0.001 else { return nil }
        let threshold = baseline + deviationMultiplier * deviation
        guard magnitude >= threshold else { return nil }

        lastEventAt = sample.timestamp

        let excess = (magnitude - threshold) / max(threshold, 0.001)
        var confidence = Statistics.clamp(0.35 + excess * 0.4, 0...1)

        let mountingConfidence = mounting.confidence ?? 0.3
        var classification = RoadImpactEvent.Classification.unclassified
        if let speed = sample.speedKmh, speed >= minimumSpeedKmh, mountingConfidence >= 0.6, confidence >= 0.5 {
            classification = .possibleSurfaceIrregularity
        } else {
            // Without road speed or a steady device this is a recording, not a finding.
            confidence = min(confidence, 0.4)
        }

        return RoadImpactEvent(timestamp: sample.timestamp,
                               latitude: location?.latitude,
                               longitude: location?.longitude,
                               peakVerticalG: magnitude,
                               speedKmh: sample.speedKmh,
                               confidence: confidence,
                               deviceMountingConfidence: mountingConfidence,
                               classification: classification)
    }
}
