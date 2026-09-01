import SwiftUI

/// The home screen.
///
/// It answers "is my car fine, and is there anything I should know?" before it shows
/// a single sensor value. Everything on it is either an interpretation or a number a
/// driver would actually plan around — never raw telemetry for its own sake.
struct TodayView: View {

    /// Bound from `RootView` so a widget tap can push a screen onto this tab.
    @Binding var path: [DeepLink]

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var isShowingCopilot = false

    private var formatter: DisplayFormatter { environment.formatter }
    private var drive: DriveSessionCoordinator { environment.drive }

    /// The status the whole screen is coloured by, faintly, at its top edge. Health
    /// first because it is the broader judgement; Hyperion when health has nothing.
    private var screenStatus: SemanticStatus? {
        drive.health?.overall ?? (drive.hyperion.isSilent ? nil : drive.hyperion.overall)
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DL.Spacing.large) {
                    if environment.selectedVehicle == nil {
                        DLUnavailableState(reason: .noVehicleSelected)
                            .padding(.top, DL.Spacing.section)
                    } else {
                        header.dlArrive(index: 0)
                        healthCard.dlArrive(index: 1)
                        hyperionCard.dlArrive(index: 2)
                        quickFacts.dlArrive(index: 3)
                        insightsSection.dlArrive(index: 4)
                        nextServiceSection.dlArrive(index: 5)
                    }
                }
                .dlScreenPadding()
                .padding(.vertical, DL.Spacing.medium)
            }
            .background(PanelBackground(statusTint: screenStatus.map(DLColor.status)))
            .navigationTitle("Today")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .refreshable { drive.refreshAnalysis(force: true) }
            .sheet(isPresented: $isShowingCopilot) { CopilotView() }
            .deepLinkDestinations()
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                NavigationLink(value: DeepLink.garage) {
                    Label("Garage", systemImage: "car.2")
                }
                NavigationLink(value: DeepLink.insights) {
                    Label("All insights", systemImage: "lightbulb")
                }
                NavigationLink(value: DeepLink.settings) {
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
                .dlFont(.display, weight: .semibold)
                .foregroundStyle(DLColor.primaryText)
            HStack(spacing: DL.Spacing.tight) {
                // A breathing dot while recording, a steady one while connected, none
                // otherwise: the readiness line's meaning, carried in the periphery.
                if drive.isRecording {
                    LiveDot(isLive: true, tint: DLColor.critical)
                } else if environment.obd.isConnected {
                    LiveDot(isLive: false, tint: DLColor.normal)
                }
                Text(readinessLine)
                    .font(DL.Font.callout)
                    .foregroundStyle(DLColor.secondaryText)
                    .contentTransition(.interpolate)
            }
            .animation(DL.Motion.standard, value: drive.isRecording)
        }
    }

    /// The engine intelligence, one card, opening to the full screen. Present even
    /// while silent, because a home screen that hides Hyperion until an adapter is
    /// connected never teaches the driver it exists.
    private var hyperionCard: some View {
        NavigationLink(value: DeepLink.hyperion) {
            HyperionSummaryCard(assessment: drive.hyperion)
        }
        .dlPressable()
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
            NavigationLink(value: DeepLink.vehicle) {
                HStack(alignment: .center, spacing: DL.Spacing.medium) {
                    // The ring is the headline. A 20pt symbol beside a word was correct
                    // and invisible; this is the one judgement the screen is about.
                    StatusRing(status: health.overall, size: 64, lineWidth: 6)
                    VStack(alignment: .leading, spacing: DL.Spacing.hairline) {
                        SectionLabel(text: "Vehicle")
                        Text(health.headline)
                            .dlFont(.metric, weight: .semibold)
                            .foregroundStyle(DLColor.primaryText)
                            .contentTransition(.interpolate)
                        if let explanation = healthExplanation(health) {
                            Text(explanation)
                                .font(DL.Font.caption)
                                .foregroundStyle(DLColor.secondaryText)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(DLColor.unknown)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .dlCard(tint: DLColor.status(health.overall))
            }
            .dlPressable()
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

    /// Two tiles across at accessibility text sizes leaves each about eight
    /// characters wide. One column is less pretty and actually readable.
    private var quickFactColumns: [GridItem] {
        dynamicTypeSize.isAccessibilitySize
            ? [GridItem(.flexible())]
            : [GridItem(.flexible()), GridItem(.flexible())]
    }

    /// The fuel gauge's colour follows the level: accent while comfortable, amber
    /// under a quarter, red under a tenth. Thresholds, not a smooth ramp, so the colour
    /// change is an event a driver notices rather than a drift nobody does.
    private var fuelTint: Color {
        guard let level = drive.fuelStatus.levelPercent.value else { return DLColor.unknown }
        if level < 10 { return DLColor.critical }
        if level < 25 { return DLColor.watch }
        return DLColor.accent
    }

    private var quickFacts: some View {
        LazyVGrid(columns: quickFactColumns, spacing: DL.Spacing.medium) {
            MetricView(label: "Range",
                       value: formatter.distance(kilometres: drive.fuelStatus.estimatedRangeKm.value, fractionDigits: 0),
                       unit: formatter.distanceUnitLabel,
                       provenance: drive.fuelStatus.estimatedRangeKm.provenance)
                .frame(maxWidth: .infinity, alignment: .leading)
                .dlCard()

            VStack(alignment: .leading, spacing: DL.Spacing.small) {
                MetricView(label: "Fuel",
                           value: formatter.percent(drive.fuelStatus.levelPercent.value),
                           unit: "%",
                           provenance: drive.fuelStatus.levelPercent.provenance)
                // A gauge under the number, filled from the same value, coloured by
                // how low it is. An empty track when the car does not report fuel -
                // never a bar at zero pretending to be an empty tank.
                FillBar(fraction: drive.fuelStatus.levelPercent.value.map { $0 / 100 },
                        tint: fuelTint)
            }
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
                    .dlFont(.metric)
                    .foregroundStyle(DLColor.primaryText)
                Text([formatter.duration(seconds: lastTrip.totalDurationSeconds),
                      formatter.economy(kmPerLitre: lastTrip.economyKmPerLitre).map { "\($0) \(formatter.economyUnitLabel)" }]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(DL.Font.caption)
                    .foregroundStyle(DLColor.secondaryText)
            } else {
                Text("—")
                    .dlFont(.metric)
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
                        .dlFont(.metric)
                        .foregroundStyle(DLColor.primaryText)
                }
                Text(drive.weatherChanges.first?.detail ?? weather.condition.displayName)
                    .font(DL.Font.caption)
                    .foregroundStyle(DLColor.secondaryText)
                    .lineLimit(2)
            } else {
                Text("—")
                    .dlFont(.metric)
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
                        NavigationLink("See all", value: DeepLink.insights)
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
                NavigationLink(value: DeepLink.maintenance) {
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
                    .dlCard(tint: next.status > .normal ? DLColor.status(next.status) : nil)
                }
                .dlPressable()
            }
        }
    }
}
