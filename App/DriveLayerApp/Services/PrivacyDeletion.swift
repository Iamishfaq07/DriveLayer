import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

/// The one place that knows what "delete" has to mean.
///
/// `GarageStore.deleteEverything()` was thorough about storage and silent about
/// everything else, so after a driver deleted all their data the app still had:
///
/// - the deleted vehicle's name, health and estimated range on the home screen,
///   because the widget snapshot lives in a shared app group and nothing cleared it;
/// - scheduled notifications about documents that no longer existed;
/// - a running Live Activity for a drive whose record had just been removed;
/// - a live drive still recording into a database that had been emptied under it.
///
/// Deletion is therefore an orchestration problem rather than a storage one, and the
/// order matters: stop the things that are still writing *before* removing what they
/// write into, then clear the surfaces that outlive the app, then reset what is held in
/// memory. Doing storage first is how a checkpoint mid-deletion could resurrect a row.
@MainActor
enum PrivacyDeletion {

    /// Backs "Delete all data".
    static func deleteEverything(in environment: AppEnvironment) async {
        await stopEverythingStillWriting(in: environment)

        environment.store.deleteEverything()

        await clearSurfacesThatOutliveTheApp(in: environment)
        environment.resetAfterDeletion()
    }

    /// Backs "delete this vehicle", which is the same problem at a smaller scale: its
    /// documents, its reminders and its widget content all have to go with it.
    static func delete(vehicleID: UUID, in environment: AppEnvironment) async {
        // Only if the drive being recorded belongs to the vehicle being deleted.
        if environment.drive.vehicle?.id == vehicleID {
            environment.drive.abandonActiveDrive()
            LiveActivityController.shared.end()
        }

        environment.store.delete(vehicleID: vehicleID)

        // Reminders are rescheduled wholesale from what is left, so cancelling here and
        // letting the next analysis pass rebuild is both correct and simpler than
        // working out which individual requests belonged to this vehicle.
        await environment.reminders.cancelAll()
        WidgetSnapshotPublisher.clear()
        environment.resetAfterDeletion(reload: true)
    }

    // MARK: - Steps

    private static func stopEverythingStillWriting(in environment: AppEnvironment) async {
        // Abandoned, not ended: ending would save the drive that is being deleted.
        environment.drive.abandonActiveDrive()
        environment.drive.stop()
        await environment.obd.disconnect()
        environment.location.stop()
        environment.motion.stop()
    }

    private static func clearSurfacesThatOutliveTheApp(in environment: AppEnvironment) async {
        LiveActivityController.shared.end()
        await environment.reminders.cancelAll()
        WidgetSnapshotPublisher.clear()
    }
}
