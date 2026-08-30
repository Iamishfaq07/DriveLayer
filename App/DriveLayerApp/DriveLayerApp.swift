import SwiftUI
import SwiftData

@main
struct DriveLayerApp: App {

    @State private var environment: AppEnvironment
    @Environment(\.scenePhase) private var scenePhase
    private let container: ModelContainer

    init() {
        let container = DriveLayerApp.makeContainer()
        self.container = container
        _environment = State(initialValue: AppEnvironment(container: container))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                .modelContainer(container)
                .tint(DLColor.accent)
                .task {
                    await environment.bootstrap()
                    environment.applyRetentionPolicy()
                    // After bootstrap, so the drives the database knows about have been
                    // loaded and recovered before anything on disk is judged an orphan.
                    environment.reconcileTelemetryJournals()
                }
                .onChange(of: scenePhase) { _, phase in
                    // Backgrounding is the last reliable moment before iOS may
                    // terminate the app, so the live drive is written out here rather
                    // than waiting for the next interval to come round.
                    if phase != .active { environment.drive.checkpoint(force: true) }
                }
        }
    }

    /// Builds the store. A failure here is not recoverable by the app, but it is
    /// recoverable by the driver, so it fails loudly rather than silently starting
    /// with an in-memory store that quietly loses their history.
    private static func makeContainer() -> ModelContainer {
        let schema = Schema(DriveLayerSchema.models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("DriveLayer could not open its database: \(error.localizedDescription)")
        }
    }
}
