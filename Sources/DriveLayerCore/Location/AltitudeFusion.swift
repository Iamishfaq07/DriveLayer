import Foundation

/// Fuses barometric relative altitude with GPS absolute altitude.
///
/// The two sensors are good at opposite things. The barometer resolves change to well
/// under a metre but has no idea how high it is, and drifts as the weather does. GPS
/// knows roughly how high it is — worth about ten metres vertically — and is far too
/// noisy to differentiate for a gradient.
///
/// So: GPS sets the origin, the barometer supplies every movement after it.
///
/// What this replaces re-anchored to GPS on every fix it liked, once per second. The
/// comment above it said "the first time GPS altitude is good"; there was no such
/// guard. The output was therefore GPS altitude with extra steps — ten metres of noise
/// per second, and the barometer contributing nothing at all to the one number it was
/// chosen for.
///
/// A value type in the core so all of this is testable without CoreMotion.
struct AltitudeFusion: Sendable, Equatable {

    /// GPS fixes worse than this are ignored. Ten metres is normal; beyond about
    /// fifteen there is nothing worth anchoring to.
    var maximumUsableAccuracyMetres: Double = 15

    /// Share of the disagreement applied per accepted fix while driving.
    ///
    /// Deliberately small. This is drift correction — the barometer wandering as the
    /// weather changes over an hour — not error correction, and anything fast enough to
    /// fix an error quickly is also fast enough to reintroduce the GPS noise.
    var driftCorrectionRate: Double = 0.02

    /// Faster correction when the car is not moving, where there is no gradient to
    /// protect and successive fixes average out.
    var stationaryCorrectionRate: Double = 0.2

    /// A disagreement this large is not drift.
    ///
    /// Leaving a tunnel, a multi-storey car park, or a long stretch with no sky: the
    /// barometer may be genuinely wrong by more than any plausible drift, and creeping
    /// back at 2% a second would take minutes. Re-anchor outright instead.
    var reAnchorThresholdMetres: Double = 75

    /// Absolute altitude of the point where relative altitude read zero.
    private(set) var anchorMetres: Double?
    /// Latest barometric reading, relative to wherever the barometer started.
    private(set) var relativeMetres: Double = 0
    private(set) var lastAnchoredAt: Date?
    /// How many GPS fixes have been folded in since the anchor was established.
    private(set) var correctionCount = 0

    init() {}

    /// Whether an absolute height can be stated at all.
    var hasAbsoluteReference: Bool { anchorMetres != nil }

    var source: AltitudeSource { hasAbsoluteReference ? .fused : .barometricRelative }

    /// Height above sea level, or `nil` when no GPS fix has established one.
    ///
    /// Nil rather than a fallback, so a caller cannot accidentally present "metres since
    /// the app launched" as "metres above sea level". That is what the old code did:
    /// `(anchor ?? 0) + relative`, displayed under the label "Altitude".
    var absoluteAltitudeMetres: Double? {
        guard let anchorMetres else { return nil }
        return anchorMetres + relativeMetres
    }

    /// Change since the barometer started, which is always available and always honest.
    var elevationChangeMetres: Double { relativeMetres }

    // MARK: - Inputs

    /// Records a barometer reading.
    mutating func update(relativeAltitude: Double) {
        relativeMetres = relativeAltitude
    }

    /// The outcome of offering a GPS fix, so callers and tests can see what happened.
    enum GPSOutcome: Equatable, Sendable {
        /// Too inaccurate, or no altitude in the fix.
        case ignored
        /// First usable fix: the origin is now known.
        case anchored
        /// Nudged towards the fix by a fraction of the disagreement.
        case corrected(byMetres: Double)
        /// The disagreement was too large to be drift, so the origin was reset.
        case reAnchored(residualMetres: Double)
    }

    /// Offers a GPS altitude.
    ///
    /// - Parameters:
    ///   - isStationary: allows faster correction, because there is no gradient to
    ///     protect and successive fixes average out.
    @discardableResult
    mutating func offer(gpsAltitude: Double?,
                        accuracyMetres: Double?,
                        isStationary: Bool = false,
                        now: Date = Date()) -> GPSOutcome {
        guard let gpsAltitude else { return .ignored }
        // A missing accuracy is not an accurate fix. CoreLocation reports negative
        // vertical accuracy when it has none, which would otherwise pass every test.
        guard let accuracyMetres, accuracyMetres > 0,
              accuracyMetres <= maximumUsableAccuracyMetres else { return .ignored }

        guard let existing = anchorMetres else {
            anchorMetres = gpsAltitude - relativeMetres
            lastAnchoredAt = now
            correctionCount = 0
            return .anchored
        }

        let residual = gpsAltitude - (existing + relativeMetres)
        if abs(residual) > reAnchorThresholdMetres {
            anchorMetres = gpsAltitude - relativeMetres
            lastAnchoredAt = now
            correctionCount = 0
            return .reAnchored(residualMetres: residual)
        }

        let rate = isStationary ? stationaryCorrectionRate : driftCorrectionRate
        let adjustment = residual * rate
        anchorMetres = existing + adjustment
        correctionCount += 1
        return .corrected(byMetres: adjustment)
    }

    /// The sample to publish for the current state.
    ///
    /// Accuracy reflects which sensor is really answering: the barometer's own
    /// resolution before an anchor exists, and the anchored figure afterwards, which
    /// cannot be better than the GPS altitude it is tied to.
    func sample(at timestamp: Date) -> AltitudeSample {
        AltitudeSample(altitudeMetres: absoluteAltitudeMetres ?? relativeMetres,
                       accuracyMetres: hasAbsoluteReference ? 3 : 1,
                       source: source,
                       timestamp: timestamp)
    }

    /// Clears the absolute reference, keeping the barometer's own continuity.
    ///
    /// Used when the vehicle changes, or when a drive is far enough from the last one
    /// that the old anchor says nothing about where the car is now.
    mutating func forgetAnchor() {
        anchorMetres = nil
        lastAnchoredAt = nil
        correctionCount = 0
    }
}
