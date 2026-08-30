import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

/// Starts, updates and ends the drive Live Activity.
///
/// Updates are throttled hard. A Live Activity that refreshes every second is a
/// battery drain and a distraction; one that refreshes when the numbers have
/// meaningfully moved is useful. Nothing here starts without the driver having
/// enabled Live Activities in settings.
@MainActor
final class LiveActivityController {

    static let shared = LiveActivityController()

    private var lastUpdate: Date?
    private var lastState: ActivityStateSnapshot?
    private let minimumUpdateInterval: TimeInterval = 20

    private struct ActivityStateSnapshot: Equatable {
        var distanceKm: Double
        var status: SemanticStatus
        var headline: String?
    }

    #if canImport(ActivityKit)
    private var activity: Activity<DriveActivityAttributes>?
    #endif

    var isSupported: Bool {
        #if canImport(ActivityKit)
        return ActivityAuthorizationInfo().areActivitiesEnabled
        #else
        return false
        #endif
    }

    func start(trip: Trip?, vehicleName: String, settings: AppSettings) {
        #if canImport(ActivityKit)
        guard settings.liveActivitiesEnabled, isSupported, activity == nil, let trip else { return }
        let attributes = DriveActivityAttributes(vehicleName: vehicleName)
        let state = DriveActivityAttributes.ContentState(distanceKm: trip.distanceKm,
                                                         durationSeconds: trip.totalDurationSeconds,
                                                         vehicleStatusRawValue: SemanticStatus.unknown.rawValue,
                                                         headline: nil,
                                                         headlineDetail: nil,
                                                         estimatedRangeKm: nil)
        do {
            activity = try Activity.request(attributes: attributes,
                                            content: ActivityContent(state: state, staleDate: nil))
            lastUpdate = Date()
        } catch {
            // A refused Live Activity is not worth interrupting a drive over.
            PrivacyLog.logger(.app).notice("Live Activity could not be started")
        }
        #endif
    }

    func update(trip: Trip?, insight: DriveInsight?, health: SemanticStatus?, settings: AppSettings) {
        #if canImport(ActivityKit)
        guard settings.liveActivitiesEnabled, let activity, let trip else { return }
        let snapshot = ActivityStateSnapshot(distanceKm: (trip.distanceKm * 10).rounded() / 10,
                                             status: health ?? .unknown,
                                             headline: insight?.title)
        let now = Date()
        // Update when something a driver would notice has changed, and never more
        // often than the throttle allows.
        let isDue = lastUpdate.map { now.timeIntervalSince($0) >= minimumUpdateInterval } ?? true
        let hasChanged = snapshot != lastState
        guard isDue, hasChanged else { return }

        lastUpdate = now
        lastState = snapshot
        let state = DriveActivityAttributes.ContentState(distanceKm: trip.distanceKm,
                                                         durationSeconds: trip.totalDurationSeconds,
                                                         vehicleStatusRawValue: (health ?? .unknown).rawValue,
                                                         headline: insight?.title,
                                                         headlineDetail: insight?.summary,
                                                         estimatedRangeKm: nil)
        Task {
            await activity.update(ActivityContent(state: state, staleDate: now.addingTimeInterval(300)))
        }
        #endif
    }

    func end() {
        #if canImport(ActivityKit)
        guard let activity else { return }
        self.activity = nil
        lastState = nil
        lastUpdate = nil
        Task {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        #endif
    }
}
