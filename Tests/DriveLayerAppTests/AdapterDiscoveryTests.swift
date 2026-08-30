import XCTest
import CoreBluetooth

/// The pairing screen used to list every advertising BLE peripheral in range, because the
/// heuristic that recognises an adapter was private to `BluetoothOBDTransport` and the
/// scanner is a different type entirely. A driver was asked to pick their adapter out of
/// their headphones, their watch, a television and someone else's tyre sensors.
@MainActor
final class AdapterDiscoveryTests: XCTestCase {

    private func advertisement(_ localName: String?) -> [String: Any] {
        guard let localName else { return [:] }
        return [CBAdvertisementDataLocalNameKey: localName]
    }

    private func looksLikeAdapter(localName: String?, peripheralName: String? = nil) -> Bool {
        BluetoothOBDTransport.looksLikeAdapter(name: peripheralName,
                                              advertisement: advertisement(localName))
    }

    func testCommonAdapterNamesAreRecognised() {
        // The names these clones actually advertise under.
        for name in ["OBDII", "OBD2 BLE", "ELM327-BLE", "vLink", "VGATE iCar Pro",
                     "Veepeak OBDCheck", "KONNWEI KW902", "OBDLink CX", "Carista"] {
            XCTAssertTrue(looksLikeAdapter(localName: name), "\(name) should be offered")
        }
    }

    func testEverydayBluetoothDevicesAreNotOffered() {
        for name in ["AirPods Pro", "Ishfaq's Apple Watch", "Living Room TV", "Mi Band 8",
                     "JBL Flip 6", "Tile Mate", "Unnamed device"] {
            XCTAssertFalse(looksLikeAdapter(localName: name), "\(name) should not be offered")
        }
    }

    func testRecognitionIgnoresCase() {
        XCTAssertTrue(looksLikeAdapter(localName: "obdii adapter"))
        XCTAssertTrue(looksLikeAdapter(localName: "Elm327"))
    }

    func testThePeripheralNameIsUsedWhenThereIsNoLocalName() {
        // Some adapters advertise nothing and only name themselves once connected.
        XCTAssertTrue(looksLikeAdapter(localName: nil, peripheralName: "OBDII"))
        XCTAssertFalse(looksLikeAdapter(localName: nil, peripheralName: "AirPods"))
    }

    func testAnAnonymousAdvertisementIsNotAssumedToBeAnAdapter() {
        // A wrong guess here is worse than a missing row: connecting to a stranger's
        // device and waiting out an ELM timeout tells the driver nothing useful.
        XCTAssertFalse(looksLikeAdapter(localName: nil, peripheralName: nil))
        XCTAssertFalse(looksLikeAdapter(localName: ""))
    }

    func testAScannerStartsEmptyAndShowsOnlyLikelyAdapters() {
        let scanner = BluetoothAdapterScanner()
        XCTAssertTrue(scanner.discoveries.isEmpty)
        XCTAssertTrue(scanner.allDiscoveries.isEmpty)
        XCTAssertFalse(scanner.showsEverything, "the unfiltered list is opt-in, for a debug screen")
    }
}
