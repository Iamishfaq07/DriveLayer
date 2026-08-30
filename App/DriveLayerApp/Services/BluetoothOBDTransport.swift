import Foundation
import CoreBluetooth

/// Talks to a Bluetooth Low Energy ELM327-compatible adapter.
///
/// This is the only file in the app that knows about CoreBluetooth. It implements
/// `OBDTransport` and nothing more: it moves text in and text out. Everything above
/// it — protocol, decoding, capability discovery, session state — is the core's, and
/// is therefore testable against the simulator rather than against a car.
///
/// Read-only by construction: the only bytes it ever writes are the request strings
/// the core builds, and the core's command set contains no write or control service.
final class BluetoothOBDTransport: NSObject, OBDTransport, @unchecked Sendable {

    nonisolated let identifier: String
    nonisolated let displayName: String

    /// Services seen on common ELM327 clones. Used as scan hints only — discovery
    /// falls back to inspecting characteristics, because these adapters vary wildly.
    static let candidateServiceUUIDs = [
        CBUUID(string: "FFF0"), CBUUID(string: "FFE0"),
        CBUUID(string: "18F0"), CBUUID(string: "FFF1")
    ]

    private let queue = DispatchQueue(label: "com.drivelayer.obd.ble")
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?

    private var responseBuffer = ""
    private var pendingRequest: PendingRequest?
    private var pendingConnection: CheckedContinuation<Void, Error>?
    private var targetPeripheralID: UUID?
    private var isReady = false
    private var requestCounter: UInt64 = 0

    /// The link dropped without us asking for it.
    ///
    /// Sticky, and that is the entire point. `didDisconnectPeripheral` can only fail a
    /// request that is in flight, and the poll loop sleeps 250 ms between reads -- so the
    /// ordinary drop happens with nothing pending, both continuations are nil, the handler
    /// is a no-op, and the only trace left behind was `isReady = false`. The next `send`
    /// then reported `.notConnected`, which is indistinguishable from never having
    /// connected at all, while the one reconnect trigger upstream is gated on
    /// `.connectionLost`. The supervised reconnect existed and was unreachable for the
    /// disconnect that actually happens in a moving car.
    private var didLoseConnection = false

    /// Set while we are the ones hanging up, so a deliberate disconnect is not mistaken
    /// for a drop and does not send the supervisor chasing it.
    private var isDisconnectingIntentionally = false

    private struct PendingRequest {
        let id: UInt64
        let continuation: CheckedContinuation<String, Error>
    }

    /// - Parameter peripheralID: a previously connected adapter, or `nil` to take the
    ///   first plausible adapter found while scanning.
    init(peripheralID: UUID?, displayName: String) {
        self.targetPeripheralID = peripheralID
        self.identifier = peripheralID?.uuidString ?? "ble.unknown"
        self.displayName = displayName
        super.init()
    }

    // MARK: - OBDTransport

