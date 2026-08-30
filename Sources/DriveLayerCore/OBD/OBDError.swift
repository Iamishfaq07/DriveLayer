import Foundation

/// Everything that can go wrong between the app and the vehicle. Each case maps to
/// a specific piece of user-facing copy — none of them are ever silently swallowed.
enum OBDError: Error, Equatable, Sendable {
    /// The adapter is not connected or the link dropped.
    case notConnected
    case connectionFailed(String)
    case connectionLost
    /// The adapter accepted the request but produced nothing within the timeout.
    case timeout
    /// "NO DATA" — the ECU did not answer. Usually an unsupported PID or engine off.
    case noData
    /// "?" — the adapter did not understand the request.
    case unrecognisedCommand
    /// "STOPPED" — the adapter aborted the request.
    case stopped
    case unableToConnectToVehicle
    case busError(String)
    case bufferFull
    /// The ECU replied with a negative response (0x7F).
    case negativeResponse(mode: UInt8, code: UInt8)
    /// Bytes arrived but did not form a response to what we asked.
    case mismatchedResponse(expected: String, received: String)
    /// The response was too short, unparseable, or contained non-hex data.
    case malformedResponse(String)
    /// Requested a PID that capability discovery says this vehicle does not support.
    case pidNotSupported(OBDPID)
    /// The adapter answered, but the catalog has no verified decoder for that PID.
    case noDecoderAvailable(OBDPID)

    /// True when retrying the exact same request could reasonably succeed.
    var isTransient: Bool {
        switch self {
        case .timeout, .busError, .bufferFull, .stopped, .connectionLost:
            return true
        case .notConnected, .connectionFailed, .noData, .unrecognisedCommand,
             .unableToConnectToVehicle, .negativeResponse, .mismatchedResponse,
             .malformedResponse, .pidNotSupported, .noDecoderAvailable:
            return false
        }
    }

    /// Whether this outcome means "stop asking for this PID on this vehicle".
    var suggestsUnsupported: Bool {
        switch self {
        case .noData, .pidNotSupported, .negativeResponse, .noDecoderAvailable:
            return true
        default:
            return false
        }
    }

    var userMessage: String {
        switch self {
        case .notConnected:
            return "No OBD adapter is connected."
        case let .connectionFailed(detail):
            return "Couldn't connect to the adapter. \(detail)"
        case .connectionLost:
            return "Lost the connection to the adapter."
        case .timeout:
            return "The adapter didn't respond in time."
        case .noData:
            return "The vehicle didn't report this value."
        case .unrecognisedCommand:
            return "The adapter didn't understand that request."
        case .stopped:
            return "The adapter stopped the request."
        case .unableToConnectToVehicle:
            return "The adapter couldn't reach the vehicle. Check the ignition is on."
        case let .busError(detail):
            return "Vehicle bus error. \(detail)"
        case .bufferFull:
            return "The adapter's buffer overflowed."
        case let .negativeResponse(mode, code):
            return String(format: "The vehicle rejected request %02X (reason %02X).", Int(mode), Int(code))
        case .mismatchedResponse:
            return "The adapter's reply didn't match the request."
        case let .malformedResponse(detail):
            return "Couldn't read the adapter's reply. \(detail)"
        case let .pidNotSupported(pid):
            return "This vehicle doesn't report \(pid.description)."
        case let .noDecoderAvailable(pid):
            return "DriveLayer has no verified way to interpret \(pid.description) yet."
        }
    }
}
