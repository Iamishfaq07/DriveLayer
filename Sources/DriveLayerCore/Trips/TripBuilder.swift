import Foundation

/// Accumulates a drive as it happens and produces the finished `Trip`.
///
/// Kept separate from `TripRecorder` so the "when does a drive start and stop"
/// decisions and the "what did the drive consist of" arithmetic can be read, and
/// tested, independently.
struct TripBuilder: Sendable {

    let id: UUID
    let vehicleID: UUID
    let startedAt: Date
    let tankCapacityLitres: Double?
    let profile: VehicleProfile?

    private(set) var distanceMetres: Double = 0
    private(set) var movingSeconds: TimeInterval = 0
    private(set) var idleSeconds: TimeInterval = 0
    private(set) var events: [TripEvent] = []
    private(set) var routePolyline: [Trip.RoutePoint] = []
    private(set) var lastEngineRunningAt: Date?
    private(set) var telemetrySampleCount: Int = 0

    private var elevation = ElevationAccumulator()
    private var lastPoint: GeoPoint?
    private var lastKeptRoutePoint: Trip.RoutePoint?
    private var startPoint: GeoPoint?
    private var endPoint: GeoPoint?

    private var maximumSpeedKmh: Double?
    private var movingSpeedSum: Double = 0
    private var movingSpeedSamples: Int = 0
    private var maximumAltitude: Double?
    private var minimumAltitude: Double?

    private var integratedFuelLitres: Double = 0
    private var sawFuelRate = false
    private var firstFuelLevelPercent: Double?
    private var lastFuelLevelPercent: Double?

    private var peakCoolant: Double?
    private var loadSum: Double = 0
    private var loadSamples: Int = 0
    private var minimumVoltage: Double?
    private var reportedCoolantEvent = false
    private var reportedVoltageEvent = false

    /// Route points closer together than this are redundant for drawing a line.
    private let routePointSpacingMetres: Double = 25
    private let routePointMaximumGapSeconds: TimeInterval = 20

    init(id: UUID = UUID(),
         vehicleID: UUID,
         startedAt: Date,
         tankCapacityLitres: Double? = nil,
         profile: VehicleProfile? = nil) {
        self.id = id
        self.vehicleID = vehicleID
        self.startedAt = startedAt
        self.tankCapacityLitres = tankCapacityLitres
        self.profile = profile
    }

    mutating func add(event: TripEvent) {
        events.append(event)
    }

    mutating func ingest(location: GeoPoint?, telemetry: VehicleTelemetry?, interval: TimeInterval, now: Date) {
        ingestLocation(location, interval: interval)
        ingestTelemetry(telemetry, interval: interval, now: now)
    }

    private mutating func ingestLocation(_ location: GeoPoint?, interval: TimeInterval) {
        guard let location, location.isUsableForRouting else { return }
        if startPoint == nil { startPoint = location }
        endPoint = location

        if let last = lastPoint {
            let metres = Geo.distance(from: last, to: location)
            let seconds = location.timestamp.timeIntervalSince(last.timestamp)
            // Reject impossible jumps: a bad fix must not add kilometres to a drive.
            let isPlausible = seconds <= 0 || (metres / seconds) <= 90
            if isPlausible { distanceMetres += metres }
        }
        lastPoint = location

        if let altitude = location.altitudeMetres {
            elevation.add(altitudeMetres: altitude)
            maximumAltitude = max(maximumAltitude ?? altitude, altitude)
            minimumAltitude = min(minimumAltitude ?? altitude, altitude)
        }

        appendRoutePointIfUseful(location)
    }

    private mutating func appendRoutePointIfUseful(_ location: GeoPoint) {
        let candidate = Trip.RoutePoint(latitude: location.latitude,
                                        longitude: location.longitude,
                                        altitudeMetres: location.altitudeMetres,
                                        timestamp: location.timestamp)
        guard let last = lastKeptRoutePoint else {
            routePolyline.append(candidate)
            lastKeptRoutePoint = candidate
            return
        }
        let metres = Geo.distance(fromLatitude: last.latitude, longitude: last.longitude,
                                  toLatitude: candidate.latitude, longitude: candidate.longitude)
        let seconds = candidate.timestamp.timeIntervalSince(last.timestamp)
        guard metres >= routePointSpacingMetres || seconds >= routePointMaximumGapSeconds else { return }
        routePolyline.append(candidate)
        lastKeptRoutePoint = candidate
    }

