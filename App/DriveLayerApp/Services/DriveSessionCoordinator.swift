import Foundation

/// The one place the live pieces meet.
///
/// Location, motion, vehicle telemetry, the trip recorder, baselines and the insight
/// engine each know nothing about the others; this object ticks them in the right
/// order and at the right rate. Keeping the wiring in one file is what stops
/// Bluetooth code, trip logic and view models from bleeding into each other.
///
/// Two rates matter. The drive loop runs at 1 Hz, which is enough to record a trip
/// accurately. Analysis — insights, health, terrain — runs every few seconds,
/// because re-deriving the whole picture at 1 Hz would burn battery to tell the
/// driver the same thing sixty times a minute.
@MainActor
@Observable
final class DriveSessionCoordinator {

    // Live state the UI reads.
    private(set) var currentTrip: Trip?
    private(set) var insights: [DriveInsight] = []
    private(set) var health: VehicleHealthReport?
    private(set) var fuelStatus: FuelStatus = .unknown
    private(set) var dieselAssessment: DieselUsageAssessment?
    /// What DriveLayer makes of the Hyperion engine right now.
    ///
    /// The analysers behind this were written and wired to nothing: EngineThermalModel
    /// and HeatSoakAnalyser were tested and reachable from no production code at all.
    /// This property is the seam that gets them to a driver.
    private(set) var hyperion: HyperionAssessment = .unavailable
    private(set) var gradient: GradientEstimate?
    private(set) var terrainFeature: TerrainFeature?
    private(set) var currentWeather: WeatherSnapshot?
    private(set) var weatherChanges: [WeatherChange] = []
    private(set) var weatherUnavailability: UnavailabilityReason?
    /// Where the driver said they are going, if anywhere.
    private(set) var destination: RouteDestination?
    private(set) var routeUnavailability: UnavailabilityReason?
    private(set) var isRecording = false
    private(set) var lastAnalysisAt: Date?

    var vehicle: Vehicle?
    var profile: VehicleProfile?

    private let store: GarageStore
    private let telemetryStore: TelemetryWriting
    private let obd: OBDConnectionManager
    private let location: LocationService
    private let motion: MotionService
    private let settings: AppSettings
    private var weather: WeatherProviding
    private var route: RouteProviding
    /// Set by `AppEnvironment` after construction; reminders are a side effect of
    /// analysis rather than something the coordinator needs to own.
    weak var reminders: ReminderScheduler?

    private var recorder: TripRecorder?
    private var gradientCalculator = GradientCalculator()
    private let insightEngine = InsightEngine()
    private var downsampler = TelemetryDownsampler()
    private var pendingSamples: [TelemetrySample] = []
    /// Samples retained because a write failed, capped so a disk that keeps refusing
    /// cannot grow this without limit. Five thousand is roughly eighty minutes at 1 Hz.
    private static let maximumPendingSamples = 5_000
    private var telemetryWriteFailures = 0
    private(set) var droppedTelemetrySamples = 0

    /// Live telemetry not yet on disk.
    ///
    /// The Debug Center shows this because it is exactly the amount at risk if iOS
    /// terminates the app in the next moment, and because a number that stops falling is
    /// how a failing write announces itself.
    var pendingTelemetryCount: Int { pendingSamples.count }
    private var pendingBaselines: [BaselineDailyAggregate] = []
    private var baselines: [BaselineKey: MetricBaseline] = [:]

    /// Impacts already taken from `MotionService`, so the same jolt is not recorded
    /// twice as the loop re-reads its rolling buffer.
    private var consumedImpactIDs: Set<UUID> = []

    /// Last adapter state the loop saw, so a change can be recorded on the drive.
    private var lastAdapterConnected: Bool?

    /// Highest intake-over-ambient difference seen recently, so a fall can be reported as
    /// cooling rather than as a smaller number. Decays rather than latching.
    private var peakIntakeDeltaC: Double?

    private var driveLoop: Task<Void, Never>?
    /// When the live drive was last written to disk. See `checkpoint(force:now:)`.
    private var lastCheckpointAt: Date?
    private var lastWeatherFetch: Date?
    /// When the next route lookup may happen. Set *after* an attempt finishes rather
    /// than before it starts, so a failure does not lock the feature out for the whole
    /// interval, and a shorter one is used when the failure is the kind that passes.
    private var nextRouteFetchAfter: Date?
    /// The refresh currently in flight, if any. Held so a destination change can cancel
    /// it rather than race it.
    private var routeWeatherTask: Task<Void, Never>?
    /// Bumped whenever the destination changes. A refresh carries the value it started
    /// with, and publishes nothing if it no longer matches.
    private var routeGeneration = 0
    /// The last route forecast and the road it was measured along, kept so distances
    /// can be re-measured as the driver moves without refetching anything.
    private var routeWeatherPoints: [RouteWeatherPoint] = []
    private var routePolyline: [GeoPoint] = []
    private let analysisInterval: TimeInterval = 5
    /// How often the live drive and its telemetry are written to disk.
    ///
    /// Twenty seconds: at 1 Hz sampling that is a bounded amount of work per write and
    /// at most twenty seconds of a drive at risk, against a SwiftData upsert of one row
    /// plus one small append-only file. Cheap enough to do while driving, frequent
    /// enough that losing the gap does not matter.
    private let checkpointInterval: TimeInterval = 20
    private let weatherInterval: TimeInterval = 15 * 60
    /// A failed route lookup is usually a tunnel or a dropped connection, which fixes
    /// itself. Waiting the full weather interval to find that out is too long.
    private let routeRetryInterval: TimeInterval = 60

