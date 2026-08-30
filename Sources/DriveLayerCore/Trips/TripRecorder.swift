import Foundation

struct TripRecorderConfiguration: Sendable, Equatable {
    var startSpeedKmh: Double = 8
    var startSustainSeconds: TimeInterval = 12
    var stopSpeedKmh: Double = 3
    var stopSustainSeconds: TimeInterval = 150
    /// How long the engine may be off before the drive is considered over.
    var engineOffGraceSeconds: TimeInterval = 45
    /// Drives below both of these are noise — a reverse out of a parking space, a
    /// stray GPS jump — and are discarded rather than cluttering history.
    var minimumDistanceMetres: Double = 250
    var minimumDurationSeconds: TimeInterval = 60
    /// A silence longer than this means the app was suspended or the phone lost signal;
    /// the drive is closed at its last known point rather than spanning the gap.
    var maximumSilenceSeconds: TimeInterval = 900
    var longIdleThresholdSeconds: TimeInterval = 180
    /// Speed change per second that counts as hard braking or rapid acceleration.
    var hardBrakingKmhPerSecond: Double = 11
    var rapidAccelerationKmhPerSecond: Double = 9

    static let `default` = TripRecorderConfiguration()
}

enum TripRecorderState: Equatable, Sendable {
    case idle
    /// Movement detected, waiting to see whether it is a real drive.
    case arming(since: Date)
    case recording
    /// Stopped, waiting to see whether the drive has actually ended.
    case stopping(since: Date)
}

enum TripRecorderOutcome: Equatable, Sendable {
    case none
    case started(UUID)
    case updated
    case ended(Trip)
    /// Carries the id as well as the reason: a discarded drive may already have been
    /// checkpointed to disk, and the caller needs to know which row to remove.
    case discarded(id: UUID, reason: String)
}

/// Decides when a drive starts and stops, and accumulates it.
///
/// Deliberately a pure value type driven by explicit `update(…)` calls: no timers, no
/// CoreLocation, no Bluetooth. Every awkward case — a duplicate start, a dropped
/// adapter, an app kill mid-drive, a car park crawl — is reachable in a unit test.
struct TripRecorder: Sendable {

    let configuration: TripRecorderConfiguration
    let vehicleID: UUID
    let tankCapacityLitres: Double?
    let profile: VehicleProfile?

    private(set) var state: TripRecorderState = .idle
    private(set) var builder: TripBuilder?

    private var lastUpdate: Date?
    private var lastSpeedKmh: Double?
    private var idleRunSeconds: TimeInterval = 0
    private var lastLongIdleReportedAt: Date?

    init(vehicleID: UUID,
         configuration: TripRecorderConfiguration = .default,
         tankCapacityLitres: Double? = nil,
         profile: VehicleProfile? = nil) {
        self.vehicleID = vehicleID
        self.configuration = configuration
        self.tankCapacityLitres = tankCapacityLitres
        self.profile = profile
    }

    var currentTrip: Trip? { builder?.snapshot() }

    var isRecording: Bool {
        if case .recording = state { return true }
        if case .stopping = state { return true }
        return false
    }

    // MARK: - Main entry point

