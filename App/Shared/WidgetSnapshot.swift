import Foundation

/// What the app hands to its widgets, CarPlay and Siri.
///
/// Widgets cannot read the app's database, so the app writes a small snapshot to a
/// shared container after each analysis pass. It is deliberately tiny and made of
/// already-formatted, already-interpreted values: a widget should render, not reason.
///
/// Every optional here means "genuinely unknown". A widget shows a dash for those.
struct WidgetSnapshot: Codable, Sendable, Equatable {

    var generatedAt: Date
    var vehicleName: String
    /// `SemanticStatus.rawValue`.
    var healthStatusRawValue: String
    var healthHeadline: String
    var estimatedRangeKm: Double?
    var fuelLevelPercent: Double?
    var nextServiceName: String?
    var nextServiceSummary: String?
    var nextServiceStatusRawValue: String?
    var lastTripDistanceKm: Double?
    var lastTripDurationSeconds: Double?
    var lastTripEconomyKmPerLitre: Double?
    var lastTripEndedAt: Date?
    /// Averaged over the full-to-full intervals that carry a price, in the currency
    /// the driver typed. Nil when no fill has a price on it — a cost figure built from
    /// half the fills would be worse than none.
    var costPerKilometre: Double?
    var headlineInsightTitle: String?
    var headlineInsightSummary: String?
    var isAdapterConnected: Bool

    var healthStatus: SemanticStatus {
        SemanticStatus(rawValue: healthStatusRawValue) ?? .unknown
    }

    var nextServiceStatus: SemanticStatus {
        nextServiceStatusRawValue.flatMap(SemanticStatus.init(rawValue:)) ?? .unknown
    }

    static let placeholder = WidgetSnapshot(
        generatedAt: Date(),
        vehicleName: "Harrier",
        healthStatusRawValue: SemanticStatus.normal.rawValue,
        healthHeadline: "Healthy",
        estimatedRangeKm: 326,
        fuelLevelPercent: 58,
        nextServiceName: "Periodic service",
        nextServiceSummary: "Due in about 1120 km or 34 days.",
        nextServiceStatusRawValue: SemanticStatus.watch.rawValue,
        lastTripDistanceKm: 42.6,
        lastTripDurationSeconds: 47 * 60,
        lastTripEconomyKmPerLitre: 12.8,
        lastTripEndedAt: Date().addingTimeInterval(-3_600),
        costPerKilometre: 7.4,
        headlineInsightTitle: "BATTERY WATCH",
        headlineInsightSummary: "Battery voltage has been trending below your normal baseline.",
        isAdapterConnected: true
    )

    /// Shown before a vehicle exists — honest rather than a fake car.
    static let empty = WidgetSnapshot(
        generatedAt: Date(),
        vehicleName: "DriveLayer",
        healthStatusRawValue: SemanticStatus.unknown.rawValue,
        healthHeadline: "No vehicle yet",
        estimatedRangeKm: nil,
        fuelLevelPercent: nil,
        nextServiceName: nil,
        nextServiceSummary: nil,
        nextServiceStatusRawValue: nil,
        lastTripDistanceKm: nil,
        lastTripDurationSeconds: nil,
        lastTripEconomyKmPerLitre: nil,
        lastTripEndedAt: nil,
        costPerKilometre: nil,
        headlineInsightTitle: nil,
        headlineInsightSummary: nil,
        isAdapterConnected: false
    )
}

/// Reads and writes the snapshot in the shared app group.
///
/// A file rather than `UserDefaults`: it is one blob, it is written rarely, and a
/// file makes the "nothing has been written yet" case obvious instead of returning
/// zeroes for missing keys.
enum WidgetSnapshotStore {

    /// Must match the App Group in both targets' entitlements.
    static let appGroupIdentifier = "group.com.drivelayer.app"
    static let widgetKind = "DriveLayerStatusWidget"

    private static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appendingPathComponent("widget-snapshot.json")
    }

    static func write(_ snapshot: WidgetSnapshot) {
        guard let fileURL else { return }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(snapshot).write(to: fileURL, options: [.atomic])
        } catch {
            PrivacyLog.error(.app, "Could not update the widget snapshot")
        }
    }

    /// Removes the snapshot entirely.
    ///
    /// Called when the data behind the widgets is deleted. The snapshot lives in the
    /// shared app group, so without this it outlives the deletion and the widgets keep
    /// showing a deleted vehicle's name, health and range - the one thing "delete all
    /// data" must not leave sitting on the home screen.
    static func clear() {
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }

    static func read() -> WidgetSnapshot? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }
}