    init(store: GarageStore,
         obd: OBDConnectionManager,
         location: LocationService,
         motion: MotionService,
         settings: AppSettings,
         weather: WeatherProviding,
         route: RouteProviding,
         telemetryStore: TelemetryWriting = TelemetryFileStore.shared) {
        self.store = store
        self.telemetryStore = telemetryStore
        self.obd = obd
        self.location = location
        self.motion = motion
        self.settings = settings
        self.weather = weather
        self.route = route
    }

    func setRouteProvider(_ provider: RouteProviding) {
        route = provider
        // Same reason `setWeatherProvider` clears its stamp. `AppEnvironment` swaps the
        // straight-line simulator provider for MapKit when an adapter connects, and
        // without this the simulated road's forecast stays up for fifteen minutes,
        // presented as though it came from a real one.
        nextRouteFetchAfter = nil
        routeWeatherTask?.cancel()
        routeWeatherTask = nil
        routeWeatherPoints = []
        routePolyline = []
        if destination != nil { scheduleRouteWeatherRefresh(force: true) }
    }

    // MARK: - Vehicle selection

    func select(vehicle: Vehicle?) {
        // Switching cars must not carry the previous car's learned state across.
        self.vehicle = vehicle
        self.profile = vehicle.flatMap { VehicleProfileCatalog.profile(id: $0.profileID) }
        gradientCalculator.reset()
        downsampler.reset()
        pendingSamples.removeAll()
        pendingBaselines.removeAll()
        insights.removeAll()
        baselines = [:]
        recorder = vehicle.map { makeRecorder(for: $0) }
        reloadBaselines()
        recoverInterruptedTrips()
        refreshAnalysis(force: true)
    }

    private func makeRecorder(for vehicle: Vehicle) -> TripRecorder {
        TripRecorder(vehicleID: vehicle.id,
                     tankCapacityLitres: vehicle.tankCapacityLitres(profile: profile),
                     profile: profile)
    }

    /// Closes any drive that was still open when the app was last terminated, using
    /// its last recorded point rather than pretending it continued.
    private func recoverInterruptedTrips() {
        guard let vehicle else { return }
        for open in store.openTrips(vehicleID: vehicle.id) {
            let lastActivity = open.routePolyline.last?.timestamp ?? open.startedAt
            if let recovered = TripRecovery.finalise(open, lastKnownActivityAt: lastActivity) {
                store.save(trip: recovered)
                // The drive's chunks outlived the process that was writing them.
                telemetryStore.finalise(vehicleID: vehicle.id, tripID: recovered.id, appending: [])
            } else {
                store.delete(tripID: open.id)
                telemetryStore.discardJournal(vehicleID: vehicle.id, tripID: open.id)
            }
        }
    }

    // MARK: - Drive loop

