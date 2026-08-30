import SwiftUI

struct TripsListView: View {

    /// Bound from `RootView` so the last-drive widget can push a drive onto this tab.
    @Binding var path: [DeepLink]

    @Environment(AppEnvironment.self) private var environment
    @State private var trips: [Trip] = []

    private var formatter: DisplayFormatter { environment.formatter }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if environment.selectedVehicle == nil {
                    DLUnavailableState(reason: .noVehicleSelected)
                } else if trips.isEmpty {
                    DLEmptyState(symbol: "map",
                                 title: "No drives yet",
                                 message: "DriveLayer records a drive automatically once you're moving, or you can start one from the Drive tab.")
                } else {
                    List {
                        summarySection
                        ForEach(groupedTrips, id: \.title) { group in
                            Section(group.title) {
                                ForEach(group.trips) { trip in
                                    NavigationLink(destination: TripDetailView(trip: trip)) {
                                        TripRow(trip: trip, formatter: formatter)
                                    }
                                }
                                .onDelete { offsets in delete(in: group, offsets: offsets) }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Trips")
            .task { reload() }
            .refreshable { reload() }
            .deepLinkDestinations()
        }
    }

    private var summarySection: some View {
        let analytics = TripAnalytics.summarise(trips)
        return Section {
            DLAdaptiveRow {
                MetricView(label: "Drives", value: "\(analytics.tripCount)")
                    .frame(maxWidth: .infinity, alignment: .leading)
                MetricView(label: "Distance",
                           value: formatter.distance(kilometres: analytics.totalDistanceKm, fractionDigits: 0),
                           unit: formatter.distanceUnitLabel)
                    .frame(maxWidth: .infinity, alignment: .leading)
                MetricView(label: "Typical economy",
                           value: formatter.economy(kmPerLitre: analytics.medianEconomyKmPerLitre),
                           unit: formatter.economyUnitLabel,
                           provenance: .estimated)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, DL.Spacing.tight)
        }
    }

    private struct TripGroup {
        var title: String
        var trips: [Trip]
    }

    private var groupedTrips: [TripGroup] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: trips) { trip in
            calendar.dateInterval(of: .month, for: trip.startedAt)?.start ?? trip.startedAt
        }
        let monthFormatter = DateFormatter()
        monthFormatter.dateFormat = "LLLL yyyy"
        return grouped
            .sorted { $0.key > $1.key }
            .map { TripGroup(title: monthFormatter.string(from: $0.key), trips: $0.value.sorted { $0.startedAt > $1.startedAt }) }
    }

    private func reload() {
        guard let vehicle = environment.selectedVehicle else { return }
        trips = environment.store.trips(vehicleID: vehicle.id)
    }

    private func delete(in group: TripGroup, offsets: IndexSet) {
        for index in offsets {
            let trip = group.trips[index]
            environment.store.delete(tripID: trip.id)
            if let vehicle = environment.selectedVehicle {
                TelemetryFileStore.shared.delete(vehicleID: vehicle.id, tripID: trip.id)
            }
        }
        reload()
    }
}

private struct TripRow: View {
    let trip: Trip
    let formatter: DisplayFormatter

    var body: some View {
        HStack(alignment: .center, spacing: DL.Spacing.medium) {
            VStack(alignment: .leading, spacing: 2) {
                Text(formatter.mediumDate(trip.startedAt) ?? "")
                    .font(DL.Font.body.weight(.medium))
                    .foregroundStyle(DLColor.primaryText)
                Text([formatter.shortTime(trip.startedAt),
                      formatter.duration(seconds: trip.totalDurationSeconds)]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(DL.Font.caption)
                    .foregroundStyle(DLColor.secondaryText)
            }
            Spacer(minLength: DL.Spacing.small)
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(formatter.distance(metres: trip.distanceMetres) ?? "—") \(formatter.distanceUnitLabel)")
                    .font(DL.Font.body.monospacedDigit())
                    .foregroundStyle(DLColor.primaryText)
                if let economy = formatter.economy(kmPerLitre: trip.economyKmPerLitre) {
                    Text("\(economy) \(formatter.economyUnitLabel)")
                        .font(DL.Font.caption.monospacedDigit())
                        .foregroundStyle(DLColor.secondaryText)
                } else if !trip.events.isEmpty {
                    Text("\(trip.events.count) event\(trip.events.count == 1 ? "" : "s")")
                        .font(DL.Font.caption)
                        .foregroundStyle(DLColor.secondaryText)
                }
            }
        }
        .padding(.vertical, 2)
    }
}


/// The most recent drive, resolved when it is opened.
///
/// This is what `drivelayer://last-drive` lands on. Looking the drive up now rather
/// than carrying an identifier in the URL means a drive finished since the widget
/// last refreshed opens the new one, and a deleted drive cannot leave the link
/// pointing at nothing.
struct LatestTripView: View {

    @Environment(AppEnvironment.self) private var environment

    private var latest: Trip? {
        environment.selectedVehicle.flatMap {
            environment.store.trips(vehicleID: $0.id, limit: 1).first
        }
    }

    var body: some View {
        if let latest {
            TripDetailView(trip: latest)
        } else if environment.selectedVehicle == nil {
            DLUnavailableState(reason: .noVehicleSelected)
        } else {
            DLEmptyState(symbol: "map",
                         title: "No drives yet",
                         message: "DriveLayer records a drive automatically once you're moving, or you can start one from the Drive tab.")
        }
    }
}