    func connect() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                guard self.pendingConnection == nil else {
                    continuation.resume(throwing: OBDError.connectionFailed("A connection is already in progress."))
                    return
                }
                self.pendingConnection = continuation
                self.didLoseConnection = false
                self.isDisconnectingIntentionally = false
                if self.central == nil {
                    self.central = CBCentralManager(delegate: self, queue: self.queue)
                } else {
                    self.beginConnectionIfPowered()
                }
                // Bluetooth can take a while to power on and a car can be out of range.
                self.queue.asyncAfter(deadline: .now() + 20) {
                    guard let pending = self.pendingConnection else { return }
                    self.pendingConnection = nil
                    self.central?.stopScan()
                    pending.resume(throwing: OBDError.connectionFailed("No adapter responded. Check it is plugged in and the ignition is on."))
                }
            }
        }
    }

    func disconnect() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.isDisconnectingIntentionally = true
                self.didLoseConnection = false
                self.failPendingRequest(with: .connectionLost)
                if let peripheral = self.peripheral {
                    self.central?.cancelPeripheralConnection(peripheral)
                }
                self.central?.stopScan()
                self.isReady = false
                self.writeCharacteristic = nil
                self.notifyCharacteristic = nil
                self.peripheral = nil
                continuation.resume()
            }
        }
    }

    func send(_ command: String, timeout: TimeInterval) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            queue.async {
                guard self.isReady,
                      let peripheral = self.peripheral,
                      let characteristic = self.writeCharacteristic else {
                    // `.notConnected` is reserved for never having had a link. Reporting it
                    // for a link that dropped is what stopped the reconnect supervisor
                    // being reached.
                    continuation.resume(throwing: self.didLoseConnection
                                        ? OBDError.connectionLost
                                        : OBDError.notConnected)
                    return
                }
                guard self.pendingRequest == nil else {
                    continuation.resume(throwing: OBDError.busError("The adapter is still answering a previous request."))
                    return
                }

                self.requestCounter += 1
                let id = self.requestCounter
                self.pendingRequest = PendingRequest(id: id, continuation: continuation)
                self.responseBuffer = ""

                let payload = Data((command + "\r").utf8)
                let type: CBCharacteristicWriteType = characteristic.properties.contains(.write)
                    ? .withResponse
                    : .withoutResponse
                // Some adapters expose a small MTU, so long commands are chunked.
                let limit = max(20, peripheral.maximumWriteValueLength(for: type))
                var offset = 0
                while offset < payload.count {
                    let end = min(offset + limit, payload.count)
                    peripheral.writeValue(payload.subdata(in: offset..<end), for: characteristic, type: type)
                    offset = end
                }

                self.queue.asyncAfter(deadline: .now() + timeout) {
                    guard let pending = self.pendingRequest, pending.id == id else { return }
                    self.pendingRequest = nil
                    pending.continuation.resume(throwing: OBDError.timeout)
                }
            }
        }
    }

    // MARK: - Internals

    private func beginConnectionIfPowered() {
        guard let central, central.state == .poweredOn else { return }
        if let targetPeripheralID,
           let known = central.retrievePeripherals(withIdentifiers: [targetPeripheralID]).first {
            peripheral = known
            known.delegate = self
            central.connect(known)
            return
        }
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    private func failPendingRequest(with error: OBDError) {
        if let pending = pendingRequest {
            pendingRequest = nil
            pending.continuation.resume(throwing: error)
        }
    }

    private func completeConnection(_ result: Result<Void, Error>) {
        guard let pending = pendingConnection else { return }
        pendingConnection = nil
        switch result {
        case .success: pending.resume()
        case let .failure(error): pending.resume(throwing: error)
        }
    }

    /// Recognises an adapter by the characteristics it exposes rather than by name,
    /// because these devices are sold under dozens of names with the same firmware.
    private func adopt(characteristics: [CBCharacteristic], of peripheral: CBPeripheral) {
        for characteristic in characteristics {
            if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
                notifyCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
            }
            if characteristic.properties.contains(.write) || characteristic.properties.contains(.writeWithoutResponse) {
                writeCharacteristic = characteristic
            }
        }
        // Readiness is deliberately not declared here. `setNotifyValue` only *asks* for
        // the subscription; CoreBluetooth confirms it separately, and a command written
        // before that confirmation gets its reply as a notification iOS is not yet
        // delivering -- a silent stall until the request times out, which is precisely how
        // slower clones lost their first response.
        completeReadinessIfPossible()
    }

    /// Declares the transport ready once there is somewhere to write and the notify
    /// subscription is confirmed live.
    private func completeReadinessIfPossible() {
        guard !isReady,
              writeCharacteristic != nil,
              let notify = notifyCharacteristic,
              notify.isNotifying else { return }
        isReady = true
        completeConnection(.success(()))
    }

    /// Whether an advertisement looks like an OBD adapter.
    ///
    /// Was private to this type, so the pairing screen -- a different type entirely -- had
    /// no way to reach it and listed every advertising peripheral in range instead.
    static func looksLikeAdapter(name: String?, advertisement: [String: Any]) -> Bool {
        let localName = (advertisement[CBAdvertisementDataLocalNameKey] as? String) ?? name ?? ""
        let upper = localName.uppercased()
        let hints = ["OBD", "ELM", "VLINK", "VGATE", "VEEPEAK", "KONNWEI", "ICAR", "OBDLINK", "CARISTA"]
        return hints.contains { upper.contains($0) }
    }
}

extension BluetoothOBDTransport: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            beginConnectionIfPowered()
        case .unauthorized:
            completeConnection(.failure(OBDError.connectionFailed("DriveLayer needs Bluetooth permission to reach your adapter.")))
        case .poweredOff:
            completeConnection(.failure(OBDError.connectionFailed("Bluetooth is turned off.")))
        case .unsupported:
            completeConnection(.failure(OBDError.connectionFailed("This device doesn't support Bluetooth Low Energy.")))
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        guard self.peripheral == nil,
              Self.looksLikeAdapter(name: peripheral.name, advertisement: advertisementData) else { return }
        central.stopScan()
        self.peripheral = peripheral
        self.targetPeripheralID = peripheral.identifier
        peripheral.delegate = self
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        completeConnection(.failure(OBDError.connectionFailed(error?.localizedDescription ?? "The adapter refused the connection.")))
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        isReady = false
        writeCharacteristic = nil
        notifyCharacteristic = nil
        // Recorded even when nothing is pending, which is the common case: this is the
        // only durable evidence that the link went away rather than never existing.
        if !isDisconnectingIntentionally { didLoseConnection = true }
        failPendingRequest(with: .connectionLost)
        completeConnection(.failure(OBDError.connectionLost))
    }
}

