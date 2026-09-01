import Foundation

/// How much a telemetry value is worth trusting.
///
/// Carried alongside the value rather than inferred at the point of display, because
/// the reason a number is doubtful is known at the moment it is admitted and
/// unrecoverable afterwards. `unavailable` is a real answer: nothing may render it
/// as zero.
enum SensorQuality: String, Codable, CaseIterable, Sendable {
    /// Passed every check.
    case good
    /// Admitted, but something about it is off - most often the last good value being
    /// held while a newer reading is rejected.
    case suspect
    /// Real once, too old to act on now.
    case stale
    /// Failed a check outright. Never a value; only a reason.
    case invalid
    /// Never reported. Distinct from `invalid`: the car was not asked, or does not answer.
    case unavailable

    /// Whether a value of this quality may drive an assessment, a baseline or a trip.
    ///
    /// `suspect` passes deliberately. It means "this is the last thing the sensor said
    /// that made sense", which is materially better than nothing for a coolant
    /// temperature - and it travels with a basis string saying so.
    var isActionable: Bool {
        switch self {
        case .good, .suspect: return true
        case .stale, .invalid, .unavailable: return false
        }
    }

    var label: String {
        switch self {
        case .good: return "Good"
        case .suspect: return "Suspect"
        case .stale: return "Stale"
        case .invalid: return "Invalid"
        case .unavailable: return "Unavailable"
        }
    }
}

/// One `SensorGate` per metric, kept across readings.
///
/// The persistence is the entire point. `SensorSanity.check` needs the previous accepted
/// value to judge a rate of change, and `SensorGate` needs a rejection count to tell one
/// bad frame from a genuine step change. A gate constructed per reading has neither and
/// silently degrades to the stateless range check that was already there - which is very
/// close to the bug this type exists to fix.
///
/// ## Why this exists
///
/// `SensorSanity` and `SensorGate` were written, tested, and then called from nowhere:
/// `grep` found the type declaration, one internal use, and a comment in
/// `HyperionGuardian` observing that they "existed, were tested, and were reachable from
/// no production code". The live path did exactly one check - `OBDReading.isPlausible`, a
/// stateless range test computed at decode time - and `VehicleTelemetry.apply` dropped
/// anything failing it.
///
/// So the range half of the promise held, and nothing else did. A reading inside the
/// plausible band could jump 80 °C in one second, or sit byte-identical for a minute
/// while the ECU had stopped answering, or read the value a sensor sends when it has
/// nothing at all, and each was stored with full `measured` provenance and fed to the
/// baselines, the trip and the UI. Wiring the gate in at the one place telemetry is
/// admitted closes all four at once.
struct SensorGateBank: Sendable, Equatable {

    private var gates: [VehicleMetric: SensorGate] = [:]

    init() {}

    /// Offers a decoded reading to its metric's gate, creating the gate on first sight.
    ///
    /// - Parameters:
    ///   - plausibleRange: from the PID catalog, so the bands stay defined in exactly one
    ///     place. Passed per call rather than captured because the gate is created on
    ///     first reading, and the caller is the one holding the descriptor.
    ///   - engineRunning: `nil` when there is no basis to judge. Treated as not running,
    ///     which is the conservative choice: `isSensorDefault` only fires while the
    ///     engine runs, so an unknown state must not manufacture a rejection.
    /// - Returns: the value to use, or `nil` when the reading must not be admitted.
    mutating func offer(_ value: Double,
                        metric: VehicleMetric,
                        at timestamp: Date,
                        plausibleRange: ClosedRange<Double>?,
                        engineRunning: Bool?) -> Double? {
        var gate = gates[metric] ?? SensorGate(metric: metric,
                                               plausibleRange: plausibleRange,
                                               staleAfter: SensorSanity.staleAfter(for: metric))
        // The catalog is the authority on the band; adopt it even for a gate made earlier.
        gate.plausibleRange = plausibleRange
        let accepted = gate.offer(value, at: timestamp, engineRunning: engineRunning ?? false)
        gates[metric] = gate
        return accepted
    }

    /// Why this metric's most recent reading was refused, if it was.
    func rejection(for metric: VehicleMetric) -> SensorSanity.Rejection? {
        gates[metric]?.lastRejection
    }

    /// The gate's own view of a metric, last good value and honest provenance included.
    func current(_ metric: VehicleMetric) -> Provenanced<Double> {
        gates[metric]?.current ?? .unavailable()
    }

    /// Metrics a gate has been established for. Test and debug affordance.
    var trackedMetrics: Set<VehicleMetric> { Set(gates.keys) }

    /// Forgets everything. Called when the adapter changes, because the previous car's
    /// last accepted coolant temperature is not a baseline for this one's rate of change.
    mutating func reset() {
        gates.removeAll()
    }
}
