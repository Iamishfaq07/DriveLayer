import Foundation

/// Mode 01 PID 01: the warning lamp, the stored fault count, and which of the ECU's
/// self-tests have finished.
///
/// This used to be decoded straight to a display string — `"MIL on, 3 stored"` — with
/// `metric: nil`, so nothing downstream could act on it. That is the whole reason
/// diagnostics were read only on connect and on demand: there was no structured value to
/// notice a change in, so nothing could trigger a refresh.
struct MonitorStatus: Sendable, Equatable, Codable {

    /// The malfunction indicator lamp — the check engine light.
    var isWarningLampOn: Bool

    /// Confirmed, stored faults. Not the same as pending ones, which live in mode 07.
    var confirmedFaultCount: Int

    /// Readiness of the ECU's self-tests, where it was reported.
    ///
    /// Nil when only the lamp byte was available. Readiness lives in bytes B to D, and the
    /// telemetry path carries a single number per metric — so a value assembled from that
    /// path knows the lamp and the count and honestly does not know this.
    var readiness: Readiness?

    /// How far through its self-tests the ECU has got.
    ///
    /// Worth surfacing rather than hiding: a car that has just had its battery
    /// disconnected reports no faults because it has not finished looking, which is a very
    /// different statement from a clean bill of health.
    struct Readiness: Sendable, Equatable, Codable {
        var supportedCount: Int
        var completeCount: Int

        var isComplete: Bool { supportedCount > 0 && completeCount == supportedCount }
        var fraction: Double? {
            guard supportedCount > 0 else { return nil }
            return Double(completeCount) / Double(supportedCount)
        }
    }

    // MARK: - Decoding

    /// The lamp byte: bit 7 is the lamp, bits 0 to 6 are the stored fault count.
    static func decode(code: Double) -> MonitorStatus? {
        guard code >= 0, code <= 255, code == code.rounded() else { return nil }
        return decode(lampByte: UInt8(code))
    }

    static func decode(lampByte: UInt8) -> MonitorStatus {
        MonitorStatus(isWarningLampOn: (lampByte & 0x80) != 0,
                      confirmedFaultCount: Int(lampByte & 0x7F),
                      readiness: nil)
    }

    /// The full four-byte response, readiness included.
    ///
    /// Bytes B to D carry two parallel bitfields per monitor group: one saying whether a
    /// test is supported on this vehicle, one saying whether it has finished. A test that
    /// is not supported is not incomplete — it does not exist — so unsupported bits are
    /// excluded from both counts rather than counted as outstanding.
    static func decode(bytes: [UInt8]) -> MonitorStatus? {
        guard bytes.count >= 4 else { return nil }
        var status = decode(lampByte: bytes[0])

        let b = bytes[1]
        // Byte B, low three bits: the three continuously monitored systems are supported.
        // Bits 4 to 6: the same three are incomplete.
        var supported = 0
        var complete = 0
        for index in 0..<3 {
            let isSupported = (b & (1 << index)) != 0
            guard isSupported else { continue }
            supported += 1
            let isIncomplete = (b & (1 << (index + 4))) != 0
            if !isIncomplete { complete += 1 }
        }

        // Bytes C and D: the non-continuous monitors, supported in C and incomplete in D,
        // bit for bit. Which physical monitors these are depends on whether the engine is
        // spark or compression ignition, and that distinction does not change the counting.
        let c = bytes[2]
        let d = bytes[3]
        for index in 0..<8 {
            let isSupported = (c & (1 << index)) != 0
            guard isSupported else { continue }
            supported += 1
            let isIncomplete = (d & (1 << index)) != 0
            if !isIncomplete { complete += 1 }
        }

        status.readiness = Readiness(supportedCount: supported, completeCount: complete)
        return status
    }

    // MARK: - Presentation

    /// Replaces the string the decoder used to produce, so nothing lost a way to show it.
    var displayName: String {
        let lamp = isWarningLampOn ? "Check engine light on" : "No warning light"
        switch confirmedFaultCount {
        case 0: return lamp
        case 1: return "\(lamp), 1 stored code"
        default: return "\(lamp), \(confirmedFaultCount) stored codes"
        }
    }

    /// The lamp is the vehicle telling the driver something. It is reported as attention
    /// rather than critical: it means have this looked at, not stop the car — and
    /// DriveLayer is not in a position to know which.
    var status: SemanticStatus {
        if isWarningLampOn { return .attention }
        if confirmedFaultCount > 0 { return .watch }
        if let readiness, !readiness.isComplete { return .unknown }
        return .normal
    }

    var detail: String {
        if isWarningLampOn {
            return "The vehicle has turned on its check engine light and stored at least one "
                 + "fault code. Reading the codes will say which system reported it."
        }
        if confirmedFaultCount > 0 {
            return "There are stored fault codes but no warning light, which usually means a "
                 + "fault that has not recurred."
        }
        if let readiness, !readiness.isComplete {
            return "No faults stored, but the vehicle has not finished its self-tests "
                 + "(\(readiness.completeCount) of \(readiness.supportedCount) complete). "
                 + "That is normal after a battery disconnect or a recent code clear."
        }
        return "No stored faults, and the vehicle has finished its self-tests."
    }
}
