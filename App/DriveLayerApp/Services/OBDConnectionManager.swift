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
    /// The vehicle's own summary of its faults and self-tests, readiness included.
    ///
    /// Kept here beside `troubleCodes` rather than in telemetry because that is what it
    /// is: diagnostics state, refreshed on connect and when the vehicle says something
    /// has changed, not a value sampled once a second.
    private(set) var monitorStatus: MonitorStatus?
    private(set) var adapterIdentity: String?
    private(set) var protocolDescription: String?
    private(set) var source: Source?
    /// Recent failures, newest first, for the Debug Center. Never silently discarded.
    private(set) var recentIssues: [String] = []
    private(set) var adapterVoltage: Provenanced<Double> = .unavailable()

    /// True while the app is in the foreground and showing live data; drives how
    /// often the adapter is polled.
    var isForeground = true

    /// Non-nil while DriveLayer is trying to get a dropped adapter back.
    private(set) var reconnectAttempt: Int?
    /// What to tell the driver while that is happening.
    private(set) var reconnectStatus: String?

    private var session: OBDSession?
    private var transport: OBDTransport?
    private var pollingTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private let reconnectPolicy = ReconnectPolicy()
    /// Set when the driver disconnects on purpose, so supervision does not fight them.
    private var isIntentionallyDisconnected = false
    private var lastRead: [UInt8: Date] = [:]
    private let maximumIssues = 20

    var isConnected: Bool { state.isUsable }

    /// Trying to get a dropped adapter back. The drive keeps recording either way, so
    /// the UI has to distinguish "gone" from "coming back".
    var isReconnecting: Bool { reconnectAttempt != nil }

    var capabilityLevel: VehicleCapabilityLevel {
        VehicleCapabilityLevel.current(profile: nil, isAdapterConnected: isConnected)
    }

    // MARK: - Lifecycle

    func connect(source: Source) async {
        // teardown, not disconnect: disconnect() cancels supervision, and this is the
        // call supervision itself makes. Cancelling from inside would stop the ladder
        // after its first attempt.
        await teardown()
        isIntentionallyDisconnected = false
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
            reconnectAttempt = nil
            reconnectStatus = nil
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

    /// Drops the connection and everything derived from it, leaving supervision alone.
    private func teardown() async {
        pollingTask?.cancel()
        pollingTask = nil
        await session?.stop()
        session = nil
        transport = nil
        state = .disconnected
        capabilities = nil
        telemetry = VehicleTelemetry(updatedAt: .distantPast)
troubleCodes = []
        monitorStatus = nil
        adapterVoltage = .unavailable()
        lastRead.removeAll()
    }

    /// Disconnects and stops trying to come back. Distinct from a dropped link.
    func disconnect() async {
        isIntentionallyDisconnected = true
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempt = nil
        reconnectStatus = nil
        await teardown()
    }

    /// Reconnects on the same source, used after a dropped link.
    func reconnect() async {
        guard let source else { return }
        await connect(source: source)
    }

    /// Keeps trying to get the adapter back, on a backoff, until it returns.
    ///
    /// The drive is deliberately untouched. A dropped adapter means the drive continues
    /// in phone-only mode - distance, terrain, weather and road events all still work -
    /// so this must never end a trip or start a new one. It restores live engine data
    /// and nothing else.
    ///
    /// `connect(source:)` repeats the whole sequence on each attempt: transport, adapter
    /// identification, protocol, capability discovery. Capabilities are rediscovered
    /// rather than reused, because a reconnect may be a different adapter and a stale
    /// report is how you end up polling PIDs this car never had.
    private func beginSupervisedReconnect(after error: OBDError) {
        guard !isIntentionallyDisconnected, source != nil, reconnectTask == nil else { return }

        state = .failed(error)
        note(error.userMessage)

        reconnectTask = Task { [weak self] in
            var attempt = 1
            while !Task.isCancelled {
                guard let self else { return }
                guard let delay = self.reconnectPolicy.delay(forAttempt: attempt) else {
                    self.reconnectAttempt = nil
                    self.reconnectStatus = self.reconnectPolicy.statusDescription(attempt: attempt)
                    return
                }

                self.reconnectAttempt = attempt
                self.reconnectStatus = self.reconnectPolicy.statusDescription(attempt: attempt)

                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled,
                      !self.isIntentionallyDisconnected,
                      let source = self.source else { return }

                await self.connect(source: source)
                if self.isConnected {
                    self.note("Adapter reconnected after \(attempt) attempt(s).")
                    self.reconnectTask = nil
                    return
                }
                attempt += 1
            }
        }
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
                // Source.isSimulated existed and was used only for display. This is the
                // place it actually matters.
                telemetry.apply(reading, provenance: source?.isSimulated == true ? .simulated : .measured)
                if descriptor.metric == .monitorStatusCode, let code = reading.numericValue {
                    noteMonitorStatus(code)
                }
                if !reading.isPlausible {
                    note("\(reading.name) returned an implausible value and was ignored.")
                }
            } catch let error as OBDError {
                if let code = descriptor.pid.code { lastRead[code] = Date() }
                if case .connectionLost = error {
                    // Supervised, not abandoned. The drive carries on phone-only.
                    beginSupervisedReconnect(after: .connectionLost)
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

    /// The lamp byte last seen, so a change in it can be acted on.
    private var lastMonitorCode: Double?

    /// Reads the stored codes when the vehicle's own summary of them changes.
    ///
    /// The lamp coming on, or the stored count moving, is the vehicle saying something new.
    /// Until now the codes were read on connect and on demand only, so a fault appearing
    /// mid-drive went unnoticed until the driver happened to open a screen — and the reason
    /// was structural rather than an oversight: PID 01 decoded to a display string, and a
    /// string cannot be compared against the previous one to notice a change.
    ///
    /// Only a lamp turning on or a count moving triggers a read. A lamp going *off* is not
    /// chased, because mode 03 is a slow request and the interesting direction is the one
    /// that has something to report.
    private func noteMonitorStatus(_ code: Double) {
        defer { lastMonitorCode = code }
        guard let previous = lastMonitorCode, previous != code,
              let new = MonitorStatus.decode(code: code),
              let old = MonitorStatus.decode(code: previous) else { return }

        let lampCameOn = new.isWarningLampOn && !old.isWarningLampOn
        let countChanged = new.confirmedFaultCount != old.confirmedFaultCount
        guard lampCameOn || countChanged else { return }

        Task { await refreshTroubleCodes() }
    }

    func refreshTroubleCodes() async {
        guard let session else { return }
        let result = await session.readDiagnosticCodes()
        troubleCodes = result.codes
        for note in result.notes { self.note(note) }
        // Read together: the stored codes and the vehicle's summary of them are answers to
        // the same question, and showing one refreshed and the other stale is how a screen
        // ends up contradicting itself.
        monitorStatus = await session.readMonitorStatus()
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
