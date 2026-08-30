import Foundation
import SwiftData
import SwiftUI

/// The app's object graph, assembled once.
///
/// Constructed explicitly rather than resolved from a container: there are eight
/// objects, their dependencies are a straight line, and being able to read the whole
/// wiring in one screen is worth more than a dependency framework.
@MainActor
@Observable
final class AppEnvironment {

    let settings: AppSettings
    let store: GarageStore
    let obd: OBDConnectionManager
    let location: LocationService
    let motion: MotionService
    let drive: DriveSessionCoordinator
    let scanner: BluetoothAdapterScanner
    let reminders: ReminderScheduler

    private(set) var vehicles: [Vehicle] = []
    private(set) var selectedVehicleID: UUID?

    /// The running instance.
    ///
    /// CarPlay and App Intents arrive on their own scenes with no way to be handed a
    /// reference, so the app records itself here at construction. Nothing else uses it.
    private(set) static var active: AppEnvironment?

    /// `settings` is optional rather than defaulted because a default argument is
    /// evaluated in a nonisolated context, and `AppSettings` is main-actor isolated.
    init(container: ModelContainer, settings: AppSettings? = nil) {
        let settings = settings ?? AppSettings()
        self.settings = settings
        self.store = GarageStore(context: ModelContext(container))
        self.obd = OBDConnectionManager()
        self.location = LocationService()
        self.motion = MotionService()
        self.scanner = BluetoothAdapterScanner()
        self.reminders = ReminderScheduler()
        self.drive = DriveSessionCoordinator(store: store,
                                             obd: obd,
                                             location: location,
                                             motion: motion,
                                             settings: settings,
                                             weather: AppEnvironment.makeWeatherProvider(settings: settings),
                                             route: AppEnvironment.makeRouteProvider(settings: settings))
        self.drive.reminders = reminders
        AppEnvironment.active = self
    }

    /// The mock provider is only ever used when the driver has explicitly switched on
    /// simulation, and the Debug Center labels it as mocked wherever it appears.
    private static func makeWeatherProvider(settings: AppSettings) -> WeatherProviding {
        settings.useSimulator ? MockWeatherProvider(scenario: .rainAhead) : WeatherKitProvider()
    }

    /// Under simulation a straight line stands in for a road, so the route-weather
    /// pipeline can be exercised without MapKit. It is never offered to a driver as
    /// though it were real routing — `StraightLineRouteProvider` says as much.
    private static func makeRouteProvider(settings: AppSettings) -> RouteProviding {
        settings.useSimulator ? StraightLineRouteProvider() : MapKitRouteProvider()
    }

    var selectedVehicle: Vehicle? {
        vehicles.first { $0.id == selectedVehicleID } ?? vehicles.first
    }

    var profile: VehicleProfile? {
        selectedVehicle.flatMap { VehicleProfileCatalog.profile(id: $0.profileID) }
    }

    var formatter: DisplayFormatter { settings.formatter }

    func bootstrap() async {
        reloadVehicles()
        drive.start()
        await reminders.refreshAuthorisation()
        await connectIfPossible()
    }

    func reloadVehicles() {
        vehicles = store.vehicles()
        if selectedVehicleID == nil || !vehicles.contains(where: { $0.id == selectedVehicleID }) {
            selectedVehicleID = store.primaryVehicle()?.id
        }
        drive.select(vehicle: selectedVehicle)
    }

    func select(vehicleID: UUID) {
        selectedVehicleID = vehicleID
        store.setPrimaryVehicle(id: vehicleID)
        reloadVehicles()
        Task { await obd.reconnect() }
    }

    func add(vehicle: Vehicle) {
        store.add(vehicle: vehicle)
        reloadVehicles()
        selectedVehicleID = vehicle.id
        drive.select(vehicle: vehicle)
    }