    func start() {
        guard driveLoop == nil else { return }
        // Idle regardless of the automatic-detection setting. This used to ask for
        // full driving accuracy when automatic detection was *off*, which is the
        // opposite of the intent: nothing is being recorded yet either way, and
        // setDriveScreenVisible and the recorder raise it when there is a reason to.
        location.start(fidelity: .idle)
        motion.start()
        driveLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stop() {
        driveLoop?.cancel()
        driveLoop = nil
        location.stop()
        motion.stop()
        flushPending()
    }

    /// Raises location fidelity while the driver is actually looking at Drive Mode.
    func setDriveScreenVisible(_ isVisible: Bool) {
        obd.isForeground = isVisible
        location.start(fidelity: isVisible ? .active : (isRecording ? .driving : .idle))
    }

    /// Drops the drive in progress without saving it.
    ///
    /// Distinct from ending it, which persists. Used when the data underneath is being
    /// deleted: ending would write the drive back out immediately after the deletion
    /// removed it, and a checkpoint firing mid-deletion would do the same.
    func abandonActiveDrive() {
        guard let trip = recorder?.currentTrip else {
            isRecording = false
            currentTrip = nil
            return
        }
        isRecording = false
        currentTrip = nil
        lastCheckpointAt = nil
        pendingSamples.removeAll()
        recorder = vehicle.map { makeRecorder(for: $0) }
        if let vehicle {
            telemetryStore.discardJournal(vehicleID: vehicle.id, tripID: trip.id)
        }
        LiveActivityController.shared.end()
    }

    /// What automatic drive detection is actually doing, permissions included.
    var automaticDetectionStatus: AutomaticDetectionStatus {
        AutomaticDetectionStatus.resolve(isEnabled: settings.automaticTripDetection,
                                         authorization: location.authorization,
                                         isReceivingUpdates: location.isMonitoring)
    }

    func startDriveManually() {
        guard var recorder = recorder else { return }
        handle(recorder.startManually(now: Date()), recorder: &recorder)
        self.recorder = recorder
    }

    func endDriveManually() {
        guard var recorder = recorder else { return }
        handle(recorder.endManually(now: Date()), recorder: &recorder)
        self.recorder = recorder
    }

    private func tick() async {
        guard var recorder = recorder else { return }
        let now = Date()
        let point = location.latest
        let telemetry = obd.isConnected ? obd.telemetry : nil

        // TripRecorder.noteAdapterConnectionChange existed with no callers, so a drive
        // recorded nothing about losing live data half way through - which is exactly
        // what explains a gap in its telemetry when the driver looks at it later.
        let adapterConnected = obd.isConnected
        if lastAdapterConnected != adapterConnected {
            if lastAdapterConnected != nil {
                recorder.noteAdapterConnectionChange(connected: adapterConnected, at: now)
                // The stream either just stopped or just resumed. Either way this is a
                // natural boundary and a cheap moment to get what we have onto disk,
                // rather than waiting out the rest of the interval.
                checkpoint(force: true, now: now)
            }
            lastAdapterConnected = adapterConnected
        }

        // Assigned every tick rather than observed: one assignment a second, and it
        // cannot drift out of step with the setting. The property's didSet no-ops
        // unless the value actually changed.
        motion.isImpactDetectionEnabled = settings.roadImpactDetectionEnabled

        let speedKmh = telemetry?.value(.vehicleSpeedKmh, freshWithin: 6, now: now)
            ?? point?.speedMetresPerSecond.map(Convert.kmh(fromMetresPerSecond:))
        motion.currentSpeedKmh = speedKmh

        // Offered, not applied. This used to re-anchor to GPS on every fix with vertical
        // accuracy under fifteen metres - once a second - which reduced the barometer to
        // a passthrough for ten metres of GPS noise. AltitudeFusion decides whether a
        // fix is worth anchoring to, nudging towards, or ignoring.
        motion.offerGPSAltitude(point?.altitudeMetres,
                                accuracyMetres: point?.verticalAccuracyMetres,
                                isStationary: (speedKmh ?? 0) < 3)

        if let point {
            gradientCalculator.add(point: point, altitude: motion.latestAltitude)
            motion.currentPoint = point
        }

        let outcome = settings.automaticTripDetection
            ? recorder.update(location: point, telemetry: telemetry, now: now)
            : recorder.update(location: point, telemetry: recorder.isRecording ? telemetry : nil, now: now)
        handle(outcome, recorder: &recorder)
        self.recorder = recorder

        if isRecording, let telemetry {
            collectTelemetry(telemetry, at: now)
        }
        collectRoadImpacts(into: &recorder)
        self.recorder = recorder
        checkpoint(now: now)
        gradient = gradientCalculator.current

        // How far ahead the weather is gets re-measured every tick; the forecast behind
        // it is only refetched every fifteen minutes. Cheap, and local. Done before
        // analysis so insights read the distance as it is now, not as it was when the
        // forecast was fetched.
        remeasureRouteWeather()

        if lastAnalysisAt == nil || now.timeIntervalSince(lastAnalysisAt!) >= analysisInterval {
            refreshAnalysis()
        }
        await refreshWeatherIfNeeded(at: point, now: now)
        // Started, not awaited. A route refresh is a directions call plus a forecast
        // call per waypoint; awaiting it here would stall the 1 Hz loop for as long as
        // a slow link takes to answer, and with it location sampling, trip start and
        // stop detection, and the gradient.
        scheduleRouteWeatherRefresh()
    }

    /// Persists impacts the motion service has detected and puts them on the drive.
    ///
    /// Only while recording: a jolt with the car parked is the phone being picked up,
    /// which is exactly the thing `RoadImpactEvent` refuses to call a pothole. Nothing
    /// is stored when the driver has the feature switched off.
    private func collectRoadImpacts(into recorder: inout TripRecorder) {
        guard settings.roadImpactDetectionEnabled, isRecording else { return }
        let fresh = motion.recentImpacts.filter { !consumedImpactIDs.contains($0.id) }
        guard !fresh.isEmpty else { return }

        for event in fresh.sorted(by: { $0.timestamp < $1.timestamp }) {
            consumedImpactIDs.insert(event.id)
            if let vehicleID = vehicle?.id {
                store.add(roadEvent: event, vehicleID: vehicleID)
            }
            recorder.add(event: event.asTripEvent())
        }

        // The buffer holds 50; keeping every ID forever would grow without bound on a
        // long drive, and an ID that has fallen out of the buffer cannot recur.
        let live = Set(motion.recentImpacts.map(\.id))
        consumedImpactIDs.formIntersection(live)
    }

    private func handle(_ outcome: TripRecorderOutcome, recorder: inout TripRecorder) {
        switch outcome {
        case .none:
            break
        case .started:
            isRecording = true
            downsampler.reset()
            pendingSamples.removeAll()
            gradientCalculator.reset()
            // The buffer can hold jolts from before the drive — a phone being picked
            // up and put in a cradle looks exactly like a bad road surface.
            motion.clearImpacts()
            consumedImpactIDs.removeAll()
            location.start(fidelity: .driving)
            currentTrip = recorder.currentTrip
            LiveActivityController.shared.start(trip: currentTrip,
                                                vehicleName: vehicle?.nickname ?? "Your vehicle",
                                                settings: settings)
            // Written straight from the local recorder rather than through
            // checkpoint(force:), which looks at `self.recorder` - and `self.recorder`
            // is not assigned the mutated value until after handle(_:recorder:) returns.
            // So checkpoint() here found no trip and silently did nothing, which is
            // exactly the bug this whole change exists to fix. Caught by the first
            // app-target test written against it.
            if let started = recorder.currentTrip {
                lastCheckpointAt = Date()
                store.save(trip: started)
            }
        case .updated:
            currentTrip = recorder.currentTrip
        case let .ended(trip):
            isRecording = false
            currentTrip = nil
            // Weather is captured with the drive rather than looked up later: what it
            // was like at the time is a fact, and a lookup next week is a guess.
            var finished = trip
            finished.weather = currentWeather.map { snapshot in
                TripWeatherSummary(temperatureC: snapshot.temperatureC,
                                   conditionDescription: snapshot.condition.displayName,
                                   precipitationIntensityMillimetresPerHour: snapshot.precipitationIntensityMillimetresPerHour,
                                   visibilityMetres: snapshot.visibilityMetres)
            }
            store.save(trip: finished)
            flushTelemetry(for: finished)
            lastCheckpointAt = nil
            updateOdometer(after: finished)
            motion.clearImpacts()
            consumedImpactIDs.removeAll()
            location.start(fidelity: .idle)
            LiveActivityController.shared.end()
            clearDestination()
            refreshAnalysis(force: true)
        case let .discarded(discardedID, _):
            isRecording = false
            currentTrip = nil
            lastCheckpointAt = nil
            // A checkpoint may already have persisted this drive. Left behind it would
            // be an incomplete row, which is exactly what recovery looks for, so the
            // next launch would "recover" a drive the recorder deliberately threw away.
            store.delete(tripID: discardedID)
            if let vehicle {
                telemetryStore.discardJournal(vehicleID: vehicle.id, tripID: discardedID)
            }
            pendingSamples.removeAll()
            motion.clearImpacts()
            consumedImpactIDs.removeAll()
            location.start(fidelity: .idle)
            LiveActivityController.shared.end()
            clearDestination()
        }
    }

    /// Adds the drive's distance to the odometer so maintenance intervals stay honest
    /// without the driver typing a number in every week.
    private func updateOdometer(after trip: Trip) {
        guard var vehicle = vehicle, let existing = vehicle.odometerKm else { return }
        vehicle.odometerKm = existing + trip.distanceKm
        vehicle.odometerUpdatedAt = trip.endedAt ?? Date()
        self.vehicle = vehicle
        store.update(vehicle: vehicle)
    }

    // MARK: - Telemetry and baselines

    /// A telemetry reading as a `Provenanced` value, or unavailable when it is missing,
    /// stale, or there is no adapter.
    ///
    /// The provenance is carried through rather than assumed, which is what keeps a
    /// simulated reading from arriving at the Hyperion screen looking measured.
    private func provenancedReading(_ metric: VehicleMetric,
                                    freshWithin seconds: TimeInterval,
                                    now: Date) -> Provenanced<Double> {
        guard obd.isConnected,
              let entry = obd.telemetry.entry(metric),
              now.timeIntervalSince(entry.timestamp) <= seconds else { return .unavailable() }
        return Provenanced(value: entry.value,
                           provenance: entry.provenance,
                           timestamp: entry.timestamp)
    }

    private func assessHyperion(profile: VehicleProfile?, now: Date) -> HyperionAssessment {
        guard obd.isConnected else {
            peakIntakeDeltaC = nil
            return .unavailable
        }

        let intake = provenancedReading(.intakeAirTemperatureC, freshWithin: 30, now: now)
        let ambient = obd.telemetry.value(.ambientAirTemperatureC, freshWithin: 300, now: now)
        if let intakeValue = intake.value, let ambient {
            peakIntakeDeltaC = HeatSoakAnalyser.updatedPeak(current: peakIntakeDeltaC,
                                                           delta: intakeValue - ambient)
        }

        return HyperionGuardian.assess(
            coolantC: provenancedReading(.coolantTemperatureC, freshWithin: 60, now: now),
            oilC: provenancedReading(.oilTemperatureC, freshWithin: 60, now: now),
            intakeC: intake,
            ambientC: ambient,
            speedKmh: obd.telemetry.value(.vehicleSpeedKmh, freshWithin: 6, now: now),
            idleSeconds: currentTrip?.idleDurationSeconds,
            runtimeSeconds: currentTrip.map { now.timeIntervalSince($0.startedAt) },
            peakIntakeDeltaC: peakIntakeDeltaC,
            // Warm-up history is not stored per drive yet; that is its own P1 item, and
            // passing an empty history simply means no comparison is offered rather than
            // a comparison being invented.
            warmUpHistory: [],
            intakeDeltaBaseline: baselines[BaselineKey(metric: .intakeAirTemperatureC, context: .any)],
            fuelSystem: obd.telemetry.value(.fuelSystemStatusCode, freshWithin: 30, now: now)
                .map { FuelSystemStatus.decode(code: $0) } ?? .unknown,
            monitorStatus: obd.telemetry.value(.monitorStatusCode, freshWithin: 120, now: now)
                .flatMap { MonitorStatus.decode(code: $0) },
            profile: profile)
    }

    private func collectTelemetry(_ telemetry: VehicleTelemetry, at now: Date) {
        if let sample = downsampler.consider(telemetry, at: now) {
            pendingSamples.append(sample)
        }

        // Simulated telemetry stops here. It may be journalled, shown live and used to
        // exercise the insight rules -- that is what the simulator is for -- but it must
        // never teach DriveLayer what is normal for a real Harrier. Nothing downstream
        // could tell the difference afterwards: aggregates are merged into the same store
        // by the same call, and a baseline learned from a scenario would quietly skew
        // every comparison made against the actual car.
        guard !telemetry.containsSimulatedData else { return }

        // Baseline observations are filed under the conditions they were taken in.
        let context = BaselineEngine.context(speedKmh: telemetry.value(.vehicleSpeedKmh, freshWithin: 6, now: now),
                                             engineLoadPercent: telemetry.value(.engineLoadPercent, freshWithin: 20, now: now),
                                             coolantTemperatureC: telemetry.value(.coolantTemperatureC, freshWithin: 60, now: now),
                                             gradientPercent: gradient?.percent,
                                             isEngineRunning: telemetry.isEngineRunning(now: now))
        for metric in [VehicleMetric.coolantTemperatureC, .controlModuleVoltageV, .engineLoadPercent, .fuelRateLitresPerHour] {
            guard let value = telemetry.value(metric, freshWithin: 60, now: now) else { continue }
            BaselineEngine.accumulate(into: &pendingBaselines,
                                      key: BaselineKey(metric: metric, context: context),
                                      value: value, at: now)
            BaselineEngine.accumulate(into: &pendingBaselines,
                                      key: BaselineKey(metric: metric, context: .any),
                                      value: value, at: now)
        }
    }

    /// Writes the live drive and its telemetry to disk.
    ///
    /// Drives used to be saved only at `.ended` and telemetry only flushed there too,
    /// so iOS terminating the app during a two-hour drive lost all of it. It also made
    /// `recoverInterruptedTrips()` unreachable: it looks for incomplete drives, and
    /// nothing ever wrote one.
    ///
    /// Called from the drive loop, on drive start, and from the scene phase changing -
    /// backgrounding is the last reliable moment before iOS may terminate the app.
    func checkpoint(force: Bool = false, now: Date = Date()) {
        guard isRecording, let trip = recorder?.currentTrip else { return }
        if !force, let last = lastCheckpointAt, now.timeIntervalSince(last) < checkpointInterval {
            return
        }
        lastCheckpointAt = now
        store.save(trip: trip)
        guard let vehicle, !pendingSamples.isEmpty else { return }
        // Cleared only once the samples are actually on disk. The buffer used to be
        // emptied on the line after a fire-and-forget `queue.async`, which meant a failed
        // write -- or termination before the queued block ran -- lost them silently.
        guard telemetryStore.appendChunk(samples: pendingSamples,
                                         vehicleID: vehicle.id,
                                         tripID: trip.id) else {
            telemetryWriteFailures += 1
            capPendingSamples()
            return
        }
        telemetryWriteFailures = 0
        pendingSamples.removeAll()
    }

    /// Drops the oldest retained samples once the buffer passes its cap.
    ///
    /// Reached only when writes keep failing, where the choice is between losing the
    /// oldest telemetry and growing until the app is killed for it. Counted rather than
    /// silent, so the Debug Center can say it happened.
    private func capPendingSamples() {
        let excess = pendingSamples.count - Self.maximumPendingSamples
        guard excess > 0 else { return }
        pendingSamples.removeFirst(excess)
        droppedTelemetrySamples += excess
    }

    /// Compacts a finished drive's chunks into its single file.
    private func flushTelemetry(for trip: Trip) {
        guard let vehicle else { return }
        if telemetryStore.finalise(vehicleID: vehicle.id,
                                   tripID: trip.id,
                                   appending: pendingSamples) {
            pendingSamples.removeAll()
        } else {
            // Kept for the next attempt. A drive whose compaction failed is still
            // recoverable from its chunks at the next launch.
            telemetryWriteFailures += 1
            capPendingSamples()
        }
        flushPending()
        reloadBaselines()
    }

    private func flushPending() {
        guard let vehicle, !pendingBaselines.isEmpty else { return }
        store.merge(aggregates: pendingBaselines, vehicleID: vehicle.id)
        pendingBaselines.removeAll()
    }

    private func reloadBaselines() {
        guard let vehicle else { return }
        let aggregates = store.baselineAggregates(vehicleID: vehicle.id)
        baselines = BaselineEngine.buildAll(from: aggregates, now: Date())
    }

    // MARK: - Analysis

    func refreshAnalysis(force: Bool = false) {
        guard let vehicle else {
            health = nil
            insights = []
            return
        }
        let now = Date()
        lastAnalysisAt = now

        let recentTrips = store.trips(vehicleID: vehicle.id, limit: 60)
        let maintenance = MaintenanceEngine.statuses(for: store.maintenanceItems(vehicleID: vehicle.id),
                                                     currentOdometerKm: vehicle.odometerKm,
                                                     now: now)
        let economy = FuelIntelligence.bestEconomy(fuelEntries: store.fuelEntries(vehicleID: vehicle.id),
                                                   recentTrips: recentTrips)
        let levelPercent: Provenanced<Double> = obd.telemetry.value(.fuelLevelPercent, freshWithin: 900, now: now)
            .map { Provenanced.measured($0, at: now) } ?? .unavailable(basis: obd.isConnected
                                                                       ? "This vehicle doesn't report tank level."
                                                                       : "Connect an adapter to read the tank level.")
        fuelStatus = FuelIntelligence.status(levelPercent: levelPercent,
                                             tankCapacityLitres: vehicle.tankCapacityLitres(profile: profile),
                                             economy: economy)
        dieselAssessment = DieselGuardian.assess(trips: recentTrips, profile: profile, now: now)
        hyperion = assessHyperion(profile: profile, now: now)

        let context = InsightContext(now: now,
                                     vehicle: vehicle,
                                     profile: profile,
                                     isAdapterConnected: obd.isConnected,
                                     telemetry: obd.isConnected ? obd.telemetry : nil,
                                     capabilities: obd.capabilities,
                                     currentTrip: currentTrip,
                                     recentTrips: recentTrips,
                                     baselines: baselines,
                                     gradient: gradient,
                                     terrainFeature: terrainFeature,
                                     currentWeather: currentWeather,
                                     weatherChanges: weatherChanges,
                                     troubleCodes: obd.troubleCodes,
                                     maintenanceStatuses: maintenance,
                                     documents: store.documents(vehicleID: vehicle.id),
                                     fuelStatus: fuelStatus,
                                     dieselAssessment: dieselAssessment,
                                     isDriving: isRecording)

        health = VehicleHealthEvaluator.evaluate(context)
        insights = insightEngine.evaluate(context, existing: force ? [] : insights)
        WidgetSnapshotPublisher.publish(vehicle: vehicle,
                                        health: health,
                                        fuel: fuelStatus,
                                        nextService: maintenance.first { $0.status != .unknown },
                                        lastTrip: recentTrips.first(where: \.isComplete),
                                        headline: InsightEngine.headline(insights),
                                        isAdapterConnected: obd.isConnected)
        LiveActivityController.shared.update(trip: currentTrip,
                                             insight: InsightEngine.headline(insights),
                                             health: health?.overall,
                                             estimatedRangeKm: fuelStatus.estimatedRangeKm.value,
                                             settings: settings)

        // Rescheduling is idempotent, so running it on every analysis pass keeps
        // reminders in step with edits without ever duplicating one.
        let documents = store.documents(vehicleID: vehicle.id)
        let remindersEnabled = settings.remindersEnabled
        Task { [weak reminders] in
            await reminders?.reschedule(documents: documents,
                                        maintenance: maintenance,
                                        isEnabled: remindersEnabled)
        }
    }

    /// Builds the copilot's snapshot from the same context the insights came from.
    func copilotSnapshot() -> VehicleContextSnapshot {
        guard let vehicle else {
            return VehicleContextSnapshot(generatedAt: Date())
        }
        let context = InsightContext(now: Date(),
                                     vehicle: vehicle,
                                     profile: profile,
                                     isAdapterConnected: obd.isConnected,
                                     telemetry: obd.isConnected ? obd.telemetry : nil,
                                     capabilities: obd.capabilities,
                                     currentTrip: currentTrip,
                                     recentTrips: store.trips(vehicleID: vehicle.id, limit: 90),
                                     baselines: baselines,
                                     gradient: gradient,
                                     terrainFeature: terrainFeature,
                                     currentWeather: currentWeather,
                                     weatherChanges: weatherChanges,
                                     troubleCodes: obd.troubleCodes,
                                     maintenanceStatuses: MaintenanceEngine.statuses(
                                        for: store.maintenanceItems(vehicleID: vehicle.id),
                                        currentOdometerKm: vehicle.odometerKm,
                                        now: Date()),
                                     documents: store.documents(vehicleID: vehicle.id),
                                     fuelStatus: fuelStatus,
                                     dieselAssessment: dieselAssessment,
                                     isDriving: isRecording)
        return CopilotContextBuilder.build(from: context, health: health, insights: insights)
    }

    // MARK: - Weather

    func setWeatherProvider(_ provider: WeatherProviding) {
        weather = provider
        lastWeatherFetch = nil
    }

    private func refreshWeatherIfNeeded(at point: GeoPoint?, now: Date) async {
        guard let point else { return }
        guard weather.isConfigured else {
            weatherUnavailability = .weatherServiceUnconfigured
            return
        }
        if let last = lastWeatherFetch, now.timeIntervalSince(last) < weatherInterval { return }
        lastWeatherFetch = now
        do {
            currentWeather = try await weather.currentWeather(at: point)
            weatherUnavailability = nil
        } catch let error as WeatherError {
            weatherUnavailability = error == .offline ? .offline : .weatherServiceUnconfigured
        } catch {
            weatherUnavailability = .offline
        }
    }

    /// Applies a route forecast. Called by the Drive screen once a destination or a
    /// polyline is known; without one there is no "ahead" to forecast for.
    ///
    /// The polyline is kept alongside the points so `remeasureRouteWeather` can work
    /// out how much of it the driver has already covered.
    func applyRouteWeather(_ points: [RouteWeatherPoint], polyline: [GeoPoint] = []) {
        routeWeatherPoints = points
        routePolyline = polyline
        weatherChanges = RouteWeatherAnalyser.changes(current: currentWeather, along: points)
        refreshAnalysis()
    }

    // MARK: - Destination and route weather

    /// Sets where the driver is going, and forecasts the road there.
    ///
    /// Clearing it drops the route forecast rather than leaving yesterday's rain on
    /// screen: weather "ahead" of a destination that no longer applies is worse than
    /// no forecast at all. Changing it does the same, for the same reason - the new
    /// road may run the opposite way.
    func setDestination(_ destination: RouteDestination?) {
        // Whatever is in flight was fetched for the previous destination. The bump
        // makes its result unpublishable; the cancel stops it doing the remaining work.
        routeGeneration += 1
        routeWeatherTask?.cancel()
        routeWeatherTask = nil
        nextRouteFetchAfter = nil

        self.destination = destination
        routeUnavailability = nil
        // `weatherChanges` feeds insights, CarPlay and Today as well as this screen, so
        // a stale entry here is a stale warning in four places.
        weatherChanges = []
        routeWeatherPoints = []
        routePolyline = []
        refreshAnalysis()

        guard destination != nil else { return }
        scheduleRouteWeatherRefresh(force: true)
    }

    /// Drops the destination when the drive it was set for is over.
    ///
    /// PRIVACY.md promises the destination lives no longer than the drive. Without this
    /// the app keeps asking Apple for a route and a forecast every fifteen minutes, for
    /// a destination the driver arrived at an hour ago, until the app is killed.
    private func clearDestination() {
        guard destination != nil else { return }
        setDestination(nil)
    }

    /// Starts a refresh without blocking the caller, one at a time.
    ///
    /// Two refreshes in flight together would race, and the one that finishes last wins
    /// regardless of which is newer or which destination it was for.
    private func scheduleRouteWeatherRefresh(force: Bool = false) {
        guard destination != nil else { return }
        if force {
            routeWeatherTask?.cancel()
        } else {
            guard routeWeatherTask == nil else { return }
            // Checked here as well as inside, so the loop is not spawning a task per
            // second only for it to return immediately.
            if let next = nextRouteFetchAfter, Date() < next { return }
        }

        let generation = routeGeneration
        routeWeatherTask = Task { [weak self] in
            await self?.refreshRouteWeather(force: force)
            guard let self, generation == self.routeGeneration else { return }
            self.routeWeatherTask = nil
        }
    }

    /// Re-measures how far ahead the route forecast is, without refetching it.
    ///
    /// At 100 km/h a driver covers 25 km between refreshes. Re-measuring is what stops
    /// "rain about 20 km ahead" being shown after they have driven through it.
    private func remeasureRouteWeather() {
        guard !routeWeatherPoints.isEmpty,
              !routePolyline.isEmpty,
              let position = location.latest else { return }
        let remaining = RouteWeatherAnalyser.remeasured(routeWeatherPoints,
                                                       along: routePolyline,
                                                       from: position)
        weatherChanges = RouteWeatherAnalyser.changes(current: currentWeather, along: remaining)
    }

    /// What a refresh concluded, before any of it is published.
    private enum RouteWeatherOutcome {
        case forecast(points: [RouteWeatherPoint], polyline: [GeoPoint])
        case unavailable(UnavailabilityReason)
    }

    /// Fetches the forecast at points spaced along the road to the destination.
    ///
    /// Runs at the weather interval rather than the drive loop's 1 Hz: a route forecast
    /// that changed every second would be noise, and each refresh is several network
    /// calls. The outcome is computed in full before anything is assigned, so a refresh
    /// for a destination the driver has since changed is dropped whole rather than
    /// half-applied on top of the new one.
    func refreshRouteWeather(force: Bool = false) async {
        guard destination != nil else { return }
        let now = Date()
        if !force, let next = nextRouteFetchAfter, now < next { return }
        let generation = routeGeneration

        let outcome = await routeWeatherOutcome(now: now)

        // The driver changed or cleared the destination while this was in flight.
        guard generation == routeGeneration else { return }

        switch outcome {
        case let .forecast(points, polyline):
            routeUnavailability = points.isEmpty ? .offline : nil
            applyRouteWeather(points, polyline: polyline)
            nextRouteFetchAfter = now.addingTimeInterval(weatherInterval)
        case let .unavailable(reason):
            routeUnavailability = reason
            // No forecast means no forecast - not the last one that happened to work.
            routeWeatherPoints = []
            routePolyline = []
            weatherChanges = []
            refreshAnalysis()
            nextRouteFetchAfter = now.addingTimeInterval(
                Self.isTransient(reason) ? routeRetryInterval : weatherInterval)
        }
    }

    /// Whether a failure is worth retrying soon.
    ///
    /// A dropped connection or a missing fix clears by itself. An unconfigured weather
    /// service, or a destination with no road to it, will not change until the driver
    /// does something, so those wait for the normal interval.
    private static func isTransient(_ reason: UnavailabilityReason) -> Bool {
        switch reason {
        case .offline, .waitingForLocationFix: return true
        default: return false
        }
    }

    private func routeWeatherOutcome(now: Date) async -> RouteWeatherOutcome {
        guard let destination else { return .unavailable(.noDestination) }
        guard weather.isConfigured else { return .unavailable(.weatherServiceUnconfigured) }
        guard route.isAvailable else { return .unavailable(.routeUnavailable) }
        // Without a fix there is no origin to route from. Naming which of the three
        // reasons it is beats what this used to do: return silently, leaving the row
        // populated and the forecast permanently, unexplainedly empty.
        guard let origin = location.latest else {
            return .unavailable(location.authorization.unavailabilityReason ?? .waitingForLocationFix)
        }

        do {
            let polyline = try await route.polyline(from: origin, to: destination.point)
            // The driver's own recent average, not a speed limit: how fast they will
            // actually be at a point decides when they arrive there.
            let speed = averageSpeedForRouteKmh()
            let waypoints = RouteWeatherAnalyser.waypoints(along: polyline,
                                                           from: now,
                                                           averageSpeedKmh: speed)
            guard !waypoints.isEmpty else { return .unavailable(.routeTooShortForForecast) }

            var points: [RouteWeatherPoint] = []
            for waypoint in waypoints {
                let hours = max(1, Int(waypoint.expectedAt.timeIntervalSince(now) / 3_600) + 1)
                let forecast = try await weather.hourlyForecast(at: waypoint.point, hours: hours)
                // The hour the driver is expected there, not the nearest hour to now.
                guard let snapshot = forecast.min(by: {
                    abs($0.timestamp.timeIntervalSince(waypoint.expectedAt))
                        < abs($1.timestamp.timeIntervalSince(waypoint.expectedAt))
                }) else { continue }
                points.append(RouteWeatherPoint(distanceMetres: waypoint.distanceMetres,
                                                expectedAt: waypoint.expectedAt,
                                                snapshot: snapshot))
            }
            return .forecast(points: points, polyline: polyline)
        } catch let error as WeatherError {
            return .unavailable(error == .offline ? .offline : .weatherServiceUnconfigured)
        } catch RouteError.noRouteFound {
            return .unavailable(.routeUnavailable)
        } catch {
            return .unavailable(.offline)
        }
    }

    /// The speed used to work out when the driver reaches each waypoint.
    ///
    /// Prefers what the car is doing now, falls back to this drive's average, and
    /// finally to a conservative figure. Never a guess dressed as a measurement — it
    /// only decides which forecast hour to read.
    private func averageSpeedForRouteKmh() -> Double {
        if let live = obd.telemetry.value(.vehicleSpeedKmh, freshWithin: 30, now: Date()), live > 15 {
            return live
        }
        if let trip = currentTrip, let average = trip.averageSpeedKmh, average > 15 {
            return average
        }
        return 45
    }

    /// Applies an elevation profile for the road ahead.
    func applyElevationProfile(_ profile: [ElevationPoint]) {
        terrainFeature = TerrainAnalyser.mostRelevantFeature(in: profile)
        refreshAnalysis()
    }
}