extension BluetoothOBDTransport: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else {
            completeConnection(.failure(OBDError.connectionFailed("Couldn't read the adapter's services.")))
            return
        }
        for service in peripheral.services ?? [] {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard error == nil else { return }
        adopt(characteristics: service.characteristics ?? [], of: peripheral)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard error == nil else {
            completeConnection(.failure(OBDError.connectionFailed("The adapter would not turn on notifications.")))
            return
        }
        guard characteristic.isNotifying else { return }
        notifyCharacteristic = characteristic
        completeReadinessIfPossible()
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard error == nil, let data = characteristic.value else { return }
        responseBuffer += String(decoding: data, as: UTF8.self)

        // ELM327 ends every reply with its prompt character.
        guard responseBuffer.contains(">"), let pending = pendingRequest else { return }
        pendingRequest = nil
        let reply = responseBuffer
        responseBuffer = ""
        pending.continuation.resume(returning: reply)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error {
            failPendingRequest(with: .busError(error.localizedDescription))
        }
    }
}

/// Finds adapters for the pairing screen.
///
/// Separate from the transport because scanning and talking are different jobs with
/// different lifetimes: the scanner runs while a screen is open, the transport runs
/// for as long as a drive lasts.
@MainActor
@Observable
final class BluetoothAdapterScanner: NSObject {

    struct Discovery: Identifiable, Equatable {
        var id: UUID
        var name: String
        var signalStrength: Int
        /// Whether this looks like an OBD adapter rather than a pair of headphones.
        var isLikelyAdapter: Bool = true
    }

    /// Candidates worth showing a driver.
    ///
    /// Filtered, because it used to be every advertising BLE peripheral in range: watches,
    /// headphones, televisions, someone else's tyre sensors. A pairing screen that asks a
    /// driver to pick their adapter out of that is asking them to guess.
    var discoveries: [Discovery] { showsEverything ? allDiscoveries : allDiscoveries.filter(\.isLikelyAdapter) }

    /// Everything seen, adapter-like or not. For a debug screen, not the pairing screen.
    private(set) var allDiscoveries: [Discovery] = []

    /// Debug builds only, and off by default even there.
    var showsEverything = false

    private(set) var isScanning = false
    private(set) var authorisationMessage: String?

    private var central: CBCentralManager?

    func start() {
        guard !isScanning else { return }
        allDiscoveries = []
        isScanning = true
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main)
        } else if central?.state == .poweredOn {
            central?.scanForPeripherals(withServices: nil, options: nil)
        }
    }

    func stop() {
        isScanning = false
        central?.stopScan()
    }
}

extension BluetoothAdapterScanner: CBCentralManagerDelegate {

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        Task { @MainActor in
            switch state {
            case .poweredOn:
                self.authorisationMessage = nil
                if self.isScanning { central.scanForPeripherals(withServices: nil, options: nil) }
            case .poweredOff:
                self.authorisationMessage = "Bluetooth is turned off."
            case .unauthorized:
                self.authorisationMessage = "DriveLayer needs Bluetooth permission to find your adapter."
            case .unsupported:
                self.authorisationMessage = "This device doesn't support Bluetooth Low Energy."
            default:
                break
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any],
                                    rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? "Unnamed device"
        let identifier = peripheral.identifier
        let strength = RSSI.intValue
        let isLikely = BluetoothOBDTransport.looksLikeAdapter(name: peripheral.name,
                                                              advertisement: advertisementData)
        Task { @MainActor in
            let discovery = Discovery(id: identifier,
                                      name: name,
                                      signalStrength: strength,
                                      isLikelyAdapter: isLikely)
            if let index = self.allDiscoveries.firstIndex(where: { $0.id == identifier }) {
                self.allDiscoveries[index] = discovery
            } else {
                self.allDiscoveries.append(discovery)
            }
            // Strongest signal first: the adapter in this car, not one two cars away.
            self.allDiscoveries.sort { $0.signalStrength > $1.signalStrength }
        }
    }
}
