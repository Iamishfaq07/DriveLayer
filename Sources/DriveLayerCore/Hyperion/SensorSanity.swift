import Foundation

/// Decides whether a reading is worth believing, before anything reasons about it.
///
/// OBD-II data off a consumer BLE adapter is noisy in specific, recognisable ways: a
/// frame arrives mangled, a sensor reads its default on power-up, a value jumps to
/// something physically impossible for one sample, or the adapter keeps handing back the
/// same stale number after the ECU stopped answering.
///
/// The rule this file exists to enforce: **a bad reading is not a zero.** Silently
/// substituting zero is how a coolant sensor dropping out becomes "engine ice cold" and
/// a fuel level glitch becomes "empty tank". Every rejection here produces an explicit
/// verdict the caller must handle, and `DataProvenance.unavailable` is a first-class
/// answer rather than a failure.
enum SensorSanity {

    /// Why a reading was not accepted.
    enum Rejection: Equatable, Sendable {
        /// Outside what the sensor could physically report.
        case outsidePlausibleRange(low: Double, high: Double)
        /// A jump too large to be real over the elapsed time.
        case impossibleRateOfChange(perSecond: Double, limit: Double)
        /// Byte-for-byte identical to the previous reading, for too long.
        case stale(seconds: TimeInterval)
        /// The value a sensor reports when it has nothing, which is not a measurement.
        case sensorDefault

        /// Whether a reading rejected for this reason may eventually be accepted as the
        /// new reality once it persists.
        ///
        /// Only an impossible rate of change may. That is the case the gate was built
        /// for: if the engine genuinely is at 4,000 rpm, a filter that keeps insisting
        /// otherwise has stopped filtering and started being wrong.
        ///
        /// The rest must never yield, and the distinction is not stylistic. A value
        /// outside the plausible range is outside what the sensor can physically report,
        /// so repetition is evidence of a broken sensor rather than of a hot engine --
        /// a coolant reading of 500 C repeated ten times is still not 500 C. A sensor
        /// default is by definition what the sensor sends when it has nothing to say,
        /// and a broken sensor says it indefinitely. A stale reading is one that has
        /// stopped changing, which is a reason to keep flagging it rather than to start
        /// trusting it. Accepting any of the three would hand a driver a fabricated
        /// number carrying full measured provenance and no way to tell.
        var mayYieldToPersistence: Bool {
            switch self {
            case .impossibleRateOfChange: return true
            case .outsidePlausibleRange, .sensorDefault, .stale: return false
            }
        }

        var explanation: String {
            switch self {
            case let .outsidePlausibleRange(low, high):
                return String(format: "outside the plausible range %.0f to %.0f", low, high)
            case let .impossibleRateOfChange(perSecond, limit):
                return String(format: "changed by %.1f per second, faster than %.1f", perSecond, limit)
            case let .stale(seconds):
                return String(format: "unchanged for %.0f s", seconds)
            case .sensorDefault:
                return "the value this sensor reports when it has none"
            }
        }
    }

    enum Verdict: Equatable, Sendable {
        case accepted(Double)
        case rejected(Rejection)

        var value: Double? {
            if case let .accepted(value) = self { return value }
            return nil
        }

        var isAccepted: Bool { value != nil }
    }

    /// The fastest a metric can physically change, per second.
    ///
    /// Generous on purpose. These exist to catch a corrupt frame reporting a coolant
    /// temperature that moved 80 °C in a second, not to smooth real driving — an engine
    /// really does gain 3,000 rpm in a second, and over-filtering live data is its own
    /// kind of dishonesty.
    static func maximumRateOfChange(for metric: VehicleMetric) -> Double? {
        switch metric {
        case .coolantTemperatureC: return 5          // thermal mass; 5 °C/s is already absurd
        case .oilTemperatureC: return 5
        case .intakeAirTemperatureC: return 20       // genuinely fast when airflow starts
        case .ambientAirTemperatureC: return 5
        case .catalystTemperatureC: return 100
        case .engineRPM: return 4_000
        case .vehicleSpeedKmh: return 40             // ~1.1 g, past any road car
        case .fuelLevelPercent: return 2             // a tank does not empty in seconds
        case .controlModuleVoltageV: return 5
        case .barometricPressureKPa: return 5
        case .ethanolPercent: return 1               // only changes when refuelled
        case .longTermFuelTrimPercent: return 2      // "long-term" is the clue
        default: return nil                          // no useful limit; range check only
        }
    }

    /// Values that mean "no reading" rather than a reading.
    ///
    /// Deliberately short. Rejecting a genuine zero — an idling engine really does report
    /// 0 km/h — would be worse than accepting a false one, so this only covers cases
    /// where zero is physically impossible while the engine is running.
    static func isSensorDefault(_ value: Double, for metric: VehicleMetric, engineRunning: Bool) -> Bool {
        guard engineRunning else { return false }
        switch metric {
        case .engineRPM, .controlModuleVoltageV:
            // A running engine cannot turn at zero rpm, and the module reporting zero
            // volts is reporting that it is not powered - which it plainly is.
            return value <= 0
        case .barometricPressureKPa:
            // Zero pressure is a vacuum. Even the highest road in the world reads ~40.
            return value <= 0
        default:
            return false
        }
    }

