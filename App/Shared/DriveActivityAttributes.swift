import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

/// The contract between the app and the Live Activity.
///
/// Shared source, compiled into both the app and the widget extension. Deliberately
/// small: a Live Activity is a glance, not a dashboard, so it carries the drive's
/// headline numbers, one status, and at most one thing worth saying.
#if canImport(ActivityKit)
struct DriveActivityAttributes: ActivityAttributes {

    struct ContentState: Codable, Hashable {
        var distanceKm: Double
        var durationSeconds: Double
        /// `SemanticStatus.rawValue`, so the widget renders the same vocabulary.
        var vehicleStatusRawValue: String
        var headline: String?
        var headlineDetail: String?
        /// Estimated range, when it is known. Absent means absent — the widget shows
        /// a dash, never a zero.
        var estimatedRangeKm: Double?

        var vehicleStatus: SemanticStatus {
            SemanticStatus(rawValue: vehicleStatusRawValue) ?? .unknown
        }
    }

    var vehicleName: String
}
#endif
