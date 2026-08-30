import Foundation

/// A standard-mode-01 parameter DriveLayer knows how to interpret.
struct OBDPIDDescriptor: Sendable {
    let pid: OBDPID
    let name: String
    let shortName: String
    let metric: VehicleMetric?
    let unitLabel: String
    /// Data bytes expected after the echoed mode and PID.
    let expectedByteCount: Int
    /// Physically plausible band. Values outside it decode but are flagged.
    let plausibleRange: ClosedRange<Double>?
    let refresh: OBDRefreshClass
    let decode: @Sendable ([UInt8]) throws -> OBDValue

    func makeReading(from data: [UInt8], at timestamp: Date) throws -> OBDReading {
        guard data.count >= expectedByteCount else {
            throw OBDError.malformedResponse("\(name) needs \(expectedByteCount) bytes, got \(data.count).")
        }
        let value = try decode(Array(data.prefix(expectedByteCount)))
        var plausible = true
        if let plausibleRange, let number = value.doubleValue {
            plausible = plausibleRange.contains(number)
        }
        return OBDReading(pid: pid,
                          name: name,
                          metric: metric,
                          value: value,
                          unitLabel: unitLabel,
                          timestamp: timestamp,
                          isPlausible: plausible)
    }
}

/// The standard SAE J1979 mode 01 parameters DriveLayer decodes.
///
/// Only parameters whose scaling is part of the published standard appear here.
/// Identifiers that exist in the standard but whose decoding DriveLayer has not
/// verified are listed in `knownUndecodedNames` instead: capability discovery will
/// report them as present, and the app will say it cannot interpret them, which is
/// honest in a way that a guessed formula would not be.
enum OBDPIDCatalog {

    static let supportedPIDRequestCodes: [UInt8] = [0x00, 0x20, 0x40, 0x60, 0x80, 0xA0, 0xC0]

    static func descriptor(for pid: OBDPID) -> OBDPIDDescriptor? {
        guard pid.mode == .currentData, let code = pid.code else { return nil }
        return byCode[code]
    }

    static var allDescriptors: [OBDPIDDescriptor] {
        byCode.values.sorted { ($0.pid.code ?? 0) < ($1.pid.code ?? 0) }
    }

    /// Parameters the app polls during a drive, in priority order.
    static var driveRelevantDescriptors: [OBDPIDDescriptor] {
        allDescriptors.filter { $0.metric != nil }
    }

    static let knownUndecodedNames: [UInt8: String] = [
        0x78: "Exhaust gas temperature, bank 1",
        0x79: "Exhaust gas temperature, bank 2",
        0x7A: "Diesel particulate filter, bank 1",
        0x7B: "Diesel particulate filter, bank 2",
        0x7C: "Diesel particulate filter temperature",
        0x83: "NOx sensor",
        0x9A: "Hybrid/EV battery",
        0x9D: "Engine fuel rate (multi-part)",
        0x9E: "Engine exhaust flow rate"
    ]

    static func displayName(forCode code: UInt8) -> String {
        if let descriptor = byCode[code] { return descriptor.name }
        if let known = knownUndecodedNames[code] { return known }
        if supportedPIDRequestCodes.contains(code) {
            return String(format: "Supported parameters %02X–%02X", Int(code) + 1, Int(code) + 0x20)
        }
        return String(format: "Parameter %02X", Int(code))
    }

    // MARK: - Decoding helpers

    private static func byteA(_ data: [UInt8]) -> Double { Double(data[0]) }

    private static func word(_ data: [UInt8]) -> Double { Double(Int(data[0]) << 8 | Int(data[1])) }

    /// The standard percentage scaling: a single byte over its full range.
    private static func percentByte(_ data: [UInt8]) -> Double { Double(data[0]) * 100.0 / 255.0 }

    /// The standard temperature scaling: one byte with a 40 °C offset.
    private static func temperatureByte(_ data: [UInt8]) -> Double { Double(data[0]) - 40.0 }

    private static func makeSupportedPIDsDescriptor(base: UInt8) -> OBDPIDDescriptor {
        OBDPIDDescriptor(
            pid: .current(base),
            name: String(format: "Supported parameters %02X–%02X", Int(base) + 1, Int(base) + 0x20),
            shortName: "Supported",
            metric: nil,
            unitLabel: "",
            expectedByteCount: 4,
            plausibleRange: nil,
            refresh: .rare,
            decode: { data in
                let codes = OBDSupportBitmap.decode(base: base, bytes: data)
                return .text(codes.sorted().map { String(format: "%02X", Int($0)) }.joined(separator: ","))
            }
        )
    }

    private static let byCode: [UInt8: OBDPIDDescriptor] = {
        var result: [UInt8: OBDPIDDescriptor] = [:]
        for base in supportedPIDRequestCodes {
            result[base] = makeSupportedPIDsDescriptor(base: base)
        }
        for descriptor in decodedDescriptors {
            if let code = descriptor.pid.code { result[code] = descriptor }
        }
        return result
    }()