    private mutating func ingestTelemetry(_ telemetry: VehicleTelemetry?, interval: TimeInterval, now: Date) {
        guard let telemetry else { return }
        telemetrySampleCount += 1

        if telemetry.isEngineRunning(now: now) == true {
            lastEngineRunningAt = now
        }

        if let speed = telemetry.value(.vehicleSpeedKmh, freshWithin: 6, now: now) {
            maximumSpeedKmh = max(maximumSpeedKmh ?? speed, speed)
            if speed >= 3 {
                movingSeconds += interval
                movingSpeedSum += speed
                movingSpeedSamples += 1
            } else {
                idleSeconds += interval
            }
        }

        if let rate = telemetry.value(.fuelRateLitresPerHour, freshWithin: 10, now: now), rate >= 0 {
            sawFuelRate = true
            integratedFuelLitres += rate * (interval / 3_600)
        }

        if let level = telemetry.value(.fuelLevelPercent, freshWithin: 180, now: now) {
            if firstFuelLevelPercent == nil { firstFuelLevelPercent = level }
            lastFuelLevelPercent = level
        }

        if let coolant = telemetry.value(.coolantTemperatureC, freshWithin: 60, now: now) {
            peakCoolant = max(peakCoolant ?? coolant, coolant)
            if !reportedCoolantEvent,
               let range = profile?.operatingRange(for: .coolantTemperatureC, condition: .warmedUp),
               range.status(for: coolant) >= .attention {
                reportedCoolantEvent = true
                events.append(TripEvent(kind: .coolantAboveNormal, timestamp: now, severity: range.status(for: coolant),
                                        note: String(format: "Coolant reached %.0f °C.", coolant)))
            }
        }

        if let load = telemetry.value(.engineLoadPercent, freshWithin: 15, now: now) {
            loadSum += load
            loadSamples += 1
        }

        if let voltage = telemetry.value(.controlModuleVoltageV, freshWithin: 120, now: now) {
            minimumVoltage = min(minimumVoltage ?? voltage, voltage)
            if !reportedVoltageEvent,
               telemetry.isEngineRunning(now: now) == true,
               let range = profile?.operatingRange(for: .controlModuleVoltageV, condition: .engineRunning),
               range.status(for: voltage) >= .attention {
                reportedVoltageEvent = true
                events.append(TripEvent(kind: .lowBatteryVoltage, timestamp: now, severity: range.status(for: voltage),
                                        note: String(format: "Charging voltage was %.2f V.", voltage)))
            }
        }
    }

    /// A read-only view of the drive so far, for the live Drive screen.
    func snapshot(at time: Date? = nil) -> Trip {
        buildTrip(endedAt: time, reason: nil)
    }

    mutating func finish(at time: Date, reason: TripEndReason) -> Trip {
        buildTrip(endedAt: time, reason: reason)
    }

    private func buildTrip(endedAt: Date?, reason: TripEndReason?) -> Trip {
        Trip(id: id,
             vehicleID: vehicleID,
             startedAt: startedAt,
             endedAt: endedAt,
             endReason: reason,
             distanceMetres: distanceMetres,
             movingDurationSeconds: movingSeconds,
             idleDurationSeconds: idleSeconds,
             elevationGainMetres: elevation.gainMetres,
             elevationLossMetres: elevation.lossMetres,
             maximumAltitudeMetres: maximumAltitude,
             minimumAltitudeMetres: minimumAltitude,
             maximumSpeedKmh: maximumSpeedKmh,
             averageMovingSpeedKmh: movingSpeedSamples > 0 ? movingSpeedSum / Double(movingSpeedSamples) : nil,
             startOdometerKm: nil,
             fuelUsedLitres: resolvedFuelUsed(),
             startLatitude: startPoint?.latitude,
             startLongitude: startPoint?.longitude,
             endLatitude: endPoint?.latitude,
             endLongitude: endPoint?.longitude,
             routePolyline: routePolyline,
             events: events,
             weather: nil,
             telemetrySampleCount: telemetrySampleCount,
             peakCoolantTemperatureC: peakCoolant,
             averageEngineLoadPercent: loadSamples > 0 ? loadSum / Double(loadSamples) : nil,
             minimumControlModuleVoltage: minimumVoltage)
    }

    /// Fuel used, with the derivation recorded.
    ///
    /// Three tiers, in descending order of trust, and an explicit "we don't know" at
    /// the end. A phone-only drive reports no fuel figure at all rather than a zero.
    private func resolvedFuelUsed() -> Provenanced<Double> {
        if sawFuelRate && integratedFuelLitres > 0 {
            return .estimated(integratedFuelLitres,
                              basis: "Integrated from the fuel rate your vehicle reported during the drive.")
        }
        if let first = firstFuelLevelPercent,
           let last = lastFuelLevelPercent,
           let capacity = tankCapacityLitres, capacity > 0 {
            let dropPercent = first - last
            // Tank senders are coarse and slosh with the road; below a couple of
            // percent the "change" is noise, not fuel.
            if dropPercent >= 2 {
                return .estimated(capacity * dropPercent / 100,
                                  basis: "From the change in your vehicle's reported tank level, which is a coarse measurement.")
            }
        }
        return .unavailable(basis: "This drive had no fuel data. Connect an adapter that reports fuel rate or tank level for an estimate.")
    }
}
