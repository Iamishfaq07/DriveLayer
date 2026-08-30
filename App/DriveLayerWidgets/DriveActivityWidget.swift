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
struct DriveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        #if canImport(ActivityKit)
        ActivityConfiguration(for: DriveActivityAttributes.self) { context in
            LockScreenDriveView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
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
        }
        #else
        StaticConfiguration(kind: "DriveLayerDriveActivity", provider: SnapshotProvider()) { _ in
            EmptyView()
        }
        #endif
    }
}

#if canImport(ActivityKit)
private struct LockScreenDriveView: View {
    let context: ActivityViewContext<DriveActivityAttributes>

    var body: some View {
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
#endif
