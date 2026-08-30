import Foundation

/// Owns the adapter connection for the whole app.
///
/// One session, one polling loop, shared by the Drive screen, CarPlay, the trip
/// recorder and the Debug Center. Polling is driven by each parameter's refresh
/// class, so engine speed is asked for every second while battery voltage is asked
/// for every half minute — the difference matters over a three-hour drive.
@MainActor
@Observable
final class OBDConnectionManager {

    enum Source: Equatable {
        case bluetooth(peripheralID: UUID?, name: String)
        case simulator(OBDScenarioID)

        var isSimulated: Bool {
            if case .simulator = self { return true }
            return false
        }
    }

    private(set) var state: OBDConnectionState = .disconnected
    private(set) var capabilities: OBDCapabilityReport?
    private(set) var telemetry = VehicleTelemetry(updatedAt: .distantPast)
    private(set) var troubleCodes: [DiagnosticTroubleCode] = []
    private(set) var adapterIdentity: String?
    private(set) var protocolDescription: String?
    private(set) var source: Source?
    /// Recent failures, newest first, for the Debug Center. Never silently discarded.
    private(set) var recentIssues: [String] = []
    private(set) var adapterVoltage: Provenanced<Double> = .unavailable()

    /// True while the app is in the foreground and showing live data; drives how
    /// often the adapter is polled.
    var isForeground = true

    private var session: OBDSession?
    private var transport: OBDTransport?
    private var pollingTask: Task<Void, Never>?
    private var lastRead: [UInt8: Date] = [:]
    private let maximumIssues = 20

    var isConnected: Bool { state.isUsable }

    var capabilityLevel: VehicleCapabilityLevel {
        VehicleCapabilityLevel.current(profile: nil, isAdapterConnected: isConnected)
    }

    // MARK: - Lifecycle

    func connect(source: Source) async {
        await disconnect()
        self.source = source

        let transport: OBDTransport
        switch source {
        case let .bluetooth(peripheralID, name):
            transport = BluetoothOBDTransport(peripheralID: peripheralID, displayName: name)
        case let .simulator(scenario):
            transport = SimulatedOBDTransport(scenario: scenario)
        }
        self.transport = transport

        let session = OBDSession(transport: transport)
        self.session = session
        state = .connecting

        do {
            try await session.start()
            state = await session.state
            capabilities = await session.capabilities
            adapterIdentity = await session.adapterIdentity
            protocolDescription = await session.protocolDescription
            adapterVoltage = await session.readAdapterVoltage()
            startPolling()
            await refreshTroubleCodes()
        } catch let error as OBDError {
            state = .failed(error)
            note(error.userMessage)
        } catch {
            state = .failed(.connectionFailed(error.localizedDescription))
            note(error.localizedDescription)
        }
    }

    func disconnect() async {
        pollingTask?.cancel()
        pollingTask = nil
        await session?.stop()
        session = nil
        transport = nil
        state = .disconnected
        capabilities = nil
        telemetry = VehicleTelemetry(updatedAt: .distantPast)
        troubleCodes = []
        adapterVoltage = .unavailable()
        lastRead.removeAll()
    }

    /// Reconnects on the same source, used after a dropped link.
    func reconnect() async {
        guard let source else { return }
        await connect(source: source)
    }

    // MARK: - Polling

    private func startPolling() {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollDueParameters()
                // A quarter-second tick is fine-grained enough for the fastest
                // parameter and cheap enough to leave the radio mostly idle.
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func pollDueParameters() async {
        guard let session, let capabilities else { return }
        let now = Date()
        let due = capabilities.decodableDescriptors.filter { descriptor in
            guard let code = descriptor.pid.code else { return false }
            let interval = isForeground ? descriptor.refresh.interval : descriptor.refresh.backgroundInterval
            guard let last = lastRead[code] else { return true }
            return now.timeIntervalSince(last) >= interval
        }
        guard !due.isEmpty else { return }

        for descriptor in due {
            guard !Task.isCancelled else { return }
            do {
                let reading = try await session.read(descriptor.pid)
                if let code = descriptor.pid.code { lastRead[code] = Date() }
                telemetry.apply(reading)
                if !reading.isPlausible {
                    note("\(reading.name) returned an implausible value and was ignored.")
                }
            } catch let error as OBDError {
                if let code = descriptor.pid.code { lastRead[code] = Date() }
                if case .connectionLost = error {
                    state = .failed(.connectionLost)
                    note(error.userMessage)
                    return
                }
                if !error.suggestsUnsupported {
                    note("\(descriptor.name): \(error.userMessage)")
                }
            } catch {
                note(error.localizedDescription)
            }
        }
        state = await session.state
    }

    // MARK: - Diagnostics

    func refreshTroubleCodes() async {
        guard let session else { return }
        let result = await session.readDiagnosticCodes()
        troubleCodes = result.codes
        for note in result.notes { self.note(note) }
    }

    func refreshAdapterVoltage() async {
        guard let session else { return }
        adapterVoltage = await session.readAdapterVoltage()
    }

    /// Everything the vehicle reports that DriveLayer cannot yet interpret, for the
    /// Debug Center. Shown rather than hidden, because it is the honest answer.
    var undecodedParameterNames: [String] {
        (capabilities?.reportedButNotDecodable ?? []).map { OBDPIDCatalog.displayName(forCode: $0) }
    }

    func unsupportedPIDs() async -> [OBDPID] {
        await session?.unsupportedPIDs ?? []
    }

    private func note(_ message: String) {
        recentIssues.insert("\(Date().formatted(date: .omitted, time: .standard)) — \(message)", at: 0)
        if recentIssues.count > maximumIssues { recentIssues.removeLast(recentIssues.count - maximumIssues) }
    }
}
