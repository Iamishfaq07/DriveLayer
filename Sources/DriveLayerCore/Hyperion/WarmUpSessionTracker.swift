import Foundation

/// Builds one trustworthy warm-up observation from successive live samples.
struct WarmUpSessionTracker: Sendable {
    private var startedAt: Date?
    private var startingCoolantC: Double?
    private var ambientC: Double?
    private var rpmIntegral = 0.0
    private var sampledSeconds = 0.0
    private var distanceKm = 0.0
    private var lastSampleAt: Date?

    mutating func reset() {
        startedAt = nil
        startingCoolantC = nil
        ambientC = nil
        rpmIntegral = 0
        sampledSeconds = 0
        distanceKm = 0
        lastSampleAt = nil
    }

    mutating func ingest(at now: Date,
                         coolant: Provenanced<Double>,
                         ambient: Provenanced<Double>,
                         rpm: Double?,
                         speedKmh: Double?,
                         engineRunning: Bool?,
                         profile: VehicleProfile?) -> WarmUpObservation? {
        guard engineRunning == true else {
            if engineRunning == false { reset() }
            return nil
        }
        guard coolant.provenance.describesRealVehicle,
              let coolantC = coolant.value,
              coolantC.isFinite else { return nil }

        let phase = EngineThermalModel.phase(coolantC: coolantC, profile: profile)
        if startedAt == nil {
            guard phase == .cold || phase == .warming else { return nil }
            startedAt = now
            startingCoolantC = coolantC
            if ambient.provenance.describesRealVehicle { ambientC = ambient.value }
            lastSampleAt = now
            return nil
        }

        if let previous = lastSampleAt {
            let elapsed = min(max(now.timeIntervalSince(previous), 0), 5)
            if let rpm, rpm.isFinite, rpm >= 0 {
                rpmIntegral += rpm * elapsed
                sampledSeconds += elapsed
            }
            if let speedKmh, speedKmh.isFinite, speedKmh >= 0 {
                distanceKm += speedKmh * elapsed / 3_600
            }
        }
        lastSampleAt = now

        guard phase == .operating,
              let start = startedAt,
              let startingCoolantC else { return nil }
        let observation = WarmUpObservation(
            startedAt: start,
            secondsToOperating: now.timeIntervalSince(start),
            startingCoolantC: startingCoolantC,
            ambientC: ambientC,
            averageRPM: sampledSeconds > 0 ? rpmIntegral / sampledSeconds : nil,
            distanceKm: distanceKm > 0 ? distanceKm : nil
        )
        reset()
        return observation
    }
}