    /// Checks one reading against its range, its rate of change and its history.
    ///
    /// - Parameters:
    ///   - previous: the last accepted value and when it was accepted, if any.
    ///   - staleAfter: how long an unchanging value stays believable. Metrics that
    ///     genuinely sit still — ambient temperature, ethanol content — should be given a
    ///     long window or none at all.
    static func check(_ value: Double,
                      metric: VehicleMetric,
                      at timestamp: Date,
                      plausibleRange: ClosedRange<Double>?,
                      previous: (value: Double, timestamp: Date)?,
                      engineRunning: Bool = true,
                      staleAfter: TimeInterval? = nil) -> Verdict {
        if let plausibleRange, !plausibleRange.contains(value) {
            return .rejected(.outsidePlausibleRange(low: plausibleRange.lowerBound,
                                                    high: plausibleRange.upperBound))
        }

        if isSensorDefault(value, for: metric, engineRunning: engineRunning) {
            return .rejected(.sensorDefault)
        }

        if let previous {
            let elapsed = timestamp.timeIntervalSince(previous.timestamp)
            if elapsed > 0, let limit = maximumRateOfChange(for: metric) {
                let rate = abs(value - previous.value) / elapsed
                if rate > limit {
                    return .rejected(.impossibleRateOfChange(perSecond: rate, limit: limit))
                }
            }
            if let staleAfter, value == previous.value, elapsed >= staleAfter {
                return .rejected(.stale(seconds: elapsed))
            }
        }

        return .accepted(value)
    }
}

/// Tracks one metric's recent history so rate-of-change and staleness can be judged.
///
/// A value type holding the last accepted reading and a short window of recent ones. The
/// window is what makes a *single* spike distinguishable from a genuine step change: one
/// impossible jump is a bad frame, three in a row is the engine actually doing something
/// and the limit being wrong.
struct SensorGate: Sendable, Equatable {

    let metric: VehicleMetric
    var plausibleRange: ClosedRange<Double>?
    var staleAfter: TimeInterval?
    /// Consecutive rejections before the gate gives up and accepts the new reality.
    var rejectionsBeforeYielding = 3

    private(set) var lastAccepted: (value: Double, timestamp: Date)?
    private(set) var consecutiveRejections = 0
    private(set) var lastRejection: SensorSanity.Rejection?

    init(metric: VehicleMetric,
         plausibleRange: ClosedRange<Double>? = nil,
         staleAfter: TimeInterval? = nil) {
        self.metric = metric
        self.plausibleRange = plausibleRange
        self.staleAfter = staleAfter
    }

    static func == (lhs: SensorGate, rhs: SensorGate) -> Bool {
        lhs.metric == rhs.metric
            && lhs.lastAccepted?.value == rhs.lastAccepted?.value
            && lhs.consecutiveRejections == rhs.consecutiveRejections
    }

    /// Offers a reading. Returns the value to use, or nil when it should be ignored.
    ///
    /// After `rejectionsBeforeYielding` consecutive rejections the gate accepts the
    /// reading and re-baselines -- but only when the reason permits it. Refusing a
    /// genuine step change forever would be worse than a spike, and refusing an
    /// impossible value forever is the entire point of the gate. See
    /// `SensorSanity.Rejection.mayYieldToPersistence`, which used not to be consulted
    /// here: three repeats of anything at all were enough to be believed.
    @discardableResult
    mutating func offer(_ value: Double, at timestamp: Date, engineRunning: Bool = true) -> Double? {
        let verdict = SensorSanity.check(value,
                                         metric: metric,
                                         at: timestamp,
                                         plausibleRange: plausibleRange,
                                         previous: lastAccepted,
                                         engineRunning: engineRunning,
                                         staleAfter: staleAfter)
        switch verdict {
        case let .accepted(accepted):
            lastAccepted = (accepted, timestamp)
            consecutiveRejections = 0
            lastRejection = nil
            return accepted
        case let .rejected(reason):
            lastRejection = reason
            guard reason.mayYieldToPersistence else {
                // Counted, but capped rather than climbing forever: this reading is never
                // going to be accepted, and the gate holds its last good value and keeps
                // reporting why. A broken sensor repeating itself is still broken.
                consecutiveRejections = min(consecutiveRejections + 1, rejectionsBeforeYielding)
                return nil
            }
            consecutiveRejections += 1
            guard consecutiveRejections >= rejectionsBeforeYielding else { return nil }
            // Persistent, so it is not a spike. Accept it and start again from here.
            lastAccepted = (value, timestamp)
            consecutiveRejections = 0
            lastRejection = nil
            return value
        }
    }

    /// The current value with honest provenance: unavailable while a rejection stands.
    var current: Provenanced<Double> {
        guard let lastAccepted else {
            return .unavailable(basis: lastRejection.map { "Last reading rejected: \($0.explanation)." })
        }
        if let lastRejection {
            return Provenanced(value: lastAccepted.value,
                               provenance: .measured,
                               timestamp: lastAccepted.timestamp,
                               basis: "Holding the last good reading; the newest was rejected because it was "
                                    + lastRejection.explanation + ".")
        }
        return .measured(lastAccepted.value, at: lastAccepted.timestamp)
    }

    mutating func reset() {
        lastAccepted = nil
        consecutiveRejections = 0
        lastRejection = nil
    }
}
