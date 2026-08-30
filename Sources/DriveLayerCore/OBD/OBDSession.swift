import Foundation

/// Owns one adapter connection: brings it to a known state, discovers what the
/// vehicle reports, and serves decoded readings.
///
/// An actor because a session is shared by the drive screen, CarPlay, the trip
/// recorder and the Debug Center at once, and the adapter is strictly one request
/// at a time.
actor OBDSession {

    private let transport: OBDTransport
    private let dateProvider: DateProviding
    private let requestTimeout: TimeInterval

    private(set) var state: OBDConnectionState = .disconnected
    private(set) var capabilities: OBDCapabilityReport?
    private(set) var adapterIdentity: String?
    private(set) var protocolDescription: String?

    /// PIDs this vehicle answered "no" to. Asking again every second wastes bus time.
    private var knownUnsupported: Set<OBDPID> = []
    private var consecutiveTransientFailures: [OBDPID: Int] = [:]
    /// Set when repeated transient failures suggest the link is unhealthy.
    private var degradedReason: String?

    /// After this many transient failures a PID is rested until the next session.
    private let transientFailureLimit = 5

    init(transport: OBDTransport,
         dateProvider: DateProviding = SystemDateProvider(),
         requestTimeout: TimeInterval = 2.0) {
        self.transport = transport
        self.dateProvider = dateProvider
        self.requestTimeout = requestTimeout
    }

    var transportIdentifier: String { transport.identifier }
    var transportName: String { transport.displayName }

    // MARK: - Lifecycle

    func start() async throws {
        state = .connecting
        do {
            try await transport.connect()
        } catch let error as OBDError {
            state = .failed(error)
            throw error
        } catch {
            let wrapped = OBDError.connectionFailed(error.localizedDescription)
            state = .failed(wrapped)
            throw wrapped
        }

        state = .initialising
        for command in ATCommand.initialisationSequence {
            let reply = try await sendRaw(command.rawValue)
            if command == .reset {
                adapterIdentity = reply
                    .replacingOccurrences(of: "\r", with: " ")
                    .replacingOccurrences(of: ">", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        protocolDescription = try? await describeProtocol()

        state = .discovering
        let discovery = OBDCapabilityDiscovery(now: { [dateProvider] in dateProvider.now }) { [weak self] pid in
            guard let self else { throw OBDError.notConnected }
            return try await self.request(pid, respectingCapabilities: false)
        }
        let report = await discovery.discover()
        capabilities = report
        state = report.isEmpty
            ? .degraded(reason: "your car didn't list any standard parameters")
            : .ready
    }

    func stop() async {
        await transport.disconnect()
        state = .disconnected
        degradedReason = nil
    }

    /// Clears the per-session learning. Used when the driver switches vehicles.
    func resetLearnedState() {
        knownUnsupported.removeAll()
        consecutiveTransientFailures.removeAll()
        capabilities = nil
        degradedReason = nil
    }

    // MARK: - Requests

    /// Sends a request and parses the reply.
    ///
    /// - Parameter respectingCapabilities: when true (the default) a PID the vehicle
    ///   has already refused is rejected locally instead of being asked again.
    func request(_ pid: OBDPID, respectingCapabilities: Bool = true) async throws -> OBDResponse {
        if respectingCapabilities {
            if knownUnsupported.contains(pid) { throw OBDError.pidNotSupported(pid) }
            // canAttempt, not supports: an unknown diagnostic mode must still be asked.
            if let capabilities, !capabilities.canAttempt(pid) { throw OBDError.pidNotSupported(pid) }
        }

        do {
            let raw = try await sendRaw(pid.requestString)
            let response = try OBDResponseParser.parse(raw: raw, for: pid)
            consecutiveTransientFailures[pid] = 0
            if degradedReason != nil, case .degraded = state {
                degradedReason = nil
                state = .ready
            }
            return response
        } catch let error as OBDError {
            note(error, for: pid)
            throw error
        }
    }

    /// Requests a PID and decodes it. Throws rather than returning a placeholder:
    /// an absent value must never reach the UI as a zero.
    func read(_ pid: OBDPID) async throws -> OBDReading {
        guard let descriptor = OBDPIDCatalog.descriptor(for: pid) else {
            throw OBDError.noDecoderAvailable(pid)
        }
        let response = try await request(pid)
        return try descriptor.makeReading(from: response.data, at: dateProvider.now)
    }

    /// Reads several PIDs, skipping the ones this vehicle doesn't support.
    /// Individual failures are reported alongside the successes, never swallowed.
    func read(_ pids: [OBDPID]) async -> (readings: [OBDReading], failures: [(OBDPID, OBDError)]) {
        var readings: [OBDReading] = []
        var failures: [(OBDPID, OBDError)] = []
        for pid in pids {
            do {
                readings.append(try await read(pid))
            } catch let error as OBDError {
                failures.append((pid, error))
            } catch {
                failures.append((pid, .malformedResponse(error.localizedDescription)))
            }
        }
        return (readings, failures)
    }

    /// Reads stored, pending and permanent codes, as far as the vehicle allows.
    ///
    /// Every call resolves a little more of what the vehicle actually supports: a mode
    /// that answers is marked `.supported`, a mode that rejects the request outright is
    /// marked `.unsupported`, and a mode that answers `NO DATA` is left `.unknown` so
    /// it is asked again next time. Nothing here is decided once and for all from the
    /// first reply.
    func readDiagnosticCodes() async -> (codes: [DiagnosticTroubleCode], notes: [String]) {
        var codes: [DiagnosticTroubleCode] = []
        var notes: [String] = []
        let modes: [(OBDMode, DTCStatus)] = [
            (.storedDTCs, .stored), (.pendingDTCs, .pending), (.permanentDTCs, .permanent)
        ]
        for (mode, status) in modes {
            let pid = OBDPID(mode: mode)
            do {
                let response = try await request(pid)
                record(mode: mode, support: .supported)
                codes.append(contentsOf: DTCDecoder.decodeList(from: response, status: status))
            } catch let error as OBDError {
                switch error {
                case .noData:
                    // Ambiguous, so nothing is learned and nothing is ruled out.
                    continue
                case .pidNotSupported:
                    continue
                case .negativeResponse, .unrecognisedCommand:
                    // A definite refusal, unlike NO DATA. Worth remembering.
                    record(mode: mode, support: .unsupported)
                    notes.append("Mode " + String(format: "%02X", Int(mode.rawValue)) + ": " + error.userMessage)
                default:
                    notes.append("Mode " + String(format: "%02X", Int(mode.rawValue)) + ": " + error.userMessage)
                }
            } catch {
                continue
            }
        }
        return (codes, notes)
    }

    /// Whether fault codes can be reported on at all, for the UI to distinguish
    /// "no known active codes" from "diagnostics unavailable".
    var canReportDiagnostics: Bool {
        guard let capabilities else { return true }
        return capabilities.canReportDiagnostics
    }

    /// Folds what a diagnostic mode just did back into the capability report.
    private func record(mode: OBDMode, support: ModeSupport) {
        guard var report = capabilities else { return }
        switch mode {
        case .storedDTCs: report.storedDTCSupport = support
        case .pendingDTCs: report.pendingDTCSupport = support
        case .permanentDTCs: report.permanentDTCSupport = support
        case .currentData, .freezeFrame, .vehicleInformation: return
        }
        capabilities = report
    }

    /// Battery voltage measured by the adapter at the OBD port.
    ///
    /// A useful fallback when the vehicle doesn't report PID 42, but it is the
    /// adapter's measurement, not the ECU's — the basis string says so.
    func readAdapterVoltage() async -> Provenanced<Double> {
        do {
            let reply = try await sendRaw(ATCommand.readVoltage.rawValue)
            let cleaned = reply
                .uppercased()
                .replacingOccurrences(of: "V", with: " ")
                .replacingOccurrences(of: ">", with: " ")
            let candidate = cleaned
                .split(whereSeparator: { !$0.isNumber && $0 != "." })
                .compactMap { Double($0) }
                .first
            guard let candidate, candidate > 4, candidate < 30 else {
                return .unavailable(basis: "The adapter didn't report a usable voltage.")
            }
            return .measured(candidate, at: dateProvider.now)
                .withBasis("Measured at the OBD port by the adapter, not by the engine control module.")
        } catch {
            return .unavailable(basis: "The adapter didn't answer the voltage request.")
        }
    }

    private func describeProtocol() async throws -> String {
        let reply = try await sendRaw(ATCommand.describeProtocolNumber.rawValue)
        let cleaned = reply
            .replacingOccurrences(of: ">", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return OBDProtocolNames.description(forNumberString: cleaned)
    }

    private func sendRaw(_ command: String) async throws -> String {
        do {
            return try await transport.send(command, timeout: requestTimeout)
        } catch let error as OBDError {
            if case .connectionLost = error { state = .failed(.connectionLost) }
            throw error
        } catch {
            throw OBDError.malformedResponse(error.localizedDescription)
        }
    }

    /// Records what a failure means for future polling.
    private func note(_ error: OBDError, for pid: OBDPID) {
        if error.suggestsUnsupported {
            // NO DATA from a diagnostic mode is not a "no". A car with nothing stored
            // answers exactly that way, and adding it here used to be the second of
            // two independent permanent blocks - the capability report said unknown
            // and this said never ask again, so a fault appearing later went unseen.
            if case .noData = error, pid.mode.isDiagnostic { return }
            knownUnsupported.insert(pid)
            consecutiveTransientFailures[pid] = 0
            return
        }
        guard error.isTransient else { return }
        let count = (consecutiveTransientFailures[pid] ?? 0) + 1
        consecutiveTransientFailures[pid] = count
        if count >= transientFailureLimit {
            knownUnsupported.insert(pid)
            let reason = "\(OBDPIDCatalog.descriptor(for: pid)?.shortName ?? pid.description) stopped answering"
            degradedReason = reason
            if state.isUsable { state = .degraded(reason: reason) }
        }
    }

    // MARK: - Introspection for the Debug Center

    var unsupportedPIDs: [OBDPID] { knownUnsupported.sorted { $0.description < $1.description } }
}

/// Maps `ATDPN` replies to readable protocol names.
enum OBDProtocolNames {
    static func description(forNumberString value: String) -> String {
        // The reply may be prefixed with "A" when the protocol was found automatically.
        let trimmed = value.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let isAutomatic = trimmed.hasPrefix("A")
        let digits = trimmed.hasPrefix("A") ? String(trimmed.dropFirst()) : trimmed
        let name: String
        switch digits {
        case "0": name = "Automatic"
        case "1": name = "SAE J1850 PWM"
        case "2": name = "SAE J1850 VPW"
        case "3": name = "ISO 9141-2"
        case "4": name = "ISO 14230-4 KWP (5 baud init)"
        case "5": name = "ISO 14230-4 KWP (fast init)"
        case "6": name = "ISO 15765-4 CAN (11 bit, 500 kbit)"
        case "7": name = "ISO 15765-4 CAN (29 bit, 500 kbit)"
        case "8": name = "ISO 15765-4 CAN (11 bit, 250 kbit)"
        case "9": name = "ISO 15765-4 CAN (29 bit, 250 kbit)"
        case "A": name = "SAE J1939 CAN"
        default: name = "Unknown protocol (\(digits))"
        }
        return isAutomatic ? "\(name), found automatically" : name
    }
}

extension Provenanced {
    /// Attaches an explanation of how a value was obtained.
    func withBasis(_ basis: String) -> Provenanced<Value> {
        var copy = self
        copy.basis = basis
        return copy
    }
}
