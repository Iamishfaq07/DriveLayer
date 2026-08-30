import Foundation

/// The development scenarios DriveLayer can drive itself with. Building these was a
/// requirement, not a convenience: the whole intelligence layer has to be
/// developable and testable without sitting in a car.
enum OBDScenarioID: String, Codable, CaseIterable, Sendable, Identifiable {
    case normalHighway
    case coldStart
    case hotCityTraffic
    case mountainClimb
    case longDescent
    case lowBattery
    case highCoolantTemperature
    case highEngineLoad
    case fuelRunningLow
    case dpfWarning
    case sensorUnavailable
    case linkDropAndRecover
    case invalidResponses

    var id: String { rawValue }
}

struct OBDScenario: Sendable, Identifiable, Equatable {
    var id: OBDScenarioID
    var title: String
    var summary: String
    /// What this scenario is meant to exercise, shown in the Debug Center so a
    /// developer knows what they should be seeing.
    var exercises: String

    static func named(_ id: OBDScenarioID) -> OBDScenario { catalog[id] ?? catalog[.normalHighway]! }

    static var all: [OBDScenario] { OBDScenarioID.allCases.compactMap { catalog[$0] } }

    static let catalog: [OBDScenarioID: OBDScenario] = {
        var result: [OBDScenarioID: OBDScenario] = [:]
        for scenario in list { result[scenario.id] = scenario }
        return result
    }()

    private static let list: [OBDScenario] = [
        OBDScenario(id: .normalHighway,
                    title: "Normal highway drive",
                    summary: "Steady 95 km/h cruise, warm engine, moderate load.",
                    exercises: "Baseline learning, trip recording, the calm end of the insight engine."),
        OBDScenario(id: .coldStart,
                    title: "Cold start",
                    summary: "Engine starts at ambient temperature and warms up over several minutes.",
                    exercises: "Warm-up detection, the warmed-up operating condition, Diesel Guardian's warm-up logic."),
        OBDScenario(id: .hotCityTraffic,
                    title: "Hot weather city traffic",
                    summary: "38 °C ambient, repeated stops, long idle periods.",
                    exercises: "Idle accounting, short-trip detection, heat-related coolant behaviour."),
        OBDScenario(id: .mountainClimb,
                    title: "Long mountain climb",
                    summary: "Sustained 70–85% load on a long gradient, coolant creeping up.",
                    exercises: "Terrain-aware engine insights: high load that is normal *for a climb*."),
        OBDScenario(id: .longDescent,
                    title: "Long descent",
                    summary: "Extended downhill, very low load, minimal fuelling.",
                    exercises: "Descent detection, economy outliers, fuel rate near zero."),
        OBDScenario(id: .lowBattery,
                    title: "Low battery voltage",
                    summary: "Charging voltage sits below the normal band while running.",
                    exercises: "Battery baseline deltas and the battery watch insight."),
        OBDScenario(id: .highCoolantTemperature,
                    title: "High coolant temperature",
                    summary: "Coolant climbs past the normal band towards a critical threshold.",
                    exercises: "Escalation from normal to watch to critical, and CarPlay urgency ordering."),
        OBDScenario(id: .highEngineLoad,
                    title: "Sustained high engine load",
                    summary: "90%+ load held for minutes on flat ground.",
                    exercises: "Load anomalies without a terrain explanation."),
        OBDScenario(id: .fuelRunningLow,
                    title: "Fuel running low",
                    summary: "Tank level falls from 9% towards 3%.",
                    exercises: "Range estimation, low-fuel insight, reserve wording."),
        OBDScenario(id: .dpfWarning,
                    title: "DPF trouble code",
                    summary: "The vehicle stores P2002 and turns on the warning light.",
                    exercises: "DTC reading and plain-language explanation. Note: no soot-load telemetry is simulated, because DriveLayer cannot read it on a real car either."),
        OBDScenario(id: .sensorUnavailable,
                    title: "Sensors unavailable",
                    summary: "The vehicle doesn't report coolant temperature or fuel level.",
                    exercises: "Graceful disappearance of unsupported values — nothing may render as zero."),
        OBDScenario(id: .linkDropAndRecover,
                    title: "Adapter drops and reconnects",
                    summary: "The Bluetooth link fails mid-drive and comes back a little later.",
                    exercises: "Connection state handling, trip continuity across a gap."),
        OBDScenario(id: .invalidResponses,
                    title: "Invalid OBD responses",
                    summary: "The adapter returns corrupted frames, NO DATA and unrecognised replies.",
                    exercises: "Parser robustness and the rule that a bad frame never becomes a reading.")
    ]
}

/// Deterministic pseudo-randomness, so a scenario replays identically for a given seed.
struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    init(seed: UInt64) { self.state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A value in -magnitude...magnitude.
    mutating func jitter(_ magnitude: Double) -> Double {
        guard magnitude > 0 else { return 0 }
        let unit = Double(next() % 10_000) / 10_000.0
        return (unit * 2 - 1) * magnitude
    }
}
