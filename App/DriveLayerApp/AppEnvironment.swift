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

    init(container: ModelContainer, settings: AppSettings = AppSettings()) {
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
                                             weather: AppEnvironment.makeWeatherProvider(settings: settings))
        self.drive.reminders = reminders
        AppEnvironment.active = self
    }

    /// The mock provider is only ever used when the driver has explicitly switched on
    /// simulation, and the Debug Center labels it as mocked wherever it appears.
    private static func makeWeatherProvider(settings: AppSettings) -> WeatherProviding {
        settings.useSimulator ? MockWeatherProvider(scenario: .rainAhead) : WeatherKitProvider()
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

    func deleteSelectedVehicle() {
        guard let id = selectedVehicleID else { return }
        store.delete(vehicleID: id)
        selectedVehicleID = nil
        reloadVehicles()
    }

    /// Connects to whatever the driver last used: the simulator when it is switched
    /// on, otherwise a remembered adapter. Never scans unprompted.
    func connectIfPossible() async {
        if settings.useSimulator {
            await obd.connect(source: .simulator(settings.simulatorScenario))
            drive.setWeatherProvider(MockWeatherProvider(scenario: .rainAhead))
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
        await obd.connect(source: .bluetooth(peripheralID: id, name: name))
        rememberConnectedAdapter()
    }

    func useSimulator(scenario: OBDScenarioID) async {
        settings.useSimulator = true
        settings.simulatorScenario = scenario
        drive.setWeatherProvider(MockWeatherProvider(scenario: .rainAhead))
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

    /// Applies the driver's retention choice. Called at launch and when it changes.
    func applyRetentionPolicy() {
        let days = settings.telemetryRetentionDays
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) else { return }
        store.pruneBaselines(olderThan: cutoff)
    }
}
