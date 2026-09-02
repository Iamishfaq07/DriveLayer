import WidgetKit
import SwiftUI
#if canImport(ActivityKit)
import ActivityKit
#endif

/// The Live Activity for a drive in progress.
///
/// Distance, duration, one status and at most one thing worth saying. Not a mini
/// dashboard: on the Lock Screen and in the Dynamic Island the driver is glancing,
/// and a glance holds three things.
///
/// Declaring the `small` activity family is what puts a live drive on the **CarPlay
/// dashboard**, beside Maps, without the driver opening anything. CarPlay renders
/// that family the same way the Apple Watch Smart Stack does, so the one small
/// layout below serves both. This is the mechanism Apple actually gives a
/// third-party app for dashboard content - `CPDashboardController` is not it - and
/// it is why the layout branches on `activityFamily` rather than assuming the Lock
/// Screen's space. See docs/CARPLAY.md.
struct DriveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        #if canImport(ActivityKit)
        ActivityConfiguration(for: DriveActivityAttributes.self) { context in
            LockScreenDriveView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(DeepLink.drive.url)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Distance").font(.caption2).foregroundStyle(.secondary)
                        Text(String(format: "%.1f km", context.state.distanceKm))
                            .font(.system(.title3, design: .rounded))
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Duration").font(.caption2).foregroundStyle(.secondary)
                        Text("\(Int(context.state.durationSeconds / 60)) min")
                            .font(.system(.title3, design: .rounded))
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let headline = context.state.headline {
                        Label(headline, systemImage: context.state.vehicleStatus.symbolName)
                            .font(.caption)
                    } else {
                        Label(context.state.vehicleStatus.label, systemImage: context.state.vehicleStatus.symbolName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                Image(systemName: "steeringwheel")
            } compactTrailing: {
                Text(String(format: "%.0f km", context.state.distanceKm))
                    .font(.caption2.monospacedDigit())
            } minimal: {
                Image(systemName: context.state.vehicleStatus.symbolName)
            }
            .widgetURL(DeepLink.drive.url)
        }
        .supplementalActivityFamilies([.small])
        #else
        StaticConfiguration(kind: "DriveLayerDriveActivity", provider: SnapshotProvider()) { _ in
            EmptyView()
        }
        #endif
    }
}

#if canImport(ActivityKit)
private struct LockScreenDriveView: View {
    /// `small` is the CarPlay dashboard and the Watch Smart Stack; anything else is
    /// the Lock Screen, which has room for the fuller layout.
    @Environment(\.activityFamily) private var activityFamily
    let context: ActivityViewContext<DriveActivityAttributes>

    var body: some View {
        if activityFamily == .small {
            SmallDriveView(context: context)
        } else {
            lockScreenBody
        }
    }

    private var lockScreenBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(context.attributes.vehicleName, systemImage: "steeringwheel")
                    .font(.caption.weight(.semibold))
                Spacer()
                Label(context.state.vehicleStatus.label,
                      systemImage: context.state.vehicleStatus.symbolName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Distance").font(.caption2).foregroundStyle(.secondary)
                    Text(String(format: "%.1f km", context.state.distanceKm))
                        .font(.system(.title2, design: .rounded))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Duration").font(.caption2).foregroundStyle(.secondary)
                    Text("\(Int(context.state.durationSeconds / 60)) min")
                        .font(.system(.title2, design: .rounded))
                }
                if let range = context.state.estimatedRangeKm {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Range").font(.caption2).foregroundStyle(.secondary)
                        Text(String(format: "~%.0f km", range))
                            .font(.system(.title2, design: .rounded))
                    }
                }
            }
            if let headline = context.state.headline {
                VStack(alignment: .leading, spacing: 1) {
                    Text(headline)
                        .font(.caption.weight(.semibold))
                    if let detail = context.state.headlineDetail {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
        }
        .padding()
    }
}

/// The drive at dashboard scale: on CarPlay this sits beside Maps, and on the Watch
/// in the Smart Stack. Three things, because that is what a glance at speed holds -
/// distance leads because it is the number that is actually changing, and the
/// headline replaces the plain status only when there is something worth saying.
private struct SmallDriveView: View {
    let context: ActivityViewContext<DriveActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: "steeringwheel")
                Text(context.attributes.vehicleName)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: context.state.vehicleStatus.symbolName)
            }
            .font(.caption2.weight(.semibold))

            Text(String(format: "%.1f km", context.state.distanceKm))
                .font(.system(.title2, design: .rounded).weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Text(context.state.headline ?? "\(Int(context.state.durationSeconds / 60)) min")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }
}
#endif
