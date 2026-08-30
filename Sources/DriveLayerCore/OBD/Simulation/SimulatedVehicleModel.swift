import Foundation

/// The instantaneous state of a simulated vehicle. Every field mirrors something a
/// real vehicle could report over standard OBD-II — nothing here is invented
/// telemetry that DriveLayer could not also read from a real car.
struct SimulatedVehicleState: Sendable, Equatable {
    var elapsed: TimeInterval = 0
    var isEngineRunning: Bool = true
    var speedKmh: Double = 0
    var rpm: Double = 800
    var coolantC: Double = 20
    var engineLoadPercent: Double = 15
    var intakeAirC: Double = 25
    var ambientC: Double = 25
    var throttlePercent: Double = 8
    var fuelLevelPercent: Double = 62
    var fuelRateLitresPerHour: Double = 1.0
    var controlModuleVoltage: Double = 14.1
    var manifoldPressureKPa: Double = 100
    var runtimeSeconds: Double = 0
    var milOn: Bool = false
    var storedCodes: [String] = []
    var pendingCodes: [String] = []

    /// Standard PID codes this simulated vehicle answers. Everything else returns
    /// NO DATA, exactly as an unsupported PID does on a real car.
    var supportedCodes: Set<UInt8> = SimulatedVehicleModel.defaultSupportedCodes
    /// When true the transport behaves as if the Bluetooth link is gone.
    var linkIsDown: Bool = false
    /// When true a share of replies are corrupted, truncated or unrecognised.
    var emitsInvalidResponses: Bool = false
}

/// Advances a simulated vehicle through a scenario.
///
/// The model is deliberately simple and explicable: first-order thermal lag, load
/// driven by the scenario's speed profile, fuel flow from load and engine speed. It
/// exists to exercise DriveLayer's own logic, not to be a engine simulator.
struct SimulatedVehicleModel: Sendable {

    static let defaultSupportedCodes: Set<UInt8> = [
        0x00, 0x01, 0x04, 0x05, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10, 0x11, 0x1F,
        0x20, 0x21, 0x2F, 0x31, 0x33,
        0x40, 0x42, 0x43, 0x45, 0x46, 0x47, 0x4C, 0x51, 0x5A, 0x5C, 0x5E
    ]

    let scenario: OBDScenarioID
    /// Tank size used to turn fuel flow into a falling level. Matches the reference
    /// vehicle's published capacity by default.
    let tankLitres: Double
    private(set) var state: SimulatedVehicleState
    private var generator: SeededGenerator

    init(scenario: OBDScenarioID, tankLitres: Double = 50, seed: UInt64 = 42) {
        self.scenario = scenario
        self.tankLitres = tankLitres
        self.generator = SeededGenerator(seed: seed)
        self.state = SimulatedVehicleModel.initialState(for: scenario)
    }

    static func initialState(for scenario: OBDScenarioID) -> SimulatedVehicleState {
        var state = SimulatedVehicleState()
        switch scenario {
        case .coldStart:
            state.ambientC = 14
            state.coolantC = 14
            state.intakeAirC = 15
            state.speedKmh = 0
            state.rpm = 1100
        case .hotCityTraffic:
            state.ambientC = 38
            state.coolantC = 92
            state.intakeAirC = 46
            state.speedKmh = 12
        case .mountainClimb:
            state.coolantC = 92
            state.speedKmh = 52
            state.ambientC = 21
            state.fuelLevelPercent = 48
        case .longDescent:
            state.coolantC = 94
            state.speedKmh = 62
            state.ambientC = 18
            state.fuelLevelPercent = 44
        case .lowBattery:
            state.coolantC = 90
            state.speedKmh = 60
            state.controlModuleVoltage = 12.1
        case .highCoolantTemperature:
            state.coolantC = 99
            state.speedKmh = 70
            state.ambientC = 34
        case .highEngineLoad:
            state.coolantC = 93
            state.speedKmh = 88
            state.engineLoadPercent = 88
        case .fuelRunningLow:
            state.coolantC = 91
            state.speedKmh = 78
            state.fuelLevelPercent = 9
        case .dpfWarning:
            state.coolantC = 90
            state.speedKmh = 46
            state.milOn = true
            state.storedCodes = ["P2002"]
        case .sensorUnavailable:
            state.coolantC = 90
            state.speedKmh = 64
            state.supportedCodes.remove(0x05)
            state.supportedCodes.remove(0x2F)
        case .linkDropAndRecover:
            state.coolantC = 90
            state.speedKmh = 72
        case .invalidResponses:
            state.coolantC = 90
            state.speedKmh = 58
            state.emitsInvalidResponses = true
        case .normalHighway:
            state.coolantC = 88
            state.speedKmh = 95
        }
        return state
    }

    /// Steps the model forward. Steps larger than a few seconds are subdivided so
    /// thermal behaviour doesn't depend on how often the caller polls.
    mutating func advance(by interval: TimeInterval) {
        guard interval > 0 else { return }
        var remaining = interval
        let maximumStep: TimeInterval = 2.0
        while remaining > 0 {
            let step = min(remaining, maximumStep)
            stepOnce(step)
            remaining -= step
        }
    }

