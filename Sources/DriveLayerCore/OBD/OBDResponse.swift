import Foundation

/// A parsed positive response from the vehicle.
struct OBDResponse: Equatable, Sendable {
    let pid: OBDPID
    /// Every byte of the chosen frame, starting with the echoed mode byte.
    let fullBytes: [UInt8]
    /// Payload after the echoed mode byte and, where present, the echoed PID byte.
    let data: [UInt8]
    /// How many *additional* control modules answered the same request.
    let additionalResponderCount: Int
    let raw: String
}

/// Turns ELM327-style text into bytes.
///
/// This is the single place raw adapter text is interpreted. The simulator emits the
/// same text format, so simulated drives exercise exactly this code path rather than
/// bypassing it.
enum OBDResponseParser {

    /// Adapter-level replies that are not vehicle data.
    private static let errorMap: [(needle: String, error: OBDError)] = [
        ("UNABLE TO CONNECT", .unableToConnectToVehicle),
        ("NO DATA", .noData),
        ("BUFFER FULL", .bufferFull),
        ("BUS INIT: ERROR", .busError("Bus initialisation failed.")),
        ("BUS INIT:ERROR", .busError("Bus initialisation failed.")),
        ("BUS ERROR", .busError("The vehicle bus reported an error.")),
        ("CAN ERROR", .busError("CAN bus error.")),
        ("DATA ERROR", .busError("The adapter reported a data error.")),
        ("FB ERROR", .busError("Feedback error — check the adapter's power.")),
        ("LV RESET", .busError("The adapter reset because of low voltage.")),
        ("STOPPED", .stopped),
        ("ERROR", .busError("The adapter reported an error."))
    ]

    /// Splits raw adapter output into meaningful lines: drops the prompt, blank lines,
    /// the command echo and "SEARCHING..." progress chatter.
    static func sanitize(_ raw: String, echoOf request: String? = nil) -> [String] {
        let normalisedRequest = request?.uppercased().filter { !$0.isWhitespace }
        return raw
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: ">", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
            .filter { line in
                guard !line.isEmpty else { return false }
                if line.hasPrefix("SEARCHING") { return false }
                if let normalisedRequest, line.filter({ !$0.isWhitespace }) == normalisedRequest { return false }
                return true
            }
    }

    /// Parses one line into bytes, stripping an 11-bit CAN header and an ISO-TP
    /// single-frame length prefix when present.
    ///
    /// Any leading byte of 0x07 or less must be a protocol control byte: every valid
    /// positive response starts at 0x41 or above and a negative response starts at 0x7F.
    static func bytes(fromLine line: String) throws -> [UInt8] {
        var tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard !tokens.isEmpty else { throw OBDError.malformedResponse("Empty frame.") }

        // Some adapters run with spaces off: one long hex run.
        if tokens.count == 1, tokens[0].count > 2 {
            let joined = tokens[0]
            guard joined.count % 2 == 0 else {
                throw OBDError.malformedResponse("Odd number of hex characters in \"\(line)\".")
            }
            tokens = stride(from: 0, to: joined.count, by: 2).map { offset -> String in
                let start = joined.index(joined.startIndex, offsetBy: offset)
                let end = joined.index(start, offsetBy: 2)
                return String(joined[start..<end])
            }
        }

        // 11-bit CAN header, e.g. "7E8", only when other tokens follow it.
        if tokens.count > 1, tokens[0].count == 3, isHex(tokens[0]) {
            tokens.removeFirst()
        }

        var values: [UInt8] = []
        values.reserveCapacity(tokens.count)
        for token in tokens {
            guard token.count == 2, let value = UInt8(token, radix: 16) else {
                throw OBDError.malformedResponse("Unexpected token \"\(token)\".")
            }
            values.append(value)
        }
        guard !values.isEmpty else { throw OBDError.malformedResponse("No data in \"\(line)\".") }

        // ISO-TP single-frame length byte, followed by the payload and possible padding.
        if let first = values.first, first <= 0x07 {
            let length = Int(first)
            let payload = Array(values.dropFirst())
            guard payload.count >= length else {
                throw OBDError.malformedResponse("Frame claims \(length) bytes but carries \(payload.count).")
            }
            return Array(payload.prefix(length))
        }
        return values
    }