    /// Deletes the selected vehicle and everything that pointed at it.
    ///
    /// Goes through `PrivacyDeletion` rather than straight to the store: the scanned
    /// documents, the reminders about them and the widget content all belong to the
    /// vehicle too, and deleting the rows alone left all three behind.
    func deleteSelectedVehicle() {
        guard let id = selectedVehicleID else { return }
        Task { await PrivacyDeletion.delete(vehicleID: id, in: self) }
    }

    /// Connects to whatever the driver last used: the simulator when it is switched
    /// on, otherwise a remembered adapter. Never scans unprompted.
    func connectIfPossible() async {
        if settings.useSimulator {
            await obd.connect(source: .simulator(settings.simulatorScenario))
            drive.setWeatherProvider(MockWeatherProvider(scenario: .rainAhead))
            drive.setRouteProvider(StraightLineRouteProvider())
            return
        }
        guard let identifier = settings.lastAdapterIdentifier, let uuid = UUID(uuidString: identifier) else { return }
        await obd.connect(source: .bluetooth(peripheralID: uuid, name: settings.lastAdapterName ?? "OBD adapter"))
        rememberConnectedAdapter()
    }

    func connect(toAdapter id: UUID, name: String) async {
        settings.useSimulator = false
        settings.lastAdapterIdentifier = id.uuidString
        settings.lastAdapterName = name
        drive.setWeatherProvider(WeatherKitProvider())
        drive.setRouteProvider(MapKitRouteProvider())
        await obd.connect(source: .bluetooth(peripheralID: id, name: name))
        rememberConnectedAdapter()
    }

    func useSimulator(scenario: OBDScenarioID) async {
        settings.useSimulator = true
        settings.simulatorScenario = scenario
        drive.setWeatherProvider(MockWeatherProvider(scenario: .rainAhead))
        drive.setRouteProvider(StraightLineRouteProvider())
        await obd.connect(source: .simulator(scenario))
    }

    func disconnectAdapter() async {
        await obd.disconnect()
    }

    private func rememberConnectedAdapter() {
        guard obd.isConnected,
              case let .bluetooth(peripheralID, name)? = obd.source,
              let peripheralID else { return }
        store.remember(deviceIdentifier: peripheralID.uuidString,
                       name: name,
                       adapter: obd.adapterIdentity,
                       protocolDescription: obd.protocolDescription)
    }

    /// Applies the driver's retention choice to **raw telemetry**.
    ///
    /// This used to call `pruneBaselines` instead, which was backwards in both
    /// directions at once: choosing a shorter window destroyed the learned baselines -
    /// the lightweight intelligence model, months in the making - while every raw
    /// telemetry file stayed on disk untouched.
    ///
    /// Baselines are now kept for as long as the vehicle exists. They are small, they
    /// are the product, and they are only discarded when the driver explicitly asks via
    /// `resetLearnedBaselines()`.
    func applyRetentionPolicy() {
        let days = settings.telemetryRetentionDays
        guard days > 0 else { return }   // 0 means keep everything
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) else { return }
        TelemetryFileStore.shared.deleteCompacted(olderThan: cutoff)
    }

    /// Discards what DriveLayer has learned about the car, on request.
    ///
    /// Separate from telemetry retention on purpose: a driver clearing disk space should
    /// not silently lose the baselines, and a driver who wants the car re-learned - after
    /// a repair, say - should not have to delete their history to get it.
    func resetLearnedBaselines() {
        guard let id = selectedVehicleID else { return }
        store.deleteBaselines(vehicleID: id)
        drive.select(vehicle: selectedVehicle)
    }

    /// Puts the app back to its just-installed state after a deletion.
    ///
    /// `PrivacyDeletion` owns the order; this is only the in-memory part.
    func resetAfterDeletion(reload: Bool = true) {
        selectedVehicleID = nil
        if reload {
            reloadVehicles()
        } else {
            vehicles = []
            drive.select(vehicle: nil)
        }
    }
}
