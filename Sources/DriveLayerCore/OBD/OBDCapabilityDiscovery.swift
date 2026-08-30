import Foundation

/// Decodes the four-byte "supported parameters" bitmaps (PIDs 00, 20, 40 …).
///
/// The most significant bit of the first byte is `base + 1`; the least significant
/// bit of the fourth byte is `base + 0x20`, which is also the request code for the
/// next block.
enum OBDSupportBitmap {
    static func decode(base: UInt8, bytes: [UInt8]) -> Set<UInt8> {
        guard bytes.count >= 4 else { return [] }
        var result: Set<UInt8> = []
        for byteIndex in 0..<4 {
            let byte = bytes[byteIndex]
            for bit in 0..<8 {
                guard (byte >> UInt8(7 - bit)) & 0x01 == 1 else { continue }
                let offset = byteIndex * 8 + bit + 1
                let code = Int(base) + offset
                if code <= 0xFF { result.insert(UInt8(code)) }
            }
        }
        return result
    }

    /// Inverse of `decode`. Used by the simulator and by round-trip tests.
    static func encode(base: UInt8, codes: Set<UInt8>) -> [UInt8] {
        var bytes: [UInt8] = [0, 0, 0, 0]
        for offset in 1...0x20 {
            let code = Int(base) + offset
            guard code <= 0xFF, codes.contains(UInt8(code)) else { continue }
            let bitIndex = offset - 1
            let byteIndex = bitIndex / 8
            let bitInByte = bitIndex % 8
            bytes[byteIndex] |= (0x80 >> UInt8(bitInByte))
        }
        return bytes
    }
}

/// Whether a diagnostic mode is available. "NO DATA" is genuinely ambiguous on mode
/// 03 — it can mean "no stored codes" or "mode not supported" depending on the ECU —
/// so DriveLayer records `.unknown` instead of picking one and being wrong.
enum ModeSupport: String, Codable, Sendable, Equatable {
    case supported
    case unsupported
    case unknown
}

/// What a specific vehicle actually reports. Nothing is displayed unless it appears
/// here: DriveLayer never assumes a PID exists because a similar car has it.
struct OBDCapabilityReport: Sendable, Equatable {
    var supportedCodes: Set<UInt8>
    var storedDTCSupport: ModeSupport
    var pendingDTCSupport: ModeSupport
    var permanentDTCSupport: ModeSupport
    var discoveredAt: Date
    /// Human-readable notes about blocks that failed to read, kept for the Debug Center.
    var notes: [String]

    init(supportedCodes: Set<UInt8> = [],
         storedDTCSupport: ModeSupport = .unknown,
         pendingDTCSupport: ModeSupport = .unknown,
         permanentDTCSupport: ModeSupport = .unknown,
         discoveredAt: Date = Date(),
         notes: [String] = []) {
        self.supportedCodes = supportedCodes
        self.storedDTCSupport = storedDTCSupport
        self.pendingDTCSupport = pendingDTCSupport
        self.permanentDTCSupport = permanentDTCSupport
        self.discoveredAt = discoveredAt
        self.notes = notes
    }

    func supports(_ pid: OBDPID) -> Bool {
        switch pid.mode {
        case .currentData, .freezeFrame:
            guard let code = pid.code else { return false }
            return supportedCodes.contains(code)
        case .storedDTCs: return storedDTCSupport == .supported
        case .pendingDTCs: return pendingDTCSupport == .supported
        case .permanentDTCs: return permanentDTCSupport == .supported
        case .vehicleInformation: return false
        }
    }

    /// Parameters that are both reported by the vehicle and decodable by DriveLayer.
    var decodableDescriptors: [OBDPIDDescriptor] {
        supportedCodes
            .compactMap { OBDPIDCatalog.descriptor(for: .current($0)) }
            .filter { $0.metric != nil || $0.pid.code == 0x01 }
            .sorted { ($0.pid.code ?? 0) < ($1.pid.code ?? 0) }
    }

    /// Reported by the vehicle but not interpretable yet. Surfaced honestly rather
    /// than decoded with a guessed formula.
    var reportedButNotDecodable: [UInt8] {
        supportedCodes
            .filter { OBDPIDCatalog.descriptor(for: .current($0)) == nil }
            .sorted()
    }

    var availableMetrics: Set<VehicleMetric> {
        Set(decodableDescriptors.compactMap { $0.metric })
    }

    var isEmpty: Bool { supportedCodes.isEmpty }
}

/// Walks the supported-parameter blocks and probes the diagnostic modes.
///
/// Takes a request closure rather than a transport so it can be tested against
/// canned responses, the simulator, or a real adapter without changing.
struct OBDCapabilityDiscovery: Sendable {
    typealias RequestHandler = @Sendable (OBDPID) async throws -> OBDResponse

    let request: RequestHandler
    let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = { Date() }, request: @escaping RequestHandler) {
        self.request = request
        self.now = now
    }

    func discover() async -> OBDCapabilityReport {
        var report = OBDCapabilityReport(discoveredAt: now())

        for base in OBDPIDCatalog.supportedPIDRequestCodes {
            // Only ask for the next block if the previous one said it exists.
            if base != 0x00 && !report.supportedCodes.contains(base) { break }
            do {
                let response = try await request(.current(base))
                let codes = OBDSupportBitmap.decode(base: base, bytes: response.data)
                if codes.isEmpty {
                    report.notes.append(String(format: "Block %02X returned an empty bitmap.", Int(base)))
                    break
                }
                report.supportedCodes.formUnion(codes)
                // The block's own request code is implicitly supported once it answers.
                report.supportedCodes.insert(base)
            } catch let error as OBDError {
                report.notes.append("Block " + String(format: "%02X", Int(base)) + ": " + error.userMessage)
                break
            } catch {
                report.notes.append("Block " + String(format: "%02X", Int(base)) + ": " + error.localizedDescription)
                break
            }
        }

        let stored = await probe(mode: .storedDTCs)
        let pending = await probe(mode: .pendingDTCs)
        let permanent = await probe(mode: .permanentDTCs)
        report.storedDTCSupport = stored.support
        report.pendingDTCSupport = pending.support
        report.permanentDTCSupport = permanent.support
        report.notes.append(contentsOf: [stored.note, pending.note, permanent.note].compactMap { $0 })

        return report
    }

    /// A mode counts as supported if it answers at all — including "no codes stored",
    /// which is a valid, informative answer.
    private func probe(mode: OBDMode) async -> (support: ModeSupport, note: String?) {
        do {
            _ = try await request(OBDPID(mode: mode))
            return (.supported, nil)
        } catch let error as OBDError {
            switch error {
            case .noData:
                return (.unknown, String(format: "Mode %02X answered NO DATA: either no codes are stored or the mode isn't supported.", Int(mode.rawValue)))
            case .negativeResponse, .unrecognisedCommand:
                return (.unsupported, nil)
            default:
                return (.unknown, "Mode " + String(format: "%02X", Int(mode.rawValue)) + ": " + error.userMessage)
            }
        } catch {
            return (.unknown, nil)
        }
    }
}