    private static let decodedDescriptors: [OBDPIDDescriptor] = [
        OBDPIDDescriptor(pid: .current(0x01), name: "Monitor status", shortName: "MIL",
                         metric: nil, unitLabel: "", expectedByteCount: 4,
                         plausibleRange: nil, refresh: .slow,
                         decode: { data in
                             let milOn = (data[0] & 0x80) != 0
                             let count = Int(data[0] & 0x7F)
                             return .text(milOn ? "MIL on, \(count) stored" : "MIL off, \(count) stored")
                         }),

        OBDPIDDescriptor(pid: .current(0x04), name: "Calculated engine load", shortName: "Load",
                         metric: .engineLoadPercent, unitLabel: "%", expectedByteCount: 1,
                         plausibleRange: 0...100, refresh: .fast,
                         decode: { .number(percentByte($0)) }),

        OBDPIDDescriptor(pid: .current(0x05), name: "Engine coolant temperature", shortName: "Coolant",
                         metric: .coolantTemperatureC, unitLabel: "°C", expectedByteCount: 1,
                         plausibleRange: -40...130, refresh: .medium,
                         decode: { .number(temperatureByte($0)) }),

        OBDPIDDescriptor(pid: .current(0x0A), name: "Fuel pressure", shortName: "Fuel press.",
                         metric: nil, unitLabel: "kPa", expectedByteCount: 1,
                         plausibleRange: 0...765, refresh: .slow,
                         decode: { .number(byteA($0) * 3.0) }),

        OBDPIDDescriptor(pid: .current(0x0B), name: "Intake manifold pressure", shortName: "MAP",
                         metric: .intakeManifoldPressureKPa, unitLabel: "kPa", expectedByteCount: 1,
                         plausibleRange: 0...255, refresh: .fast,
                         decode: { .number(byteA($0)) }),

        OBDPIDDescriptor(pid: .current(0x0C), name: "Engine speed", shortName: "RPM",
                         metric: .engineRPM, unitLabel: "rpm", expectedByteCount: 2,
                         plausibleRange: 0...9000, refresh: .fast,
                         decode: { .number(word($0) / 4.0) }),

        OBDPIDDescriptor(pid: .current(0x0D), name: "Vehicle speed", shortName: "Speed",
                         metric: .vehicleSpeedKmh, unitLabel: "km/h", expectedByteCount: 1,
                         plausibleRange: 0...255, refresh: .fast,
                         decode: { .number(byteA($0)) }),

        OBDPIDDescriptor(pid: .current(0x0E), name: "Timing advance", shortName: "Timing",
                         metric: nil, unitLabel: "°", expectedByteCount: 1,
                         plausibleRange: -64...63.5, refresh: .medium,
                         decode: { .number(byteA($0) / 2.0 - 64.0) }),

        OBDPIDDescriptor(pid: .current(0x0F), name: "Intake air temperature", shortName: "Intake air",
                         metric: .intakeAirTemperatureC, unitLabel: "°C", expectedByteCount: 1,
                         plausibleRange: -40...215, refresh: .medium,
                         decode: { .number(temperatureByte($0)) }),

        OBDPIDDescriptor(pid: .current(0x10), name: "Mass air flow", shortName: "MAF",
                         metric: nil, unitLabel: "g/s", expectedByteCount: 2,
                         plausibleRange: 0...655.35, refresh: .fast,
                         decode: { .number(word($0) / 100.0) }),

        OBDPIDDescriptor(pid: .current(0x11), name: "Throttle position", shortName: "Throttle",
                         metric: .throttlePositionPercent, unitLabel: "%", expectedByteCount: 1,
                         plausibleRange: 0...100, refresh: .fast,
                         decode: { .number(percentByte($0)) }),

        OBDPIDDescriptor(pid: .current(0x1F), name: "Run time since engine start", shortName: "Runtime",
                         metric: nil, unitLabel: "s", expectedByteCount: 2,
                         plausibleRange: 0...65535, refresh: .medium,
                         decode: { .number(word($0)) }),

        OBDPIDDescriptor(pid: .current(0x21), name: "Distance with warning light on", shortName: "MIL distance",
                         metric: nil, unitLabel: "km", expectedByteCount: 2,
                         plausibleRange: 0...65535, refresh: .rare,
                         decode: { .number(word($0)) }),

        OBDPIDDescriptor(pid: .current(0x2F), name: "Fuel tank level", shortName: "Fuel",
                         metric: .fuelLevelPercent, unitLabel: "%", expectedByteCount: 1,
                         plausibleRange: 0...100, refresh: .slow,
                         decode: { .number(percentByte($0)) }),

        OBDPIDDescriptor(pid: .current(0x31), name: "Distance since codes cleared", shortName: "Since clear",
                         metric: nil, unitLabel: "km", expectedByteCount: 2,
                         plausibleRange: 0...65535, refresh: .rare,
                         decode: { .number(word($0)) }),

        OBDPIDDescriptor(pid: .current(0x33), name: "Barometric pressure", shortName: "Baro",
                         metric: nil, unitLabel: "kPa", expectedByteCount: 1,
                         plausibleRange: 0...255, refresh: .slow,
                         decode: { .number(byteA($0)) }),

        OBDPIDDescriptor(pid: .current(0x42), name: "Control module voltage", shortName: "Voltage",
                         metric: .controlModuleVoltageV, unitLabel: "V", expectedByteCount: 2,
                         plausibleRange: 0...30, refresh: .slow,
                         decode: { .number(word($0) / 1000.0) }),

        OBDPIDDescriptor(pid: .current(0x43), name: "Absolute load value", shortName: "Abs. load",
                         metric: nil, unitLabel: "%", expectedByteCount: 2,
                         plausibleRange: 0...25700, refresh: .medium,
                         decode: { .number(word($0) * 100.0 / 255.0) }),

        OBDPIDDescriptor(pid: .current(0x45), name: "Relative throttle position", shortName: "Rel. throttle",
                         metric: nil, unitLabel: "%", expectedByteCount: 1,
                         plausibleRange: 0...100, refresh: .medium,
                         decode: { .number(percentByte($0)) }),

        OBDPIDDescriptor(pid: .current(0x46), name: "Ambient air temperature", shortName: "Ambient",
                         metric: .ambientAirTemperatureC, unitLabel: "°C", expectedByteCount: 1,
                         plausibleRange: -40...215, refresh: .slow,
                         decode: { .number(temperatureByte($0)) }),

        OBDPIDDescriptor(pid: .current(0x47), name: "Absolute throttle position B", shortName: "Throttle B",
                         metric: nil, unitLabel: "%", expectedByteCount: 1,
                         plausibleRange: 0...100, refresh: .medium,
                         decode: { .number(percentByte($0)) }),

        OBDPIDDescriptor(pid: .current(0x4C), name: "Commanded throttle actuator", shortName: "Cmd. throttle",
                         metric: nil, unitLabel: "%", expectedByteCount: 1,
                         plausibleRange: 0...100, refresh: .medium,
                         decode: { .number(percentByte($0)) }),

        OBDPIDDescriptor(pid: .current(0x51), name: "Fuel type", shortName: "Fuel type",
                         metric: nil, unitLabel: "", expectedByteCount: 1,
                         plausibleRange: nil, refresh: .rare,
                         decode: { .text(OBDFuelTypeTable.name(for: $0[0])) }),

        OBDPIDDescriptor(pid: .current(0x5A), name: "Relative accelerator pedal position", shortName: "Pedal",
                         metric: nil, unitLabel: "%", expectedByteCount: 1,
                         plausibleRange: 0...100, refresh: .fast,
                         decode: { .number(percentByte($0)) }),

        OBDPIDDescriptor(pid: .current(0x5C), name: "Engine oil temperature", shortName: "Oil temp",
                         metric: nil, unitLabel: "°C", expectedByteCount: 1,
                         plausibleRange: -40...215, refresh: .medium,
                         decode: { .number(temperatureByte($0)) }),

        OBDPIDDescriptor(pid: .current(0x5E), name: "Engine fuel rate", shortName: "Fuel rate",
                         metric: .fuelRateLitresPerHour, unitLabel: "L/h", expectedByteCount: 2,
                         plausibleRange: 0...300, refresh: .fast,
                         decode: { .number(word($0) / 20.0) }),

        OBDPIDDescriptor(pid: .current(0x61), name: "Driver's demanded torque", shortName: "Demand torque",
                         metric: nil, unitLabel: "%", expectedByteCount: 1,
                         plausibleRange: -125...130, refresh: .medium,
                         decode: { .number(byteA($0) - 125.0) }),

        OBDPIDDescriptor(pid: .current(0x62), name: "Actual engine torque", shortName: "Torque",
                         metric: nil, unitLabel: "%", expectedByteCount: 1,
                         plausibleRange: -125...130, refresh: .medium,
                         decode: { .number(byteA($0) - 125.0) }),

        OBDPIDDescriptor(pid: .current(0x63), name: "Engine reference torque", shortName: "Ref. torque",
                         metric: nil, unitLabel: "N·m", expectedByteCount: 2,
                         plausibleRange: 0...65535, refresh: .rare,
                         decode: { .number(word($0)) })
    ]
}

/// PID 0x51's standard fuel type table.
enum OBDFuelTypeTable {
    static func name(for value: UInt8) -> String {
        switch value {
        case 0: return "Not available"
        case 1: return "Petrol"
        case 2: return "Methanol"
        case 3: return "Ethanol"
        case 4: return "Diesel"
        case 5: return "LPG"
        case 6: return "CNG"
        case 7: return "Propane"
        case 8: return "Electric"
        case 9: return "Bifuel, running petrol"
        case 10: return "Bifuel, running methanol"
        case 11: return "Bifuel, running ethanol"
        case 12: return "Bifuel, running LPG"
        case 13: return "Bifuel, running CNG"
        case 14: return "Bifuel, running propane"
        case 15: return "Bifuel, running electricity"
        default: return "Other"
        }
    }
}
