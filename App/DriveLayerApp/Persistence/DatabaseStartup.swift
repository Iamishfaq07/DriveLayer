import Foundation
import SwiftData

/// A failed open never creates an empty fallback store and never removes store files.
@MainActor
@Observable
final class DatabaseStartup {
    private(set) var container: ModelContainer?
    private(set) var failure: String?
    private let open: () throws -> ModelContainer

    init(open: @escaping () throws -> ModelContainer = {
        let schema = Schema(DriveLayerSchema.models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        return try ModelContainer(for: schema, configurations: [configuration])
    }) {
        self.open = open
    }

    func retry() {
        guard container == nil else { return }
        do {
            container = try open()
            failure = nil
        } catch {
            let detail = error as NSError
            failure = "DriveLayer could not open its saved data.\n\(detail.domain) (\(detail.code)): \(detail.localizedDescription)"
        }
    }
}
