import SwiftUI

/// One drive, in six sections: overview, route, vehicle, efficiency, terrain, events.
///
/// The ordering is deliberate — a driver wants the summary first and the raw event
/// log last — and each section disappears entirely when there is nothing behind it,
/// rather than showing empty rows.
struct TripDetailView: View {

    let trip: Trip
    @Environment(AppEnvironment.self) private var environment
    @State private var comparison: TripComparison?

    private var formatter: DisplayFormatter { environment.formatter }

    var body: some View {
        List {
            overviewSection
            if let comparison, let summary = comparison.summary {
                Section("Compared with your usual") {
                    Text(summary)
                        .font(DL.Font.body)
                        .foregroundStyle(DLColor.primaryText)
                    Text("Based on \(comparison.comparableTripCount) previous drives between the same areas. DriveLayer reports what moved together, not what caused what.")
                        .font(DL.Font.caption)
                        .foregroundStyle(DLColor.secondaryText)
                }
            }
            efficiencySection
            vehicleSection
            terrainSection
            weatherSection
            eventsSection
        }
        .navigationTitle(formatter.mediumDate(trip.startedAt) ?? "Drive")
        .navigationBarTitleDisplayMode(.inline)
        .task { loadComparison() }
    }

    private var overviewSection: some View {
        Section {
            DLAdaptiveRow {
                MetricView(label: "Distance",
                           value: formatter.distance(metres: trip.distanceMetres),
                           unit: formatter.distanceUnitLabel)
                    .frame(maxWidth: .infinity, alignment: .leading)
                MetricView(label: "Duration", value: formatter.duration(seconds: trip.totalDurationSeconds))
                    .frame(maxWidth: .infinity, alignment: .leading)
                MetricView(label: "Average",
                           value: formatter.speed(kmh: trip.averageSpeedKmh),
                           unit: formatter.speedUnitLabel)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, DL.Spacing.tight)

            ValueOrReasonRow(label: "Started", value: formatter.shortTime(trip.startedAt))
            ValueOrReasonRow(label: "Ended", value: formatter.shortTime(trip.endedAt), reason: "Still recording")
            ValueOrReasonRow(label: "Idle time",
                             value: formatter.duration(seconds: trip.idleDurationSeconds))
            ValueOrReasonRow(label: "Top speed",
                             value: formatter.speed(kmh: trip.maximumSpeedKmh),
                             unit: formatter.speedUnitLabel,
                             reason: "Not recorded")
        }
    }

    private var efficiencySection: some View {
        Section("Efficiency") {
            ValueOrReasonRow(label: "Fuel used",
                             value: formatter.volume(litres: trip.fuelUsedLitres.value),
                             unit: formatter.volumeUnitLabel,
                             provenance: trip.fuelUsedLitres.provenance,
                             reason: "No fuel data for this drive")
            ValueOrReasonRow(label: "Economy",
                             value: formatter.economy(kmPerLitre: trip.economyKmPerLitre),
                             unit: formatter.economyUnitLabel,
                             provenance: .estimated,
                             reason: "Needs fuel data")
            if let basis = trip.fuelUsedLitres.basis {
                Text(basis)
                    .font(DL.Font.caption)
                    .foregroundStyle(DLColor.secondaryText)
            }
        }
    }

    @ViewBuilder
    private var vehicleSection: some View {
        if trip.peakCoolantTemperatureC != nil
            || trip.averageEngineLoadPercent != nil
            || trip.minimumControlModuleVoltage != nil {
            Section("Vehicle") {
                ValueOrReasonRow(label: "Peak coolant",
                                 value: formatter.temperature(celsius: trip.peakCoolantTemperatureC),
                                 unit: formatter.temperatureUnitLabel)
                ValueOrReasonRow(label: "Average load",
                                 value: formatter.percent(trip.averageEngineLoadPercent),
                                 unit: "%")
                ValueOrReasonRow(label: "Lowest voltage",
                                 value: formatter.voltage(trip.minimumControlModuleVoltage),
                                 unit: "V")
                Text("Recorded from \(trip.telemetrySampleCount) samples during the drive.")
                    .font(DL.Font.caption)
                    .foregroundStyle(DLColor.secondaryText)
            }
        } else {
            Section("Vehicle") {
                Text("No vehicle data was recorded for this drive. Connect an OBD-II adapter to capture engine readings.")
                    .font(DL.Font.callout)
                    .foregroundStyle(DLColor.secondaryText)
            }
        }
    }

    @ViewBuilder
    private var terrainSection: some View {
        if trip.elevationGainMetres > 0 || trip.elevationLossMetres > 0 {
            Section("Terrain") {
                ValueOrReasonRow(label: "Climbed", value: "\(Int(trip.elevationGainMetres.rounded()))", unit: "m", provenance: .estimated)
                ValueOrReasonRow(label: "Descended", value: "\(Int(trip.elevationLossMetres.rounded()))", unit: "m", provenance: .estimated)
                if let high = trip.maximumAltitudeMetres, let low = trip.minimumAltitudeMetres {
                    ValueOrReasonRow(label: "Altitude range",
                                     value: "\(Int(low.rounded()))–\(Int(high.rounded()))",
                                     unit: "m",
                                     provenance: .estimated)
                }
            }
        }
    }

    @ViewBuilder
    private var weatherSection: some View {
        if let weather = trip.weather {
            Section("Weather") {
                ValueOrReasonRow(label: "Conditions", value: weather.conditionDescription)
                ValueOrReasonRow(label: "Temperature",
                                 value: formatter.temperature(celsius: weather.temperatureC),
                                 unit: formatter.temperatureUnitLabel)
                ValueOrReasonRow(label: "Visibility",
                                 value: weather.visibilityMetres.map { String(Int($0.rounded())) },
                                 unit: "m",
                                 reason: "Not recorded")
                Text("Recorded during the drive, not looked up afterwards.")
                    .font(DL.Font.caption)
                    .foregroundStyle(DLColor.secondaryText)
            }
        }
    }

    @ViewBuilder
    private var eventsSection: some View {
        if !trip.events.isEmpty {
            Section("Events") {
                ForEach(trip.events) { event in
                    HStack(alignment: .top, spacing: DL.Spacing.small) {
                        Image(systemName: event.kind.symbolName)
                            .foregroundStyle(DLColor.status(event.severity))
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.kind.displayName)
                                .font(DL.Font.callout.weight(.medium))
                                .foregroundStyle(DLColor.primaryText)
                            Text(event.note)
                                .font(DL.Font.caption)
                                .foregroundStyle(DLColor.secondaryText)
                        }
                        Spacer()
                        Text(formatter.shortTime(event.timestamp) ?? "")
                            .font(DL.Font.caption.monospacedDigit())
                            .foregroundStyle(DLColor.unknown)
                    }
                }
            }
        }
    }

    private func loadComparison() {
        guard let vehicle = environment.selectedVehicle else { return }
        let history = environment.store.trips(vehicleID: vehicle.id, limit: 200)
        comparison = TripComparisonEngine.compare(trip, against: history)
    }
}
