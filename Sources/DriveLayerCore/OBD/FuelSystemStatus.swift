import Foundation

/// What the fuel system is doing, from SAE J1979 mode 01 PID 03.
///
/// This exists because fuel trim numbers are meaningless without it. Short- and long-term
/// trim describe how far the ECU is correcting from its base fuel map, and that correction
/// only means anything while the engine is running closed loop on oxygen sensor feedback.
/// During a cold start, at high load, or with a failed sensor, the ECU is running open loop
/// off a lookup table and the trims are either frozen or irrelevant. Reading them then and
/// telling a driver their fuel system has drifted would be inventing a problem out of a
/// normal operating mode.
///
/// So this is decoded before trims are looked at, not alongside them.
enum FuelSystemStatus: String, Codable, CaseIterable, Sendable {

    /// Open loop: the engine is not warm enough for oxygen sensor feedback yet.
    case openLoopInsufficientTemperature
    /// Closed loop on oxygen sensor feedback. The normal warm running state, and the only
    /// one where fuel trims describe anything.
    case closedLoop
    /// Open loop because of engine load, or fuel cut on deceleration.
    case openLoopEngineLoad
    /// Open loop because the ECU has detected a system failure.
    case openLoopSystemFailure
    /// Closed loop, but with a fault on at least one oxygen sensor, so the feedback it is
    /// using is suspect.
    case closedLoopWithFault
    /// The ECU reported nothing, or a combination this decoder will not guess at.
    case unknown

    /// The bit J1979 assigns to each state. One bit, and only one, should be set.
    private var bit: UInt8? {
        switch self {
        case .openLoopInsufficientTemperature: return 0x01
        case .closedLoop: return 0x02
        case .openLoopEngineLoad: return 0x04
        case .openLoopSystemFailure: return 0x08
        case .closedLoopWithFault: return 0x10
        case .unknown: return nil
        }
    }

    /// Decodes the status byte for one fuel system.
    ///
    /// Exactly one bit set is the only valid encoding. A byte with several bits set is not
    /// a combination to be interpreted -- it is an adapter or an ECU that has answered
    /// badly, and guessing which bit was meant is how a bad frame becomes a diagnosis.
    static func decode(statusByte: UInt8) -> FuelSystemStatus {
        guard statusByte != 0, statusByte.nonzeroBitCount == 1 else { return .unknown }
        return allCases.first { $0.bit == statusByte } ?? .unknown
    }

    /// Decodes from the raw code as it travels through telemetry.
    ///
    /// Carried as a number rather than as its own telemetry type so it flows through the
    /// existing pipeline untouched: a bitfield is a number, and reconstructing the meaning
    /// at the point of use is cheaper than a parallel channel for one PID.
    static func decode(code: Double) -> FuelSystemStatus {
        guard code >= 0, code <= 255, code == code.rounded() else { return .unknown }
        return decode(statusByte: UInt8(code))
    }

    /// Whether the ECU is using oxygen sensor feedback at all.
    var isClosedLoop: Bool {
        switch self {
        case .closedLoop, .closedLoopWithFault: return true
        case .openLoopInsufficientTemperature, .openLoopEngineLoad, .openLoopSystemFailure, .unknown:
            return false
        }
    }

    /// Whether fuel trim readings taken in this state are worth comparing against a
    /// baseline.
    ///
    /// Deliberately stricter than `isClosedLoop`. Closed loop with a faulty oxygen sensor
    /// is still closed loop, but the correction it produces is a response to a broken
    /// input, so folding it into what is normal for this car would poison the baseline
    /// with the very fault it should be helping to spot.
    var allowsFuelTrimComparison: Bool { self == .closedLoop }

    var displayName: String {
        switch self {
        case .openLoopInsufficientTemperature: return "Open loop, warming up"
        case .closedLoop: return "Closed loop"
        case .openLoopEngineLoad: return "Open loop, load"
        case .openLoopSystemFailure: return "Open loop, fault"
        case .closedLoopWithFault: return "Closed loop, sensor fault"
        case .unknown: return "Unknown"
        }
    }

    /// Plain language, for a driver rather than a technician.
    var detail: String {
        switch self {
        case .openLoopInsufficientTemperature:
            return "The engine is still too cold to use its oxygen sensor, so it is running "
                 + "from its built-in fuelling map. Normal for the first few minutes."
        case .closedLoop:
            return "The engine is trimming its fuelling from live oxygen sensor readings, "
                 + "which is what it should be doing once warm."
        case .openLoopEngineLoad:
            return "The engine has stepped away from oxygen sensor feedback, which it does "
                 + "under hard acceleration and when cutting fuel on a closed throttle."
        case .openLoopSystemFailure:
            return "The engine has stopped using oxygen sensor feedback because it has "
                 + "detected a fault. Worth having the stored codes read."
        case .closedLoopWithFault:
            return "The engine is using oxygen sensor feedback but has flagged a problem "
                 + "with at least one sensor, so its fuel corrections are less reliable."
        case .unknown:
            return "This vehicle is not reporting a fuel system state DriveLayer recognises."
        }
    }

    /// Never worse than a watch on its own.
    ///
    /// Open loop is a normal operating mode for most of these reasons, and the two that do
    /// suggest a fault are already reported through the stored codes. A loop state alone is
    /// not evidence enough to escalate past "worth a look".
    var status: SemanticStatus {
        switch self {
        case .closedLoop: return .normal
        case .openLoopInsufficientTemperature, .openLoopEngineLoad: return .normal
        case .openLoopSystemFailure, .closedLoopWithFault: return .watch
        case .unknown: return .unknown
        }
    }
}
