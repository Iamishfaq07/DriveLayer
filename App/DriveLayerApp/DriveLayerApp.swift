import SwiftUI
import SwiftData

@main
struct DriveLayerApp: App {

    @State private var environment: AppEnvironment
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
