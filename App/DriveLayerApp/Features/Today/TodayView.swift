import SwiftUI

/// The home screen.
///
/// It answers "is my car fine, and is there anything I should know?" before it shows
/// a single sensor value. Everything on it is either an interpretation or a number a
/// driver would actually plan around — never raw telemetry for its own sake.
struct TodayView: View {

    @Environment(AppEnvironment.self) private var environment
    @State private var isShowingCopilot = false

    private var formatter: DisplayFormatter { environment.formatter }
    private var drive: DriveSessionCoordinator { environment.drive }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DL.Spacing.large) {
                    if environment.selectedVehicle == nil {
                        DLUnavailableState(reason: .noVehicleSelected)
                            .padding(.top, DL.Spacing.section)
                    } else {
                        header
                        healthCard
                        quickFacts
                        insightsSection
                        nextServiceSection
                    }
                }
                .dlScreenPadding()
                .padding(.vertical, DL.Spacing.medium)
            }
            .background(DLColor.background)
            .navigationTitle("Today")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .refreshable { drive.refreshAnalysis(force: true) }
            .sheet(isPresented: $isShowingCopilot) { CopilotView() }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                NavigationLink(destination: GarageView()) {
                    Label("Garage", systemImage: "car.2")
                }
                NavigationLink(destination: InsightsView()) {
                    Label("All insights", systemImage: "lightbulb")
                }
                NavigationLink(destination: SettingsView()) {
                    Label("Settings", systemImage: "gearshape")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
        ToolbarItem(placement: .topBarLeading) {
            Button {
                isShowingCopilot = true
            } label: {
                Label("Ask copilot", systemImage: "bubble.left.and.text.bubble.right")
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: DL.Spacing.hairline) {
            Text(formatter.greeting(for: Date()))
                .font(DL.Font.callout)
                .foregroundStyle(DLColor.secondaryText)
            Text(environment.selectedVehicle?.nickname ?? "DriveLayer")
                .font(DL.Font.display)
                .foregroundStyle(DLColor.primaryText)
            Text(readinessLine)
                .font(DL.Font.callout)
                .foregroundStyle(DLColor.secondaryText)
        }
    }

    /// The line under the vehicle name. It says what DriveLayer can currently see,
    /// which is more useful than a decorative subtitle.
    private var readinessLine: String {
        let level = VehicleCapabilityLevel.current(profile: environment.profile,
                                                   isAdapterConnected: environment.obd.isConnected)
        if drive.isRecording { return "Recording a drive" }
        switch level {
        case .phoneOnly: return "Ready to drive — phone data only"
        case .obdConnected: return "Ready to drive — connected to your car"
        case .enhancedProfile: return "Ready to drive — enhanced vehicle data"
        }
    }

    @ViewBuilder
    private var healthCard: some View {
        if let health = drive.health {
            NavigationLink(destination: VehicleContentView()) {
                VStack(alignment: .leading, spacing: DL.Spacing.small) {
                    SectionLabel(text: "Vehicle")
                    HStack(spacing: DL.Spacing.small) {
                        StatusIndicator(status: health.overall, showsLabel: false, size: 20)
                        Text(health.headline)
                            .font(DL.Font.metric)
                            .foregroundStyle(DLColor.primaryText)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(DLColor.unknown)
                    }
                    if let explanation = healthExplanation(health) {
                        Text(explanation)
                            .font(DL.Font.callout)
                            .foregroundStyle(DLColor.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .dlCard()
            }
            .buttonStyle(.plain)
        }
    }

    private func healthExplanation(_ health: VehicleHealthReport) -> String? {
        if let worst = health.systems.filter({ $0.status >= .watch }).max(by: { $0.status < $1.status }) {
            return "\(worst.kind.displayName): \(worst.headline)"
        }
        if health.isLimitedByMissingData {
            return "Some systems can't be checked yet — connect an adapter for the full picture."
        }
        return "Everything DriveLayer can see looks normal."
    }

    private var quickFacts: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: DL.Spacing.medium) {
            MetricView(label: "Range",
                       value: formatter.distance(kilometres: drive.fuelStatus.estimatedRangeKm.value, fractionDigits: 0),
                       unit: formatter.distanceUnitLabel,
                       provenance: drive.fuelStatus.estimatedRangeKm.provenance)
                .frame(maxWidth: .infinity, alignment: .leading)
                .dlCard()

            MetricView(label: "Fuel",
                       value: formatter.percent(drive.fuelStatus.levelPercent.value),
                       unit: "%",
                       provenance: drive.fuelStatus.levelPercent.provenance)
                .frame(maxWidth: .infinity, alignment: .leading)
                .dlCard()

            lastDriveTile
            weatherTile
        }
    }

    @ViewBuilder
    private var lastDriveTile: some View {
        let lastTrip = environment.selectedVehicle.flatMap {
            environment.store.trips(vehicleID: $0.id, limit: 1).first
        }
        VStack(alignment: .leading, spacing: DL.Spacing.hairline) {
            SectionLabel(text: "Last drive")
            if let lastTrip {
                Text(formatter.distance(metres: lastTrip.distanceMetres) ?? "—")
                    .font(DL.Font.metric)
                    .foregroundStyle(DLColor.primaryText)
                Text([formatter.duration(seconds: lastTrip.totalDurationSeconds),
                      formatter.economy(kmPerLitre: lastTrip.economyKmPerLitre).map { "\($0) \(formatter.economyUnitLabel)" }]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(DL.Font.caption)
                    .foregroundStyle(DLColor.secondaryText)
            } else {
                Text("—")
                    .font(DL.Font.metric)
                    .foregroundStyle(DLColor.unknown)
                Text("No drives recorded yet")
                    .font(DL.Font.caption)
                    .foregroundStyle(DLColor.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dlCard()
    }

    @ViewBuilder
    private var weatherTile: some View {
        VStack(alignment: .leading, spacing: DL.Spacing.hairline) {
            SectionLabel(text: "Weather")
            if let weather = drive.currentWeather {
                HStack(spacing: DL.Spacing.tight) {
                    Image(systemName: weather.condition.symbolName)
                        .foregroundStyle(DLColor.secondaryText)
                    Text(formatter.temperature(celsius: weather.temperatureC).map { "\($0)\(formatter.temperatureUnitLabel)" } ?? "—")
                        .font(DL.Font.metric)
                        .foregroundStyle(DLColor.primaryText)
                }
                Text(drive.weatherChanges.first?.detail ?? weather.condition.displayName)
                    .font(DL.Font.caption)
                    .foregroundStyle(DLColor.secondaryText)
                    .lineLimit(2)
            } else {
                Text("—")
                    .font(DL.Font.metric)
                    .foregroundStyle(DLColor.unknown)
                Text(drive.weatherUnavailability?.title ?? "Not available")
                    .font(DL.Font.caption)
                    .foregroundStyle(DLColor.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dlCard()
    }

    @ViewBuilder
    private var insightsSection: some View {
        let visible = Array(drive.insights.prefix(3))
        if !visible.isEmpty {
            VStack(alignment: .leading, spacing: DL.Spacing.small) {
                HStack {
                    SectionLabel(text: "Worth knowing")
                    Spacer()
                    if drive.insights.count > visible.count {
                        NavigationLink("See all", destination: InsightsView())
                            .font(DL.Font.caption)
                    }
                }
                ForEach(visible) { insight in
                    InsightCard(insight: insight)
                }
            }
        }
    }

    @ViewBuilder
    private var nextServiceSection: some View {
        if let vehicle = environment.selectedVehicle {
            let statuses = MaintenanceEngine.statuses(for: environment.store.maintenanceItems(vehicleID: vehicle.id),
                                                      currentOdometerKm: vehicle.odometerKm,
                                                      now: Date())
            if let next = statuses.first(where: { $0.status != .unknown }) {
                NavigationLink(destination: MaintenanceView()) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: DL.Spacing.hairline) {
                            SectionLabel(text: "Next service")
                            Text(next.item.name)
                                .font(DL.Font.body.weight(.medium))
                                .foregroundStyle(DLColor.primaryText)
                            Text(next.summary)
                                .font(DL.Font.callout)
                                .foregroundStyle(DLColor.secondaryText)
                        }
                        Spacer()
                        StatusIndicator(status: next.status, showsLabel: false, size: 17)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .dlCard()
                }
                .buttonStyle(.plain)
            }
        }
    }
}
