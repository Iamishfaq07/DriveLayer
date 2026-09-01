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

    // MARK: - Which adapter a connection is allowed to bind to

    /// Recognising an adapter and being allowed to connect to it are separate questions, and
    /// the transport used to ask only the first. `didDiscover` checked `looksLikeAdapter` and
    /// nothing else, so once the scan fallback ran - which it does whenever
    /// `retrievePeripherals` returns nothing, as it does for an adapter that is powered down,
    /// out of range, or simply not cached after a reboot - a saved target was ignored and the
    /// first OBD-ish name in range was taken instead.
    ///
    /// In a driveway that is invisible. In a car park it means connecting to another car.

    private func shouldBind(_ identifier: UUID,
                            name: String?,
                            policy: BluetoothOBDTransport.SelectionPolicy) -> Bool {
        BluetoothOBDTransport.shouldBind(to: identifier,
                                         name: nil,
                                         advertisement: advertisement(name),
                                         policy: policy)
    }

    func testASavedTargetBindsOnlyToThatExactPeripheral() {
        let mine = UUID()
        XCTAssertTrue(shouldBind(mine, name: "OBDII", policy: .onlyTarget(mine)))
    }

    /// The heart of the fix: another adapter, advertising a perfectly plausible name, in a
    /// car that is not the driver's.
    func testAnotherPersonsAdapterIsIgnoredWhenATargetIsSaved() {
        let mine = UUID()
        let theirs = UUID()
        XCTAssertNotEqual(mine, theirs)

        for name in ["OBDII", "ELM327-BLE", "VGATE iCar Pro", "OBDLink CX"] {
            XCTAssertFalse(shouldBind(theirs, name: name, policy: .onlyTarget(mine)),
                           "\(name) is a plausible adapter, but it is not the saved one")
        }
    }

    /// Identity is the whole test under `onlyTarget`. A previously validated adapter that
    /// advertises an unhelpful name today is still the right device, and refusing it would
    /// strand the driver for no benefit.
    func testTheSavedTargetIsAcceptedEvenIfItsNameLooksNothingLikeAnAdapter() {
        let mine = UUID()
        XCTAssertTrue(shouldBind(mine, name: "BLE-3A7F", policy: .onlyTarget(mine)))
        XCTAssertTrue(shouldBind(mine, name: nil, policy: .onlyTarget(mine)))
    }

    /// Opportunistic binding is still available, and only where it is the point: the driver
    /// is on the pairing screen looking for an adapter they have not saved yet.
    func testPairingModeStillTakesTheFirstPlausibleAdapter() {
        XCTAssertTrue(shouldBind(UUID(), name: "OBDII", policy: .firstPlausibleAdapter))
        XCTAssertFalse(shouldBind(UUID(), name: "AirPods Pro", policy: .firstPlausibleAdapter))
    }

    /// The policy comes from whether an identifier was supplied, so a caller cannot ask for
    /// a target and get opportunistic scanning by accident. This is the invariant that keeps
    /// the reconnect path safe.
    func testTheTransportPicksItsPolicyFromWhetherATargetWasGiven() {
        let saved = UUID()
        XCTAssertEqual(BluetoothOBDTransport(peripheralID: saved, displayName: "Mine").selectionPolicyForTesting,
                       .onlyTarget(saved))
        XCTAssertEqual(BluetoothOBDTransport(peripheralID: nil, displayName: "Any").selectionPolicyForTesting,
                       .firstPlausibleAdapter)
    }
}