    private mutating func stepOnce(_ dt: TimeInterval) {
        state.elapsed += dt
        let t = state.elapsed

        state.speedKmh = max(0, targetSpeed(at: t) + generator.jitter(1.2))
        state.engineLoadPercent = Statistics.clamp(targetLoad(at: t) + generator.jitter(2.0), 0...100)
        state.isEngineRunning = true
        state.runtimeSeconds += dt

        // Engine speed: idle plus a road-speed component, lifted by load.
        let idle: Double = state.coolantC < 40 ? 1_000 : 780
        let fromRoadSpeed = state.speedKmh * 18.0
        let fromLoad = state.engineLoadPercent * 4.0
        state.rpm = Statistics.clamp(idle + fromRoadSpeed + fromLoad, 600...4_500)

        // First-order thermal lag towards a load- and ambient-dependent target.
        let coolantTarget = targetCoolant(at: t)
        let tau: Double = state.coolantC < 70 ? 190 : 320
        state.coolantC += (coolantTarget - state.coolantC) * (dt / tau)

        state.intakeAirC += (targetIntakeAir() - state.intakeAirC) * (dt / 60)
        state.throttlePercent = Statistics.clamp(state.engineLoadPercent * 0.75 + generator.jitter(1.5), 0...100)
        state.manifoldPressureKPa = Statistics.clamp(95 + state.engineLoadPercent * 1.4, 20...255)
        state.controlModuleVoltage = targetVoltage(at: t)

        // Fuel flow from load and engine speed, then drain the tank with it.
        let litresPerHour = max(0.4, 0.7 + (state.engineLoadPercent / 100) * (state.rpm / 1_000) * 7.0)
        state.fuelRateLitresPerHour = litresPerHour
        let litresBurned = litresPerHour * (dt / 3_600)
        if tankLitres > 0 {
            state.fuelLevelPercent = max(0, state.fuelLevelPercent - (litresBurned / tankLitres) * 100)
        }

        // The link drops between 60 s and 105 s, then recovers on its own.
        if scenario == .linkDropAndRecover {
            state.linkIsDown = (t >= 60 && t < 105)
        }
    }

    // MARK: - Scenario profiles

    private func targetSpeed(at t: TimeInterval) -> Double {
        switch scenario {
        case .normalHighway:
            return 95
        case .coldStart:
            // Idle for 40 s, then pull away and build up to town speed.
            if t < 40 { return 0 }
            return min(48, (t - 40) * 1.6)
        case .hotCityTraffic:
            // Repeating crawl-and-stop cycle, roughly 90 seconds long.
            let phase = t.truncatingRemainder(dividingBy: 90)
            if phase < 30 { return 0 }
            if phase < 60 { return (phase - 30) * 1.1 }
            return max(0, 33 - (phase - 60) * 1.1)
        case .mountainClimb:
            return 52 - min(10, t / 240)
        case .longDescent:
            return 62 + min(14, t / 120)
        case .lowBattery:
            return 60
        case .highCoolantTemperature:
            return 70
        case .highEngineLoad:
            return 88
        case .fuelRunningLow:
            return 78
        case .dpfWarning:
            return 46
        case .sensorUnavailable:
            return 64
        case .linkDropAndRecover:
            return 72
        case .invalidResponses:
            return 58
        }
    }

    private func targetLoad(at t: TimeInterval) -> Double {
        switch scenario {
        case .normalHighway: return 38
        case .coldStart: return t < 40 ? 22 : 42
        case .hotCityTraffic: return state.speedKmh < 2 ? 18 : 42
        case .mountainClimb: return min(84, 62 + t / 90)
        case .longDescent: return 6
        case .lowBattery: return 36
        case .highCoolantTemperature: return 74
        case .highEngineLoad: return 91
        case .fuelRunningLow: return 40
        case .dpfWarning: return 44
        case .sensorUnavailable: return 39
        case .linkDropAndRecover: return 41
        case .invalidResponses: return 37
        }
    }

    private func targetCoolant(at t: TimeInterval) -> Double {
        let loadContribution = state.engineLoadPercent * 0.12
        switch scenario {
        case .coldStart:
            return 88 + loadContribution
        case .hotCityTraffic:
            // Little airflow when stopped, so heat builds in traffic.
            return state.speedKmh < 5 ? 101 : 95
        case .mountainClimb:
            return 96 + loadContribution
        case .longDescent:
            return 84
        case .highCoolantTemperature:
            // Climbs steadily past the normal band to exercise escalation.
            return min(118, 100 + t / 45)
        case .highEngineLoad:
            return 99
        default:
            return 88 + loadContribution
        }
    }

    private func targetIntakeAir() -> Double {
        switch scenario {
        case .hotCityTraffic: return state.ambientC + 12
        case .mountainClimb, .highEngineLoad: return state.ambientC + 18
        default: return state.ambientC + 6
        }
    }

    private func targetVoltage(at t: TimeInterval) -> Double {
        switch scenario {
        case .lowBattery:
            // Sags further under load, which is what a tired battery does.
            return 12.3 - min(0.5, t / 600) - (state.engineLoadPercent / 100) * 0.3
        case .coldStart:
            return t < 10 ? 12.4 : 14.2
        default:
            return 14.1
        }
    }
}
