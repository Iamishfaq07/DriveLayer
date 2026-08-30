import Foundation

enum TelemetryCodecError: Error, Equatable, Sendable {
    case badMagic
    case unsupportedVersion(UInt8)
    case truncated(expected: Int, available: Int)
    case tooManyMetrics(Int)
    case unknownMetricIndex(Int)
}

/// Compact storage for a drive's telemetry.
///
/// Storing every reading as its own database row would mean millions of heavy objects
/// per month and a database that gets slower every drive. Instead a trip's samples are
/// encoded into one blob: a fixed header, then per sample a millisecond offset, a
/// presence bitmask, and 16-bit quantised values for the metrics actually present.
///
/// That is roughly 8 bytes plus 2 bytes per present metric per sample, and it keeps
/// the "absent" case free — a metric the vehicle never reported costs nothing.
///
/// The metric order below is part of the on-disk format. Append to it; never reorder
/// it, and bump `version` if that ever becomes necessary.
enum TelemetrySeriesCodec {

    static let magic: [UInt8] = Array("DLT1".utf8)
    static let version: UInt8 = 1

    /// Stable index order for the presence bitmask. Append-only.
    static let metricOrder: [VehicleMetric] = [
        .engineRPM,
        .vehicleSpeedKmh,
        .coolantTemperatureC,
        .engineLoadPercent,
        .intakeAirTemperatureC,
        .ambientAirTemperatureC,
        .throttlePositionPercent,
        .fuelLevelPercent,
        .fuelRateLitresPerHour,
        .controlModuleVoltageV,
        .intakeManifoldPressureKPa,
        .economyKmPerLitre,
        .warmUpDurationSeconds,
        .idleFractionPercent,
        .tripDistanceKm,
        // Appended, never inserted. The wire format stores a metric's *index* in this
        // list, so reordering it would silently reinterpret every telemetry file already
        // on disk - a coolant temperature read back as a fuel trim.
        .shortTermFuelTrimPercent,
        .longTermFuelTrimPercent,
        .commandedEquivalenceRatio,
        .fuelRailPressureKPa,
        .catalystTemperatureC,
        .ethanolPercent,
        .barometricPressureKPa,
        .oilTemperatureC,
        .absoluteLoadPercent,
        .acceleratorPedalPercent,
        .massAirFlowGramsPerSecond,
        .timingAdvanceDegrees
    ]

    /// Quantisation step per metric. Chosen so the full plausible range fits in Int16
    /// with resolution finer than the sensor's own.
    static func scale(for metric: VehicleMetric) -> Double {
        switch metric {
        case .engineRPM: return 1.0
        case .controlModuleVoltageV: return 0.001
        case .fuelRateLitresPerHour: return 0.01
        case .economyKmPerLitre: return 0.01
        case .warmUpDurationSeconds: return 1.0
        case .tripDistanceKm: return 0.01
        // Fuel trims are the reason this needs a finer step than the 0.1 default: a
        // baseline drifting from +1.5% to +3% is the signal, and 0.1% resolution would
        // quantise most of it away.
        case .shortTermFuelTrimPercent, .longTermFuelTrimPercent: return 0.01
        case .commandedEquivalenceRatio: return 0.001
        default: return 0.1
        }
    }

    private static let indexByMetric: [VehicleMetric: Int] = {
        var result: [VehicleMetric: Int] = [:]
        for (index, metric) in metricOrder.enumerated() { result[metric] = index }
        return result
    }()

    // MARK: - Encoding

