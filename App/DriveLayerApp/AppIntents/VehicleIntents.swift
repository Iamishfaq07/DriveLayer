import Foundation
import AppIntents

/// Siri and Shortcuts.
///
/// Both intents answer from the snapshot the app has already published, so they work
/// without launching the UI and cannot produce a number the app itself would not
/// show. Where something is unknown they say so rather than returning zero.
struct VehicleStatusIntent: AppIntent {

    static var title: LocalizedStringResource = "Check my vehicle"
    static var description = IntentDescription("Reports how your vehicle is doing, its estimated range, and anything worth knowing.")
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let snapshot = WidgetSnapshotStore.read() else {
            return .result(dialog: "DriveLayer doesn't have anything recorded yet. Open the app and add your vehicle.")
        }

        var parts: [String] = ["\(snapshot.vehicleName) is \(snapshot.healthHeadline.lowercased())."]
        if let range = snapshot.estimatedRangeKm {
            parts.append("You have roughly \(Int(range.rounded())) kilometres of estimated range.")
        }
        if let insight = snapshot.headlineInsightSummary {
            parts.append(insight)
        }
        if !snapshot.isAdapterConnected {
            parts.append("No adapter is connected, so this is based on your phone and history only.")
        }
        return .result(dialog: IntentDialog(stringLiteral: parts.joined(separator: " ")))
    }
}

struct NextServiceIntent: AppIntent {

    static var title: LocalizedStringResource = "When is my service due"
    static var description = IntentDescription("Reports the next maintenance item due, by distance or date.")
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let snapshot = WidgetSnapshotStore.read() else {
            return .result(dialog: "DriveLayer doesn't have anything recorded yet.")
        }
        guard let name = snapshot.nextServiceName, let summary = snapshot.nextServiceSummary else {
            return .result(dialog: "Nothing is being tracked yet. Add your last service in DriveLayer and it'll work out what's due.")
        }
        return .result(dialog: IntentDialog(stringLiteral: "\(name). \(summary)"))
    }
}

struct LastDriveIntent: AppIntent {

    static var title: LocalizedStringResource = "How was my last drive"
    static var description = IntentDescription("Reports the distance, duration and economy of your most recent drive.")
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let snapshot = WidgetSnapshotStore.read(), let distance = snapshot.lastTripDistanceKm else {
            return .result(dialog: "DriveLayer hasn't recorded a drive yet.")
        }
        var text = String(format: "Your last drive was %.1f kilometres", distance)
        if let duration = snapshot.lastTripDurationSeconds {
            text += " over \(Int(duration / 60)) minutes"
        }
        if let economy = snapshot.lastTripEconomyKmPerLitre {
            text += String(format: ", at about %.1f kilometres per litre", economy)
        } else {
            text += ". There was no fuel data for it, so I can't give you an economy figure"
        }
        return .result(dialog: IntentDialog(stringLiteral: text + "."))
    }
}

struct DriveLayerShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: VehicleStatusIntent(),
                    phrases: ["How is my car in \(.applicationName)",
                              "Check my vehicle with \(.applicationName)"],
                    shortTitle: "Check my vehicle",
                    systemImageName: "car")
        AppShortcut(intent: NextServiceIntent(),
                    phrases: ["When is my service due in \(.applicationName)"],
                    shortTitle: "Next service",
                    systemImageName: "wrench.and.screwdriver")
        AppShortcut(intent: LastDriveIntent(),
                    phrases: ["How was my last drive in \(.applicationName)"],
                    shortTitle: "Last drive",
                    systemImageName: "map")
    }
}
