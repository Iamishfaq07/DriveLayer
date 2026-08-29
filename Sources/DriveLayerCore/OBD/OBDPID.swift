import Foundation

/// Standard OBD-II service (mode) numbers DriveLayer uses. All are read-only.
///
/// Modes that write to or reconfigure the vehicle — notably mode 04 (clear
/// diagnostic information) and any manufacturer control routine — are deliberately
/// absent. See docs/OBD.md, "Read-only policy".
enum OBDMode: UInt8, Codable, CaseIterable, Sendable {
    /// Current data.
    case currentData = 0x01
    /// Freeze frame data.
    case freezeFrame = 0x02
    /// Stored diagnostic trouble codes.
    case storedDTCs = 0x03
    /// Pending diagnostic trouble codes.
    case pendingDTCs = 0x07
    /// Vehicle information (VIN, calibration IDs).
    case vehicleInformation = 0x09
    /// Permanent diagnostic trouble codes.
    case permanentDTCs = 0x0A

    /// Positive responses echo the mode with 0x40 added.
    var positiveResponseByte: UInt8 { rawValue &+ 0x40 }

    /// Whether the request carries a PID byte after the mode.
    var carriesPID: Bool {
        switch self {
        case .currentData, .freezeFrame, .vehicleInformation: return true
        case .storedDTCs, .pendingDTCs, .permanentDTCs: return false
        }
    }
}

/// Identifies one request: a mode plus, where applicable, a parameter id.
struct OBDPID: Hashable, Codable, Sendable, CustomStringConvertible {
    var mode: OBDMode
    var code: UInt8?

    init(mode: OBDMode, code: UInt8? = nil) {
        self.mode = mode
        self.code = mode.carriesPID ? code : nil
    }

    /// Convenience for the common case: a mode 01 current-data parameter.
    static func current(_ code: UInt8) -> OBDPID {
        OBDPID(mode: .currentData, code: code)
    }

    var description: String {
        if let code {
            return String(format: "%02X%02X", Int(mode.rawValue), Int(code))
        }
        return String(format: "%02X", Int(mode.rawValue))
    }

    /// The ASCII request sent to an ELM327-compatible adapter, without terminator.
    var requestString: String { description }
}