    /// Parses a complete adapter reply for a given request.
    static func parse(raw: String, for pid: OBDPID) throws -> OBDResponse {
        let lines = sanitize(raw, echoOf: pid.requestString)
        guard !lines.isEmpty else { throw OBDError.timeout }

        let joined = lines.joined(separator: " ")
        for entry in errorMap where joined.contains(entry.needle) {
            throw entry.error
        }
        if joined == "?" || lines.contains("?") { throw OBDError.unrecognisedCommand }

        let frames = try assembleFrames(from: lines)
        guard !frames.isEmpty else { throw OBDError.malformedResponse("No frames in reply.") }

        // A negative response is authoritative even if another module answered.
        if let negative = frames.first(where: { $0.count >= 3 && $0[0] == 0x7F }) {
            throw OBDError.negativeResponse(mode: negative[1], code: negative[2])
        }

        let expectedMode = pid.mode.positiveResponseByte
        let matching = frames.filter { frame in
            guard frame.first == expectedMode else { return false }
            guard let code = pid.code else { return true }
            return frame.count >= 2 && frame[1] == code
        }

        guard let chosen = matching.first else {
            let received = frames.map { hexString($0) }.joined(separator: " | ")
            throw OBDError.mismatchedResponse(expected: pid.requestString, received: received)
        }

        let headerLength = pid.code == nil ? 1 : 2
        guard chosen.count >= headerLength else {
            throw OBDError.malformedResponse("Response shorter than its own header.")
        }
        return OBDResponse(
            pid: pid,
            fullBytes: chosen,
            data: Array(chosen.dropFirst(headerLength)),
            additionalResponderCount: max(0, matching.count - 1),
            raw: raw
        )
    }

    /// Rebuilds ISO-TP multi-frame replies (mode 03 with many codes, mode 09 VIN) and
    /// otherwise treats each line as one control module's answer.
    private static func assembleFrames(from lines: [String]) throws -> [[UInt8]] {
        var declaredLength: Int?
        var indexed: [(index: Int, bytes: [UInt8])] = []
        var singles: [[UInt8]] = []

        for line in lines {
            var working = line
            var tokens = working.split(separator: " ").map(String.init)

            // A lone 3-character hex token is a total-length header, not a CAN header.
            if tokens.count == 1, tokens[0].count == 3, isHex(tokens[0]) {
                declaredLength = Int(tokens[0], radix: 16)
                continue
            }
            // Drop an 11-bit header preceding an indexed continuation line.
            if tokens.count > 1, tokens[0].count == 3, isHex(tokens[0]), tokens[1].hasSuffix(":") {
                tokens.removeFirst()
                working = tokens.joined(separator: " ")
            }
            if let firstToken = tokens.first, firstToken.hasSuffix(":") {
                let indexToken = String(firstToken.dropLast())
                guard let index = Int(indexToken, radix: 16) else {
                    throw OBDError.malformedResponse("Bad frame index \"\(firstToken)\".")
                }
                let remainder = tokens.dropFirst().joined(separator: " ")
                guard !remainder.isEmpty else { continue }
                indexed.append((index, try bytes(fromLine: remainder)))
                continue
            }
            singles.append(try bytes(fromLine: working))
        }

        guard !indexed.isEmpty else { return singles }

        var assembled: [UInt8] = []
        for frame in indexed.sorted(by: { $0.index < $1.index }) {
            assembled.append(contentsOf: frame.bytes)
        }
        if let declaredLength, declaredLength <= assembled.count {
            assembled = Array(assembled.prefix(declaredLength))
        }
        return singles + [assembled]
    }

    private static func isHex(_ token: String) -> Bool {
        !token.isEmpty && token.allSatisfy { $0.isHexDigit }
    }

    static func hexString(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", Int($0)) }.joined(separator: " ")
    }
}