    /// Feeds one observation into the recorder.
    ///
    /// - Parameters:
    ///   - location: the newest fix, or `nil` when there isn't one.
    ///   - telemetry: the newest vehicle data, or `nil` on a phone-only drive.
    ///   - now: the current time, injected so tests control the clock.
    mutating func update(location: GeoPoint?, telemetry: VehicleTelemetry?, now: Date) -> TripRecorderOutcome {
        defer { lastUpdate = now }

        // A long silence means we were not running. Close the drive at its last point
        // rather than inventing the missing time and distance.
        if let last = lastUpdate,
           now.timeIntervalSince(last) > configuration.maximumSilenceSeconds,
           isRecording {
            return finish(at: last, reason: .recoveredAfterInterruption)
        }

        let speed = resolvedSpeedKmh(location: location, telemetry: telemetry, now: now)
        let engineRunning = telemetry?.isEngineRunning(now: now)
        let interval = lastUpdate.map { now.timeIntervalSince($0) } ?? 0

        switch state {
        case .idle:
            guard shouldConsiderStarting(speed: speed, engineRunning: engineRunning) else { return .none }
            state = .arming(since: now)
            return .none

        case let .arming(since):
            if !shouldConsiderStarting(speed: speed, engineRunning: engineRunning) {
                state = .idle
                return .none
            }
            guard now.timeIntervalSince(since) >= configuration.startSustainSeconds else { return .none }
            var newBuilder = TripBuilder(vehicleID: vehicleID,
                                         startedAt: since,
                                         tankCapacityLitres: tankCapacityLitres,
                                         profile: profile)
            newBuilder.ingest(location: location, telemetry: telemetry, interval: 0, now: now)
            builder = newBuilder
            state = .recording
            idleRunSeconds = 0
            lastSpeedKmh = speed
            return .started(newBuilder.id)

        case .recording, .stopping:
            guard builder != nil else {
                state = .idle
                return .none
            }
            accumulate(location: location, telemetry: telemetry, speed: speed, interval: interval, now: now)

            if isEngineOffLongEnough(now: now, engineRunning: engineRunning) {
                return finish(at: now, reason: .engineOff)
            }

            let isStopped = (speed ?? 0) < configuration.stopSpeedKmh
            if isStopped {
                if case .recording = state {
                    state = .stopping(since: now)
                } else if case let .stopping(since) = state,
                          now.timeIntervalSince(since) >= configuration.stopSustainSeconds {
                    return finish(at: now, reason: .stoppedMoving)
                }
            } else if case .stopping = state {
                state = .recording
            }
            return .updated
        }
    }

    /// Starts a drive because the driver asked. A second call while already recording
    /// is ignored rather than producing a duplicate trip.
    mutating func startManually(now: Date) -> TripRecorderOutcome {
        guard !isRecording else { return .none }
        var newBuilder = TripBuilder(vehicleID: vehicleID,
                                     startedAt: now,
                                     tankCapacityLitres: tankCapacityLitres,
                                     profile: profile)
        newBuilder.ingest(location: nil, telemetry: nil, interval: 0, now: now)
        builder = newBuilder
        state = .recording
        lastUpdate = now
        idleRunSeconds = 0
        return .started(newBuilder.id)
    }

    mutating func endManually(now: Date) -> TripRecorderOutcome {
        guard isRecording else { return .none }
        return finish(at: now, reason: .manual)
    }

    /// Notes that the adapter dropped or came back, so trip history shows the gap.
    mutating func noteAdapterConnectionChange(connected: Bool, at time: Date) {
        guard builder != nil else { return }
        builder?.add(event: TripEvent(
            kind: connected ? .adapterReconnected : .adapterDisconnected,
            timestamp: time,
            severity: connected ? .normal : .watch,
            note: connected ? "Vehicle data resumed." : "Vehicle data stopped; the drive kept recording from your phone."
        ))
    }

    mutating func add(event: TripEvent) {
        builder?.add(event: event)
    }

    // MARK: - Internals

