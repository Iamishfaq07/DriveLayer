import XCTest
import CoreBluetooth

private actor FailingHandshakeTransport: OBDTransport {
    nonisolated let identifier = "failed-handshake"
    nonisolated let displayName = "Failed handshake"
    private(set) var isConnected = false
    func connect() async throws { isConnected = true }
    func disconnect() async { isConnected = false }
    func send(_ command: String, timeout: TimeInterval) async throws -> String { throw OBDError.timeout }
}

@MainActor
final class BLELifecycleRegressionTests: XCTestCase {
    func testFailedELMHandshakeClosesTransport() async {
        let transport = FailingHandshakeTransport()
        let manager = OBDConnectionManager(transportFactory: { _ in transport })
        await manager.connect(source: .bluetooth(peripheralID: UUID(), name: "Test"))
        let connected = await transport.isConnected
        XCTAssertFalse(connected)
        XCTAssertFalse(manager.isConnected)
        XCTAssertNil(manager.capabilities)
        XCTAssertTrue(manager.telemetry.isEmpty)
    }

    private func characteristic(_ id: String, _ properties: CBCharacteristicProperties) -> CBCharacteristic {
        CBMutableCharacteristic(type: CBUUID(string: id), properties: properties,
                                value: nil, permissions: [.readable, .writeable])
    }

    func testUnrelatedServicesCannotFormUART() {
        let services: [CBUUID: [CBCharacteristic]] = [
            CBUUID(string: "FFF0"): [characteristic("FFF1", .write)],
            CBUUID(string: "FFE0"): [characteristic("FFE1", .notify)]
        ]
        XCTAssertNil(BluetoothOBDTransport.selectUART(from: services))
    }

    func testUnknownCoherentUARTIsSupportedAndSelectionIsDeterministic() throws {
        let write = characteristic("AB01", .writeWithoutResponse)
        let notify = characteristic("AB02", .indicate)
        let unknown = CBUUID(string: "AB00")
        let incomplete = CBUUID(string: "FFF0")
        let first = [unknown: [notify, write], incomplete: [characteristic("FFF1", .write)]]
        let second = [incomplete: [characteristic("FFF1", .write)], unknown: [write, notify]]
        let a = try XCTUnwrap(BluetoothOBDTransport.selectUART(from: first))
        let b = try XCTUnwrap(BluetoothOBDTransport.selectUART(from: second))
        XCTAssertTrue(a.write === write)
        XCTAssertTrue(a.notify === notify)
        XCTAssertTrue(b.write === a.write)
        XCTAssertTrue(b.notify === a.notify)
    }
}
