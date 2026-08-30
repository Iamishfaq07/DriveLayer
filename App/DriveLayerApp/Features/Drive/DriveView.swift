import SwiftUI

/// Drive Mode.
///
/// One large number, four supporting ones, and whatever context actually matters
/// right now. Deliberately not twelve gauges: at speed, a screen is read in glances,
/// and a glance holds one thing. Everything else is one tap away in Telemetry.
struct DriveView: View {

    @Environment(AppEnvironment.self) private var environment
    @State private var isShowingTelemetry = false
    @State private var isShowingCopilot = false
    @State private var isChoosingDestination = false

    private var drive: DriveSessionCoordinator { environment.drive }
    private var formatter: DisplayFormatter { environment.formatter }

    private var speedKmh: Double? {
        environment.obd.telemetry.value(.vehicleSpeedKmh, freshWithin: 6, now: Date())
            ?? environment.location.latest?.speedMetresPerSecond.map(Convert.kmh(fromMetresPerSecond:))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DL.Spacing.large) {
                    speedBlock
                    tripRow
                    destinationSection
                    contextSection
                    controls
                }
                .dlScreenPadding()
                .padding(.vertical, DL.Spacing.medium)
            }
            .background(DLColor.background)
            .navigationTitle("Drive")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isShowingTelemetry = true
                    } label: {
                        Label("Telemetry", systemImage: "list.bullet.rectangle")
                    }
                    .disabled(!environment.obd.isConnected)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        isShowingCopilot = true
                    } label: {
                        Label("Ask copilot", systemImage: "bubble.left.and.text.bubble.right")
                    }
                }
            }
            .sheet(isPresented: $isShowingTelemetry) { TelemetryDetailView() }
            .sheet(isPresented: $isShowingCopilot) { CopilotView() }
            .onAppear { drive.setDriveScreenVisible(true) }
            .onDisappear { drive.setDriveScreenVisible(false) }
        }
    }

    private var speedBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: drive.isRecording ? "Recording" : "Speed")
            HStack(alignment: .firstTextBaseline, spacing: DL.Spacing.tight) {
                Text(formatter.speed(kmh: speedKmh) ?? "—")
                    .dlFont(.hero, usesMonospacedDigits: true)
                    .contentTransition(.numericText())
                    .foregroundStyle(speedKmh == nil ? DLColor.unknown : DLColor.primaryText)
                Text(formatter.speedUnitLabel)
                    .font(DL.Font.title)
                    .foregroundStyle(DLColor.secondaryText)
            }
            .animation(DL.Motion.value, value: speedKmh)
            if speedKmh == nil {
                Text("Waiting for GPS or vehicle speed")
                    .font(DL.Font.caption)
                    .foregroundStyle(DLColor.secondaryText)
            }
        }
    }

    private var tripRow: some View {
        DLAdaptiveRow {
            MetricView(label: "Distance",
                       value: formatter.distance(metres: drive.currentTrip?.distanceMetres),
                       unit: formatter.distanceUnitLabel)
                .frame(maxWidth: .infinity, alignment: .leading)
            MetricView(label: "Duration",
                       value: formatter.duration(seconds: drive.currentTrip?.totalDurationSeconds),
                       unit: nil)
                .frame(maxWidth: .infinity, alignment: .leading)
            MetricView(label: "Altitude",
                       value: environment.motion.latestAltitude.map { String(Int($0.altitudeMetres.rounded())) }
                            ?? environment.location.latest?.altitudeMetres.map { String(Int($0.rounded())) },
                       unit: "m",
                       provenance: environment.motion.latestAltitude == nil ? .measured : .estimated)
                .frame(maxWidth: .infinity, alignment: .leading)
            MetricView(label: "Range",
                       value: formatter.distance(kilometres: drive.fuelStatus.estimatedRangeKm.value, fractionDigits: 0),
                       unit: formatter.distanceUnitLabel,
                       provenance: drive.fuelStatus.estimatedRangeKm.provenance)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .dlCard()
    }

    /// Where the driver is going, and what the weather does on the way.
    ///
    /// Optional and off by default. DriveLayer is not a navigation app; it asks for a
    /// destination only because "rain in 14 km" needs to know which 14 km, and
    /// looking up a route is the one thing here that sends a location off the device.
    @ViewBuilder
    private var destinationSection: some View {
        VStack(alignment: .leading, spacing: DL.Spacing.small) {
            SectionLabel(text: "Heading to")
            Button {
                isChoosingDestination = true
            } label: {
                HStack(spacing: DL.Spacing.small) {
                    Image(systemName: drive.destination == nil ? "mappin.and.ellipse" : "location.fill")
                        .foregroundStyle(DLColor.accent)
                        .accessibilityHidden(true)
                    Text(drive.destination?.name ?? "Set a destination")
                        .font(DL.Font.body)
                        .foregroundStyle(drive.destination == nil ? DLColor.secondaryText : DLColor.primaryText)
                        .lineLimit(1)
                    Spacer()
                    if drive.destination != nil {
                        Button("Clear") { drive.setDestination(nil) }
                            .font(DL.Font.callout)
                            .buttonStyle(.plain)
                            .foregroundStyle(DLColor.accent)
                    }
                }
            }
            .buttonStyle(.plain)

            if drive.destination != nil, let reason = drive.routeUnavailability {
                Text(reason.message)
                    .font(DL.Font.caption)
                    .foregroundStyle(DLColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dlCard()
        .sheet(isPresented: $isChoosingDestination) {
            DestinationSearchView { destination in
                drive.setDestination(destination)
                isChoosingDestination = false
            }
        }
    }

    /// The part that makes this Drive Mode rather than a speedometer: at most three
    /// pieces of context, urgent first, and nothing at all when there is nothing to say.
    @ViewBuilder
    private var contextSection: some View {
        let visible = InsightEngine.forDriving(drive.insights)
        if visible.isEmpty {
            VStack(alignment: .leading, spacing: DL.Spacing.tight) {
                SectionLabel(text: "Context")
                Text(drive.isRecording
                     ? "Nothing needs your attention. DriveLayer will say something when that changes."
                     : "Start driving and DriveLayer will read the road, the weather and your car.")
                    .font(DL.Font.callout)
                    .foregroundStyle(DLColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .dlCard()
        } else {
            VStack(alignment: .leading, spacing: DL.Spacing.small) {
                SectionLabel(text: "Context")
                ForEach(visible) { insight in
                    InsightCard(insight: insight, isCompact: true)
                }
            }
        }
    }

    private var controls: some View {
        VStack(spacing: DL.Spacing.small) {
            if drive.isRecording {
                Button(role: .destructive) {
                    drive.endDriveManually()
                } label: {
                    Label("End drive", systemImage: "stop.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            } else {
                Button {
                    drive.startDriveManually()
                } label: {
                    Label("Start drive", systemImage: "play.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(DLColor.accent)
            }

            if !environment.settings.automaticTripDetection {
                Text("Automatic trip detection is off. You can turn it on in Settings.")
                    .font(DL.Font.caption)
                    .foregroundStyle(DLColor.secondaryText)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

/// The deeper telemetry view, deliberately one level down from Drive Mode.
struct TelemetryDetailView: View {

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if !environment.obd.isConnected {
                    DLUnavailableState(reason: .obdNotConnected)
                        .listRowBackground(Color.clear)
                } else {
                    Section("Live values") {
                        ForEach(readings, id: \.metric) { reading in
                            ValueOrReasonRow(label: reading.name,
                                             value: reading.formattedValue,
                                             unit: reading.unit,
                                             provenance: .measured,
                                             reason: "Not reported")
                        }
                    }
                    if !environment.obd.undecodedParameterNames.isEmpty {
                        Section("Reported but not interpreted") {
                            ForEach(environment.obd.undecodedParameterNames, id: \.self) { name in
                                Text(name)
                                    .font(DL.Font.callout)
                                    .foregroundStyle(DLColor.secondaryText)
                            }
                            Text("Your vehicle reports these, but DriveLayer has no verified way to interpret them yet, so it doesn't guess.")
                                .font(DL.Font.caption)
                                .foregroundStyle(DLColor.secondaryText)
                        }
                    }
                }
            }
            .navigationTitle("Telemetry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private struct Row {
        var metric: VehicleMetric
        var name: String
        var formattedValue: String?
        var unit: String?
    }

    private var readings: [Row] {
        let telemetry = environment.obd.telemetry
        let formatter = environment.formatter
        return VehicleMetric.allCases.compactMap { metric -> Row? in
            guard let value = telemetry.value(metric) else { return nil }
            let formatted: String?
            switch metric {
            case .coolantTemperatureC, .intakeAirTemperatureC, .ambientAirTemperatureC:
                formatted = formatter.temperature(celsius: value)
            case .vehicleSpeedKmh:
                formatted = formatter.speed(kmh: value)
            case .controlModuleVoltageV:
                formatted = formatter.voltage(value)
            case .engineRPM:
                formatted = formatter.rpm(value)
            default:
                formatted = formatter.percent(value)
            }
            return Row(metric: metric, name: metric.displayName, formattedValue: formatted, unit: metric.unitLabel)
        }
    }
}
