import Foundation

/// An in-process adapter that speaks ELM327 text.
///
/// It is a `OBDTransport` like any other, so the app's parser, decoders, capability
/// discovery and session state machine all run unchanged against it. Simulator code
/// never reaches into the production path; the production path reaches the simulator
/// only through this protocol.
actor SimulatedOBDTransport: OBDTransport {

    nonisolated let identifier: String
    nonisolated let displayName: String

    private var model: SimulatedVehicleModel
    private let dateProvider: DateProviding
    private var lastAdvance: Date?
    private var isConnected = false
    /// Deterministic cursor for the invalid-response scenario.
    private var faultCursor = 0

    init(scenario: OBDScenarioID = .normalHighway,
         tankLitres: Double = 50,
         dateProvider: DateProviding = SystemDateProvider(),
         seed: UInt64 = 42) {
        self.identifier = "simulator.\(scenario.rawValue)"
        self.displayName = "Simulated adapter — \(OBDScenario.named(scenario).title)"
        self.model = SimulatedVehicleModel(scenario: scenario, tankLitres: tankLitres, seed: seed)
        self.dateProvider = dateProvider
    }

    // MARK: - OBDTransport

    func connect() async throws {
        isConnected = true
        lastAdvance = dateProvider.now
    }

    func disconnect() async {
        isConnected = false
    }

    func send(_ command: String, timeout: TimeInterval) async throws -> String {
        guard isConnected else { throw OBDError.notConnected }
        advanceModel()

        if model.state.linkIsDown { throw OBDError.connectionLost }

        let normalised = command.uppercased().filter { !$0.isWhitespace }

        if normalised.hasPrefix("AT") {
            return atReply(for: normalised)
        }

        if model.state.emitsInvalidResponses, let fault = nextFaultReply() {
            return fault
        }

        return vehicleReply(for: normalised)
    }

    // MARK: - Debug Center support

    func currentState() -> SimulatedVehicleState {
        advanceModel()
        return model.state
    }

    func scenario() -> OBDScenarioID { model.scenario }

    /// Switches scenario and restarts the simulated drive from zero.
    func setScenario(_ scenario: OBDScenarioID, tankLitres: Double = 50, seed: UInt64 = 42) {
        model = SimulatedVehicleModel(scenario: scenario, tankLitres: tankLitres, seed: seed)
        lastAdvance = dateProvider.now
        faultCursor = 0
    }

    private func advanceModel() {
        let now = dateProvider.now
        guard let last = lastAdvance else {
            lastAdvance = now
            return
        }
        let elapsed = now.timeIntervalSince(last)
        if elapsed > 0 {
            model.advance(by: elapsed)
            lastAdvance = now
        }
    }

    // MARK: - Replies

    private func atReply(for command: String) -> String {
        switch command {
        case ATCommand.reset.rawValue:
            return "ELM327 v1.5\r\r>"
        case ATCommand.describeProtocolNumber.rawValue:
            return "A6\r\r>"
        case ATCommand.readVoltage.rawValue:
            return String(format: "%.1fV\r\r>", model.state.controlModuleVoltage)
        default:
            return "OK\r\r>"
        }
    }

    /// Cycles deterministically through the failure shapes a cheap adapter produces.
    private func nextFaultReply() -> String? {
        faultCursor += 1
        switch faultCursor % 6 {
        case 1: return "41 0C 1A\r\r>"          // truncated: fewer bytes than the PID needs
        case 2: return "41 ZZ 00 00\r\r>"       // non-hex token
        case 3: return "NO DATA\r\r>"
        case 4: return "?\r\r>"
        case 5: return "BUFFER FULL\r\r>"
        default: return nil                     // one good reply in six keeps the drive alive
        }
    }

    private func vehicleReply(for request: String) -> String {
        guard request.count >= 2, let mode = UInt8(request.prefix(2), radix: 16) else {
            return "?\r\r>"
        }

        switch mode {
        case 0x01:
            guard request.count >= 4, let code = UInt8(request.dropFirst(2).prefix(2), radix: 16) else {
                return "?\r\r>"
            }
            guard model.state.supportedCodes.contains(code) else { return "NO DATA\r\r>" }
            guard let payload = encode(code: code) else { return "NO DATA\r\r>" }
            let bytes = [UInt8(0x41), code] + payload
            return frame(bytes)

        case 0x03:
            return dtcFrame(codes: model.state.storedCodes, responseByte: 0x43)

        case 0x07:
            return dtcFrame(codes: model.state.pendingCodes, responseByte: 0x47)

        case 0x0A:
            return dtcFrame(codes: [], responseByte: 0x4A)

        default:
            // Mirrors a real ECU refusing an unsupported service.
            return frame([0x7F, mode, 0x11])
        }
    }

    private func dtcFrame(codes: [String], responseByte: UInt8) -> String {
        let pairs = codes.compactMap { DTCDecoder.encode($0) }
        guard !pairs.isEmpty else {
            // "No codes" is reported as a count of zero, which is a valid answer.
            return frame([responseByte, 0x00, 0x00, 0x00])
        }
        var bytes: [UInt8] = [responseByte, UInt8(pairs.count)]
        for pair in pairs {
            bytes.append(pair.0)
            bytes.append(pair.1)
        }
        return frame(bytes)
    }

    private func frame(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", Int($0)) }.joined(separator: " ") + "\r\r>"
    }

    // MARK: - Value encoding
    //
    // These are the exact inverses of the catalog's decoders, which is what makes a
    // simulated drive a real test of the decoding path.

    private func byte(_ value: Double) -> UInt8 {
        UInt8(Statistics.clamp(value.rounded(), 0...255))
    }

    private func word(_ value: Double) -> [UInt8] {
        let clamped = Int(Statistics.clamp(value.rounded(), 0...65_535))
        return [UInt8(clamped >> 8), UInt8(clamped & 0xFF)]
    }

    private func percentByte(_ percent: Double) -> UInt8 {
        byte(Statistics.clamp(percent, 0...100) * 255.0 / 100.0)
    }

    private func encode(code: UInt8) -> [UInt8]? {
        let state = model.state
        switch code {
        case 0x00, 0x20, 0x40, 0x60, 0x80, 0xA0, 0xC0:
            return OBDSupportBitmap.encode(base: code, codes: state.supportedCodes)
        case 0x01:
            let count = UInt8(min(state.storedCodes.count, 0x7F))
            let statusByte = (state.milOn ? 0x80 : 0x00) | count
            return [statusByte, 0x07, 0xE5, 0x00]
        case 0x04: return [percentByte(state.engineLoadPercent)]
        case 0x05: return [byte(state.coolantC + 40)]
        case 0x0B: return [byte(state.manifoldPressureKPa)]
        case 0x0C: return word(state.rpm * 4)
        case 0x0D: return [byte(state.speedKmh)]
        case 0x0E: return [byte((10.0 + 64.0) * 2.0)]
        case 0x0F: return [byte(state.intakeAirC + 40)]
        case 0x10:
            let gramsPerSecond = (state.engineLoadPercent / 100) * (state.rpm / 1_000) * 30
            return word(gramsPerSecond * 100)
        case 0x11: return [percentByte(state.throttlePercent)]
        case 0x1F: return word(state.runtimeSeconds)
        case 0x21: return word(state.milOn ? 145 : 0)
        case 0x2F: return [percentByte(state.fuelLevelPercent)]
        case 0x31: return word(1_284)
        case 0x33: return [byte(101)]
        case 0x42: return word(state.controlModuleVoltage * 1_000)
        case 0x43: return word(state.engineLoadPercent * 255.0 / 100.0)
        case 0x45: return [percentByte(state.throttlePercent * 0.9)]
        case 0x46: return [byte(state.ambientC + 40)]
        case 0x47: return [percentByte(state.throttlePercent)]
        case 0x4C: return [percentByte(state.throttlePercent)]
        case 0x51: return [4]
        case 0x5A: return [percentByte(state.throttlePercent * 0.85)]
        case 0x5C: return [byte(state.coolantC - 4 + 40)]
        case 0x5E: return word(state.fuelRateLitresPerHour * 20)
        default: return nil
        }
    }
}