    private mutating func accumulate(location: GeoPoint?,
                                     telemetry: VehicleTelemetry?,
                                     speed: Double?,
                                     interval: TimeInterval,
                                     now: Date) {
        let clampedInterval = Statistics.clamp(interval, 0...120)
        builder?.ingest(location: location, telemetry: telemetry, interval: clampedInterval, now: now)

        if let speed {
            if speed < configuration.stopSpeedKmh {
                idleRunSeconds += clampedInterval
                if idleRunSeconds >= configuration.longIdleThresholdSeconds,
                   lastLongIdleReportedAt.map({ now.timeIntervalSince($0) > configuration.longIdleThresholdSeconds }) ?? true {
                    lastLongIdleReportedAt = now
                    let minutes = Int(idleRunSeconds / 60)
                    builder?.add(event: TripEvent(
                        kind: .longIdle,
                        timestamp: now,
                        severity: .watch,
                        note: "Stationary with the engine running for about \(max(1, minutes)) minutes.",
                        latitude: location?.latitude,
                        longitude: location?.longitude
                    ))
                }
            } else {
                idleRunSeconds = 0
            }

            if let previous = lastSpeedKmh, clampedInterval > 0.4 {
                let change = (speed - previous) / clampedInterval
                if change <= -configuration.hardBrakingKmhPerSecond {
                    builder?.add(event: TripEvent(kind: .hardBraking, timestamp: now, severity: .watch,
                                                  note: "Speed dropped quickly.",
                                                  latitude: location?.latitude, longitude: location?.longitude))
                } else if change >= configuration.rapidAccelerationKmhPerSecond {
                    builder?.add(event: TripEvent(kind: .rapidAcceleration, timestamp: now, severity: .watch,
                                                  note: "Rapid acceleration.",
                                                  latitude: location?.latitude, longitude: location?.longitude))
                }
            }
            lastSpeedKmh = speed
        }
    }

    private mutating func finish(at time: Date, reason: TripEndReason) -> TripRecorderOutcome {
        guard var finished = builder else {
            state = .idle
            return .none
        }
        state = .idle
        builder = nil
        idleRunSeconds = 0
        lastSpeedKmh = nil
        lastLongIdleReportedAt = nil

        let trip = finished.finish(at: time, reason: reason)
        if trip.distanceMetres < configuration.minimumDistanceMetres
            && trip.totalDurationSeconds < configuration.minimumDurationSeconds {
            return .discarded(id: trip.id, reason: "Too short to be a drive.")
        }
        return .ended(trip)
    }

    /// Movement alone is not enough when the vehicle tells us the engine is off:
    /// that pattern is a car on a ferry, a tow truck, or a phone in someone else's car.
    private func shouldConsiderStarting(speed: Double?, engineRunning: Bool?) -> Bool {
        if engineRunning == false { return false }
        guard let speed else { return false }
        return speed >= configuration.startSpeedKmh
    }

    private func isEngineOffLongEnough(now: Date, engineRunning: Bool?) -> Bool {
        guard engineRunning == false, let builder else { return false }
        guard let lastRunning = builder.lastEngineRunningAt else { return false }
        return now.timeIntervalSince(lastRunning) >= configuration.engineOffGraceSeconds
    }

    /// Vehicle speed is preferred when the adapter reports it; GPS is the fallback.
    private func resolvedSpeedKmh(location: GeoPoint?, telemetry: VehicleTelemetry?, now: Date) -> Double? {
        if let obdSpeed = telemetry?.value(.vehicleSpeedKmh, freshWithin: 6, now: now) {
            return obdSpeed
        }
        guard let location, location.isUsableForRouting else { return nil }
        guard let metresPerSecond = location.speedMetresPerSecond else { return nil }
        return Convert.kmh(fromMetresPerSecond: metresPerSecond)
    }
}

/// Closes out a trip that was still open when the app was terminated.
enum TripRecovery {
    /// Finalises an interrupted trip using the last point actually recorded.
    ///
    /// The missing time is not filled in and no distance is invented: an interrupted
    /// drive is shorter than reality, and saying so is better than inflating it.
    static func finalise(_ trip: Trip, lastKnownActivityAt: Date, configuration: TripRecorderConfiguration = .default) -> Trip? {
        guard trip.endedAt == nil else { return trip }
        var recovered = trip
        recovered.endedAt = max(lastKnownActivityAt, trip.startedAt)
        recovered.endReason = .recoveredAfterInterruption
        if recovered.distanceMetres < configuration.minimumDistanceMetres
            && recovered.totalDurationSeconds < configuration.minimumDurationSeconds {
            return nil
        }
        return recovered
    }
}
