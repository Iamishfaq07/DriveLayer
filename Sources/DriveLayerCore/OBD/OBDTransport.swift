import Foundation

/// The single boundary between DriveLayer and whatever physically carries OBD-II
/// traffic. Bluetooth code lives behind this in the app target; the simulator
/// implements the same protocol and speaks the same text, so simulated drives run
/// through the real parser and decoders rather than around them.
///
/// Adding Wi-Fi or a wired adapter later means adding one conformance, nothing else.
protocol OBDTransport: AnyObject, Sendable {
    /// Stable identifier for the adapter (e.g. a peripheral UUID). Never logged in full.
    var identifier: String { get }
    var displayName: String { get }

    func connect() async throws
    func disconnect() async

    /// Sends one request and returns the adapter's raw reply, with the trailing
    /// prompt included or stripped — the parser tolerates both.
    func send(_ command: String, timeout: TimeInterval) async throws -> String
}

/// Adapter-level configuration commands. All are ELM327 housekeeping; none of them
/// write to the vehicle.
enum ATCommand: String, CaseIterable, Sendable {
    case reset = "ATZ"
    case echoOff = "ATE0"
    case linefeedsOff = "ATL0"
    case headersOff = "ATH0"
    case spacesOn = "ATS1"
    case adaptiveTiming = "ATAT1"
    case automaticProtocol = "ATSP0"
    case describeProtocolNumber = "ATDPN"
    case readVoltage = "ATRV"

    /// The order used to bring an adapter to a known state.
    ///
    /// Spaces are left on deliberately: the throughput saved by `ATS0` is not worth
    /// the parsing ambiguity between a CAN header and a run of data bytes.
    static var initialisationSequence: [ATCommand] {
        [.reset, .echoOff, .linefeedsOff, .headersOff, .spacesOn, .adaptiveTiming, .automaticProtocol]
    }
}

enum OBDConnectionState: Equatable, Sendable {
    case disconnected
    case scanning
    case connecting
    /// Connected to the adapter, configuring it.
    case initialising
    /// Asking the vehicle what it can report.
    case discovering
    case ready
    /// Connected and usable, but something is degraded (e.g. several PIDs stopped answering).
    case degraded(reason: String)
    case failed(OBDError)

    var isUsable: Bool {
        switch self {
        case .ready, .degraded: return true
        default: return false
        }
    }

    var userDescription: String {
        switch self {
        case .disconnected: return "Not connected"
        case .scanning: return "Looking for adapters"
        case .connecting: return "Connecting"
        case .initialising: return "Setting up the adapter"
        case .discovering: return "Asking your car what it reports"
        case .ready: return "Connected"
        case let .degraded(reason): return "Connected — \(reason)"
        case let .failed(error): return error.userMessage
        }
    }
}
