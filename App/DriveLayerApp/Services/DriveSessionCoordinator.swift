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
    private(set) var gradient: GradientEstimate?
    private(set) var terrainFeature: TerrainFeature?
    private(set) var currentWeather: WeatherSnapshot?
    private(set) var weatherChanges: [WeatherChange] = []
    private(set) var weatherUnavailability: UnavailabilityReason?
    private(set) var isRecording = false
    private(set) var lastAnalysisAt: Date?

    var vehicle: Vehicle?
    var profile: VehicleProfile?

    private let store: GarageStore
    private let obd: OBDConnectionManager
    private let location: LocationService
    private let motion: MotionService
    private let settings: AppSettings
    private var weather: WeatherProviding
    /// Set by `AppEnvironment` after construction; reminders are a side effect of
    /// analysis rather than something the coordinator needs to own.
    weak var reminders: ReminderScheduler?

    private var recorder: TripRecorder?
    private var gradientCalculator = GradientCalculator()
    private let insightEngine = InsightEngine()
    private var downsampler = TelemetryDownsampler()
    private var pendingSamples: [TelemetrySample] = []
    private var pendingBaselines: [BaselineDailyAggregate] = []
    private var baselines: [BaselineKey: MetricBaseline] = [:]

    /// Impacts already taken from `MotionService`, so the same jolt is not recorded
    /// twice as the loop re-reads its rolling buffer.
    private var consumedImpactIDs: Set<UUID> = []

    private var driveLoop: Task<Void, Never>?
    private var lastWeatherFetch: Date?
    private let analysisInterval: TimeInterval = 5
    private let weatherInterval: TimeInterval = 15 * 60

    init(store: GarageStore,
         obd: OBDConnectionManager,
         location: LocationService,
         motion: MotionService,
         settings: AppSettings,
         weather: WeatherProviding) {
        self.store = store
        self.obd = obd
        self.location = location
        self.motion = motion
        self.settings = settings
        self.weather = weather
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
            } else {
                store.delete(tripID: open.id)
            }
        }
    }

    // MARK: - Drive loop

    func start() {
        guard driveLoop == nil else { return }
        location.start(fidelity: settings.automaticTripDetection ? .idle : .driving)
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

        // Give the barometer an absolute reference the first time GPS altitude is good.
        if let point, let altitude = point.altitudeMetres, (point.verticalAccuracyMetres ?? 99) < 15 {
            motion.anchorAltitude(toGPS: altitude)
        }
        if let point {
            gradientCalculator.add(point: point, altitude: motion.latestAltitude)
            motion.currentPoint = point
        }
        motion.currentSpeedKmh = telemetry?.value(.vehicleSpeedKmh, freshWithin: 6, now: now)
            ?? point?.speedMetresPerSecond.map(Convert.kmh(fromMetresPerSecond:))

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
        gradient = gradientCalculator.current

        if lastAnalysisAt == nil || now.timeIntervalSince(lastAnalysisAt!) >= analysisInterval {
            refreshAnalysis()
        }
        await refreshWeatherIfNeeded(at: point, now: now)
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
            updateOdometer(after: finished)
            motion.clearImpacts()
            consumedImpactIDs.removeAll()
            location.start(fidelity: .idle)
            LiveActivityController.shared.end()
            refreshAnalysis(force: true)
        case .discarded:
            isRecording = false
            currentTrip = nil
            pendingSamples.removeAll()
            motion.clearImpacts()
            consumedImpactIDs.removeAll()
            location.start(fidelity: .idle)
            LiveActivityController.shared.end()
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

    private func collectTelemetry(_ telemetry: VehicleTelemetry, at now: Date) {
        if let sample = downsampler.consider(telemetry, at: now) {
            pendingSamples.append(sample)
        }

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

    private func flushTelemetry(for trip: Trip) {
        guard let vehicle, !pendingSamples.isEmpty else { return }
        TelemetryFileStore.shared.write(samples: pendingSamples, vehicleID: vehicle.id, tripID: trip.id)
        pendingSamples.removeAll()
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
    func applyRouteWeather(_ points: [RouteWeatherPoint]) {
        weatherChanges = RouteWeatherAnalyser.changes(current: currentWeather, along: points)
        refreshAnalysis()
    }

    /// Applies an elevation profile for the road ahead.
    func applyElevationProfile(_ profile: [ElevationPoint]) {
        terrainFeature = TerrainAnalyser.mostRelevantFeature(in: profile)
        refreshAnalysis()
    }
}