    static func encode(_ samples: [TelemetrySample]) throws -> Data {
        guard metricOrder.count <= 32 else { throw TelemetryCodecError.tooManyMetrics(metricOrder.count) }

        var data = Data()
        data.append(contentsOf: magic)
        data.append(version)
        data.append(UInt8(metricOrder.count))

        let base = samples.first?.timestamp.timeIntervalSinceReferenceDate ?? 0
        appendDouble(base, to: &data)
        appendUInt32(UInt32(samples.count), to: &data)

        for sample in samples {
            let offsetSeconds = sample.timestamp.timeIntervalSinceReferenceDate - base
            let offsetMilliseconds = UInt32(Statistics.clamp(offsetSeconds * 1_000, 0...Double(UInt32.max)))
            appendUInt32(offsetMilliseconds, to: &data)

            var mask: UInt32 = 0
            var payload: [Int16] = []
            for (index, metric) in metricOrder.enumerated() {
                guard let value = sample.values[metric] else { continue }
                mask |= (1 << UInt32(index))
                payload.append(quantise(value, scale: scale(for: metric)))
            }
            appendUInt32(mask, to: &data)
            for value in payload { appendInt16(value, to: &data) }
        }
        return data
    }

    // MARK: - Decoding

    static func decode(_ data: Data) throws -> [TelemetrySample] {
        var cursor = 0
        let bytes = [UInt8](data)

        func require(_ count: Int) throws {
            guard cursor + count <= bytes.count else {
                throw TelemetryCodecError.truncated(expected: cursor + count, available: bytes.count)
            }
        }

        try require(magic.count + 2)
        guard Array(bytes[0..<magic.count]) == magic else { throw TelemetryCodecError.badMagic }
        cursor += magic.count

        let fileVersion = bytes[cursor]; cursor += 1
        guard fileVersion == version else { throw TelemetryCodecError.unsupportedVersion(fileVersion) }

        let metricCount = Int(bytes[cursor]); cursor += 1
        guard metricCount <= metricOrder.count else {
            throw TelemetryCodecError.unknownMetricIndex(metricCount - 1)
        }

        try require(12)
        let base = readDouble(bytes, at: &cursor)
        let sampleCount = Int(readUInt32(bytes, at: &cursor))

        var samples: [TelemetrySample] = []
        samples.reserveCapacity(sampleCount)

        for _ in 0..<sampleCount {
            try require(8)
            let offsetMilliseconds = readUInt32(bytes, at: &cursor)
            let mask = readUInt32(bytes, at: &cursor)

            var values: [VehicleMetric: Double] = [:]
            for index in 0..<metricCount where (mask & (1 << UInt32(index))) != 0 {
                guard index < metricOrder.count else { throw TelemetryCodecError.unknownMetricIndex(index) }
                try require(2)
                let raw = readInt16(bytes, at: &cursor)
                let metric = metricOrder[index]
                values[metric] = Double(raw) * scale(for: metric)
            }
            let timestamp = Date(timeIntervalSinceReferenceDate: base + Double(offsetMilliseconds) / 1_000)
            samples.append(TelemetrySample(timestamp: timestamp, values: values))
        }
        return samples
    }

    // MARK: - Primitives

    private static func quantise(_ value: Double, scale: Double) -> Int16 {
        let raw = (value / scale).rounded()
        return Int16(Statistics.clamp(raw, Double(Int16.min)...Double(Int16.max)))
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    private static func appendInt16(_ value: Int16, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    private static func appendDouble(_ value: Double, to data: inout Data) {
        var littleEndian = value.bitPattern.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    private static func readUInt32(_ bytes: [UInt8], at cursor: inout Int) -> UInt32 {
        var value: UInt32 = 0
        for offset in (0..<4).reversed() {
            value = (value << 8) | UInt32(bytes[cursor + offset])
        }
        cursor += 4
        return value
    }

    private static func readInt16(_ bytes: [UInt8], at cursor: inout Int) -> Int16 {
        let low = UInt16(bytes[cursor])
        let high = UInt16(bytes[cursor + 1])
        cursor += 2
        return Int16(bitPattern: (high << 8) | low)
    }

    private static func readDouble(_ bytes: [UInt8], at cursor: inout Int) -> Double {
        var pattern: UInt64 = 0
        for offset in (0..<8).reversed() {
            pattern = (pattern << 8) | UInt64(bytes[cursor + offset])
        }
        cursor += 8
        return Double(bitPattern: pattern)
    }
}
