import WidgetKit
import SwiftUI

@main
struct DriveLayerWidgetBundle: WidgetBundle {
    var body: some Widget {
        VehicleStatusWidget()
        RangeWidget()
        ServiceWidget()
        LastTripWidget()
        DriveActivityWidget()
    }
}

/// Reads the snapshot the app publishes. Widgets never compute anything themselves —
/// they render what the app has already interpreted.
struct SnapshotProvider: TimelineProvider {

    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        let snapshot = context.isPreview ? WidgetSnapshot.placeholder : (WidgetSnapshotStore.read() ?? .empty)
        completion(SnapshotEntry(date: Date(), snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let snapshot = WidgetSnapshotStore.read() ?? .empty
        let entry = SnapshotEntry(date: Date(), snapshot: snapshot)
        // The app reloads timelines when something changes; this is the fallback so a
        // widget cannot sit indefinitely on a stale reading.
        let next = Date().addingTimeInterval(30 * 60)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

// MARK: - Shared pieces

/// Widget-side status mark. Same rule as in the app: shape carries the meaning, so
/// it reads correctly in tinted and accented widget rendering modes.
private struct WidgetStatusMark: View {
    let status: SemanticStatus
    var size: CGFloat = 13

    var body: some View {
        Image(systemName: status.symbolName)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(color)
            .accessibilityLabel(status.label)
    }

    private var color: Color {
        switch status {
        case .normal: return .green
        case .watch: return .yellow
        case .attention: return .orange
        case .critical: return .red
        case .unknown: return .secondary
        }
    }
}

private struct WidgetLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
    }
}

/// A value that renders "—" when it is genuinely unknown.
private struct WidgetValue: View {
    let value: String?
    var unit: String?
    var size: CGFloat = 26

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(value ?? "—")
                .font(.system(size: size, weight: .medium, design: .rounded))
                .foregroundStyle(value == nil ? .secondary : .primary)
            if let unit, value != nil {
                Text(unit)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .minimumScaleFactor(0.7)
        .lineLimit(1)
    }
}

private func formattedDistance(_ kilometres: Double?) -> String? {
    guard let kilometres else { return nil }
    return String(format: "%.0f", kilometres)
}

// MARK: - Widgets

struct VehicleStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "DriveLayerVehicleStatus", provider: SnapshotProvider()) { entry in
            VehicleStatusWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Vehicle status")
        .description("How your car is doing, and anything worth knowing.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

struct VehicleStatusWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.snapshot.vehicleName)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            HStack(spacing: 5) {
                WidgetStatusMark(status: entry.snapshot.healthStatus, size: 15)
                Text(entry.snapshot.healthHeadline)
                    .font(.system(size: 17, weight: .medium, design: .rounded))
                    .lineLimit(1)
            }
            if family != .accessoryRectangular {
                Spacer(minLength: 0)
                if let title = entry.snapshot.headlineInsightTitle {
                    VStack(alignment: .leading, spacing: 2) {
                        WidgetLabel(text: title)
                        if family == .systemMedium, let summary = entry.snapshot.headlineInsightSummary {
                            Text(summary)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                    }
                } else {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 1) {
                            WidgetLabel(text: "Range")
                            WidgetValue(value: formattedDistance(entry.snapshot.estimatedRangeKm), unit: "km", size: 18)
                        }
                        if !entry.snapshot.isAdapterConnected {
                            VStack(alignment: .leading, spacing: 1) {
                                WidgetLabel(text: "Adapter")
                                Text("Not connected")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        // Tapping opens what the widget is actually showing: the insight if there is
        // one, the vehicle's own screen if there isn't.
        .widgetURL(entry.snapshot.headlineInsightTitle == nil ? DeepLink.vehicle.url : DeepLink.insights.url)
    }
}

struct RangeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "DriveLayerRange", provider: SnapshotProvider()) { entry in
            RangeWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Fuel and range")
        .description("Estimated range and tank level.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular])
    }
}

struct RangeWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry

    var body: some View {
        content.widgetURL(DeepLink.fuel.url)
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .accessoryCircular:
            Gauge(value: entry.snapshot.fuelLevelPercent ?? 0, in: 0...100) {
                Image(systemName: "fuelpump")
            } currentValueLabel: {
                Text(entry.snapshot.fuelLevelPercent.map { "\(Int($0))" } ?? "—")
            }
            .gaugeStyle(.accessoryCircular)
        default:
            VStack(alignment: .leading, spacing: 6) {
                WidgetLabel(text: "Range")
                WidgetValue(value: formattedDistance(entry.snapshot.estimatedRangeKm), unit: "km", size: 30)
                Spacer(minLength: 0)
                WidgetLabel(text: "Fuel")
                WidgetValue(value: entry.snapshot.fuelLevelPercent.map { String(format: "%.0f", $0) },
                            unit: "%", size: 18)
                if entry.snapshot.estimatedRangeKm != nil {
                    Text("Estimated")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}

struct ServiceWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "DriveLayerService", provider: SnapshotProvider()) { entry in
            ServiceWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Service due")
        .description("What's due next, by distance or date.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

struct ServiceWidgetView: View {
    let entry: SnapshotEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                WidgetLabel(text: "Next service")
                Spacer()
                if entry.snapshot.nextServiceName != nil {
                    WidgetStatusMark(status: entry.snapshot.nextServiceStatus, size: 12)
                }
            }
            if let name = entry.snapshot.nextServiceName {
                Text(name)
                    .font(.system(size: 16, weight: .medium))
                    .lineLimit(1)
                Text(entry.snapshot.nextServiceSummary ?? "")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            } else {
                Text("Nothing set up")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("Add your last service in DriveLayer to track what's due.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .widgetURL(DeepLink.maintenance.url)
    }
}

struct LastTripWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "DriveLayerLastTrip", provider: SnapshotProvider()) { entry in
            LastTripWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Last drive")
        .description("Distance, duration and economy from your most recent drive.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct LastTripWidgetView: View {
    let entry: SnapshotEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            WidgetLabel(text: "Last drive")
            if let distance = entry.snapshot.lastTripDistanceKm {
                WidgetValue(value: String(format: "%.1f", distance), unit: "km", size: 28)
                HStack(spacing: 10) {
                    if let duration = entry.snapshot.lastTripDurationSeconds {
                        Text("\(Int(duration / 60)) min")
                    }
                    if let economy = entry.snapshot.lastTripEconomyKmPerLitre {
                        Text(String(format: "%.1f km/L", economy))
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                if let ended = entry.snapshot.lastTripEndedAt {
                    Text(ended, style: .relative)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("No drives yet")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        // Opens the drive itself. The link names "my last drive" rather than an
        // identifier, so the app resolves which one that is as it opens — a drive
        // finished since this widget refreshed opens the new one, not a stale one.
        .widgetURL(entry.snapshot.lastTripDistanceKm == nil ? DeepLink.trips.url : DeepLink.lastTrip.url)
    }
}
