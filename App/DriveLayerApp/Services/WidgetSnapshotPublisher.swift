import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Publishes the widget snapshot, throttled.
///
/// Widget timelines are a scarce resource — reloading them on every analysis pass
/// would get DriveLayer's budget cut by the system — so a reload is requested only
/// when something a widget actually displays has changed.
@MainActor
enum WidgetSnapshotPublisher {

    private static var lastPublished: WidgetSnapshot?

    static func publish(vehicle: Vehicle?,
                        health: VehicleHealthReport?,
                        fuel: FuelStatus,
                        nextService: MaintenanceDueStatus?,
                        lastTrip: Trip?,
                        headline: DriveInsight?,
                        isAdapterConnected: Bool) {
        guard let vehicle else {
            store(.empty)
            return
        }

        let snapshot = WidgetSnapshot(
            generatedAt: Date(),
            vehicleName: vehicle.nickname,
            healthStatusRawValue: (health?.overall ?? .unknown).rawValue,
            healthHeadline: health?.headline ?? "Not enough data",
            estimatedRangeKm: fuel.estimatedRangeKm.value,
            fuelLevelPercent: fuel.levelPercent.value,
            nextServiceName: nextService?.item.name,
            nextServiceSummary: nextService?.summary,
            nextServiceStatusRawValue: nextService?.status.rawValue,
            lastTripDistanceKm: lastTrip?.distanceKm,
            lastTripDurationSeconds: lastTrip?.totalDurationSeconds,
            lastTripEconomyKmPerLitre: lastTrip?.economyKmPerLitre,
            lastTripEndedAt: lastTrip?.endedAt,
            headlineInsightTitle: headline?.title,
            headlineInsightSummary: headline?.summary,
            isAdapterConnected: isAdapterConnected
        )
        store(snapshot)
    }

    /// Clears the snapshot and reloads the widgets.
    ///
    /// `lastPublished` has to be reset too: it exists to suppress redundant reloads, and
    /// leaving it set would suppress the very next publish if that publish happened to
    /// be equal to what was on screen before the deletion.
    static func clear() {
        lastPublished = nil
        WidgetSnapshotStore.clear()
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    private static func store(_ snapshot: WidgetSnapshot) {
        // `generatedAt` always differs, so it is excluded from the comparison.
        if var previous = lastPublished {
            previous.generatedAt = snapshot.generatedAt
            guard previous != snapshot else { return }
        }
        lastPublished = snapshot
        WidgetSnapshotStore.write(snapshot)
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}
