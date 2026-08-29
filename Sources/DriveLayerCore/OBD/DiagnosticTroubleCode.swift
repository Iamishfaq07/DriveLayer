import Foundation

enum DTCSystem: String, Codable, CaseIterable, Sendable {
    case powertrain = "P"
    case chassis = "C"
    case body = "B"
    case network = "U"

    var displayName: String {
        switch self {
        case .powertrain: return "Powertrain"
        case .chassis: return "Chassis"
        case .body: return "Body"
        case .network: return "Network"
        }
    }
}

enum DTCStatus: String, Codable, CaseIterable, Sendable {
    /// Confirmed and stored; usually accompanied by the warning light.
    case stored
    /// Seen once, not yet confirmed. Often clears itself.
    case pending
    /// Retained until the vehicle itself verifies the repair. Cannot be cleared by a tool.
    case permanent

    var displayName: String {
        switch self {
        case .stored: return "Stored"
        case .pending: return "Pending"
        case .permanent: return "Permanent"
        }
    }

    var explanation: String {
        switch self {
        case .stored: return "Confirmed by the vehicle and stored in the ECU."
        case .pending: return "Seen once and not yet confirmed. It may clear on its own if it doesn't recur."
        case .permanent: return "Kept by the vehicle until it confirms the fault is fixed. Diagnostic tools cannot erase it."
        }
    }
}

struct DiagnosticTroubleCode: Hashable, Codable, Sendable, Identifiable {
    var code: String
    var system: DTCSystem
    var status: DTCStatus

    var id: String { "\(code)-\(status.rawValue)" }
}

/// Decodes mode 03/07/0A replies.
enum DTCDecoder {

    /// Decodes one two-byte code. Returns `nil` for the 0x0000 padding that ECUs use
    /// to fill the rest of a frame.
    static func decode(first: UInt8, second: UInt8, status: DTCStatus) -> DiagnosticTroubleCode? {
        if first == 0x00 && second == 0x00 { return nil }
        let systems: [DTCSystem] = [.powertrain, .chassis, .body, .network]
        let system = systems[Int((first & 0xC0) >> 6)]
        let digit1 = (first & 0x30) >> 4
        let digit2 = first & 0x0F
        let digit3 = (second & 0xF0) >> 4
        let digit4 = second & 0x0F
        let code = system.rawValue + String(format: "%d%X%X%X", Int(digit1), Int(digit2), Int(digit3), Int(digit4))
        return DiagnosticTroubleCode(code: code, system: system, status: status)
    }

    /// Decodes the payload of a mode 03/07/0A response.
    ///
    /// Some ECUs prefix the code pairs with a count byte and some do not. An odd
    /// payload length can only be explained by a leading count byte, so that is the
    /// signal used; the count itself is treated as advisory, never as truth.
    static func decodeList(payload: [UInt8], status: DTCStatus) -> [DiagnosticTroubleCode] {
        var bytes = payload
        if bytes.count % 2 == 1 { bytes.removeFirst() }
        var codes: [DiagnosticTroubleCode] = []
        var index = 0
        while index + 1 < bytes.count {
            if let code = decode(first: bytes[index], second: bytes[index + 1], status: status) {
                codes.append(code)
            }
            index += 2
        }
        // Multiple ECUs can report the same code; show it once.
        var seen = Set<String>()
        return codes.filter { seen.insert($0.code).inserted }
    }

    static func decodeList(from response: OBDResponse, status: DTCStatus) -> [DiagnosticTroubleCode] {
        decodeList(payload: response.data, status: status)
    }

    /// Inverse of `decode`, for the simulator and round-trip tests.
    /// Returns `nil` for anything that isn't a well-formed five-character code.
    static func encode(_ code: String) -> (UInt8, UInt8)? {
        let characters = Array(code.uppercased())
        guard characters.count == 5,
              let system = DTCSystem(rawValue: String(characters[0])) else { return nil }
        let systems: [DTCSystem] = [.powertrain, .chassis, .body, .network]
        guard let systemIndex = systems.firstIndex(of: system) else { return nil }
        guard let digit1 = characters[1].hexDigitValue, digit1 <= 3,
              let digit2 = characters[2].hexDigitValue,
              let digit3 = characters[3].hexDigitValue,
              let digit4 = characters[4].hexDigitValue else { return nil }
        let first = UInt8(systemIndex << 6) | UInt8(digit1 << 4) | UInt8(digit2)
        let second = UInt8(digit3 << 4) | UInt8(digit4)
        return (first, second)
    }
}
