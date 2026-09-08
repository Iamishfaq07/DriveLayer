import SwiftUI
import SwiftData

@main
struct DriveLayerApp: App {

    @State private var environment: AppEnvironment?
    @State private var startup = DatabaseStartup()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let startup = DatabaseStartup()
        startup.retry()
        _startup = State(initialValue: startup)
        _environment = State(initialValue: startup.container.map { AppEnvironment(container: $0) })
    }

    var body: some Scene {
        WindowGroup {
            Group {
            if let environment, let container = startup.container {
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
            } else {
                ContentUnavailableView {
                    Label("Saved data needs attention", systemImage: "externaldrive.badge.exclamationmark")
                } description: {
                    Text("DriveLayer could not open your history. Your saved files have not been deleted or replaced. Unlock your iPhone and try again. Keep the app installed to preserve your data.")
                } actions: {
                    Button("Try again") { openStore() }
                        .buttonStyle(.borderedProminent)
                    if let failure = startup.failure {
                        ShareLink("Share diagnostic details", item: failure)
                    }
                }
            }
            }
            .task { if environment == nil { openStore() } }
        }
    }

    private func openStore() {
        startup.retry()
        if let container = startup.container, environment == nil {
            environment = AppEnvironment(container: container)
        }
    }
}
