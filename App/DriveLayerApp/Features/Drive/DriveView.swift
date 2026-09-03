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
                    speedBlock.dlArrive(index: 0)
                    tripRow.dlArrive(index: 1)
                    destinationSection.dlArrive(index: 2)
                    contextSection.dlArrive(index: 3)
                    controls.dlArrive(index: 4)
                }
                .dlScreenPadding()
                .padding(.vertical, DL.Spacing.medium)
            }
            // The top edge takes the Hyperion status while driving, so a car whose
            // engine has moved to Watch is warmer at the top of the screen than one
            // that is fine - a cue that arrives before the driver reads anything.
            .background(PanelBackground(statusTint: drive.hyperion.isSilent ? nil : DLColor.status(drive.hyperion.overall)))
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
                        Label("Ask Harrier", systemImage: "bubble.left.and.text.bubble.right")
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
            HStack(spacing: DL.Spacing.tight) {
                // The recording state is the one thing worth animating here: a breathing
                // red dot in the periphery says "this drive is being kept" without a
                // word having to be read at speed.
                if drive.isRecording {
                    LiveDot(isLive: true, tint: DLColor.critical)
                        .transition(.scale.combined(with: .opacity))
                }
                SectionLabel(text: drive.isRecording ? "Recording" : "Speed")
                    .contentTransition(.interpolate)
            }
            .animation(DL.Motion.arrive, value: drive.isRecording)

            HStack(alignment: .firstTextBaseline, spacing: DL.Spacing.tight) {
                RollingNumber(value: formatter.speed(kmh: speedKmh), font: .hero, weight: .semibold)
                Text(formatter.speedUnitLabel)
                    .font(DL.Font.title)
                    .foregroundStyle(DLColor.secondaryText)
            }
            if speedKmh == nil {
                Text("Waiting for GPS or vehicle speed")
                    .font(DL.Font.caption)
                    .foregroundStyle(DLColor.secondaryText)
            } else {
                speedSourceLine
            }
        }
    }

    /// Which sensor the big number is coming from. OBD speed and GPS speed disagree by
    /// a few km/h routinely, and a driver who sees the number change character when the
    /// adapter drops deserves to know why.
    private var speedSourceLine: some View {
        let fromOBD = environment.obd.telemetry.value(.vehicleSpeedKmh, freshWithin: 6, now: Date()) != nil
        return Text(fromOBD ? "From the vehicle" : "From GPS")
            .font(DL.Font.caption)
            .foregroundStyle(DLColor.secondaryText)
            .contentTransition(.interpolate)
            .animation(DL.Motion.standard, value: fromOBD)
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
            // Two different quantities, and the label has to say which one this is.
            // Before a GPS fix anchors the barometer, the only figure available is the
            // change since it started - which was previously shown as "Altitude", so a
            // reading of 7 m meant "7 m since the app launched".
            altitudeMetric
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
            // Two sibling buttons, not one nested in the other's label: SwiftUI gives
            // a Button's whole label to the Button, so a "Clear" placed inside it
            // could never be tapped — every tap opened the search sheet instead.
            HStack(spacing: DL.Spacing.small) {
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
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(drive.destination == nil
                                    ? "Set a destination"
                                    : "Heading to \(drive.destination?.name ?? ""). Change destination.")

                if drive.destination != nil {
                    Button("Clear") { drive.setDestination(nil) }
                        .font(DL.Font.callout)
                        .buttonStyle(.plain)
                        .foregroundStyle(DLColor.accent)
                        .accessibilityLabel("Clear destination")
                }
            }

            if drive.destination != nil, let reason = drive.routeUnavailability {
                Text(reason.message)
                    .font(DL.Font.caption)
                    .foregroundStyle(DLColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            reachabilityLine
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

    /// Whether the tank covers the road ahead.
    ///
    /// An EV answers this continuously and a petrol car leaves it to the driver's
    /// arithmetic at 100 km/h. DriveLayer knows the route length and the estimated
    /// range, so it can do the subtraction — and says "estimated" every time, because
    /// a range figure is an inference from economy, not a reading from the tank.
    @ViewBuilder
    private var reachabilityLine: some View {
        if let verdict = drive.journeyReserve, let sentence = drive.journeySentence,
           verdict != .unknown {
            HStack(alignment: .top, spacing: DL.Spacing.small) {
                StatusIndicator(status: verdict.status, showsLabel: false, size: 15)
                Text(sentence)
                    .font(DL.Font.caption)
                    .foregroundStyle(DLColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, DL.Spacing.tight)
            .accessibilityElement(children: .combine)
        }
    }

    /// Height above sea level once that is known, and the climb so far until it is.
    @ViewBuilder
    private var altitudeMetric: some View {
        let motion = environment.motion
        if let absolute = motion.absoluteAltitudeMetres {
            MetricView(label: "Altitude",
                       value: String(Int(absolute.rounded())),
                       unit: "m",
                       provenance: .estimated)
        } else if motion.isRunning {
            let change = motion.elevationChangeMetres
            MetricView(label: "Elevation change",
                       value: (change >= 0 ? "+" : "") + String(Int(change.rounded())),
                       unit: "m",
                       provenance: .measured)
        } else if let satellite = environment.location.latest?.altitudeMetres {
            MetricView(label: "Altitude",
                       value: String(Int(satellite.rounded())),
                       unit: "m",
                       provenance: .measured)
        } else {
            MetricView(label: "Altitude", value: nil, unit: "m", provenance: .unavailable)
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
            // One 56pt target either way, the same size in both states so the driver's
            // thumb lands in the same place whether starting or stopping.
            if drive.isRecording {
                Button(role: .destructive) {
                    drive.endDriveManually()
                } label: {
                    Label("End drive", systemImage: "stop.fill")
                }
                .dlPrimaryButton(role: .destructive)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else {
                Button {
                    drive.startDriveManually()
                } label: {
                    Label("Start drive", systemImage: "play.fill")
                }
                .dlPrimaryButton()
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }

            if !environment.settings.automaticTripDetection {
                Text("Automatic trip detection is off. You can turn it on in Settings.")
                    .font(DL.Font.caption)
                    .foregroundStyle(DLColor.secondaryText)
                    .multilineTextAlignment(.center)
            }
        }
        .animation(DL.Motion.arrive, value: drive.isRecording)
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
            case .coolantTemperatureC, .intakeAirTemperatureC, .ambientAirTemperatureC,
                 .oilTemperatureC, .catalystTemperatureC:
                formatted = formatter.temperature(celsius: value)
            case .vehicleSpeedKmh:
                formatted = formatter.speed(kmh: value)
            case .controlModuleVoltageV:
                formatted = formatter.voltage(value)
            case .engineRPM:
                formatted = formatter.rpm(value)
            // Fuel trims are signed and small; a trim of -2.3% rounded to "-2" and shown
            // as a percentage lost the sign's meaning and the decimal that matters.
            case .shortTermFuelTrimPercent, .longTermFuelTrimPercent:
                formatted = String(format: "%+.1f", value)
            case .commandedEquivalenceRatio:
                formatted = String(format: "%.3f", value)
            case .massAirFlowGramsPerSecond, .fuelRateLitresPerHour:
                formatted = String(format: "%.1f", value)
            case .timingAdvanceDegrees:
                formatted = String(format: "%.1f", value)
            // Pressures and the raw bitfields were falling through to `percent`, which
            // showed manifold pressure as "101" with a % unit and a monitor-status byte as
            // a meaningless integer. Bitfields are decoded elsewhere; they are not values.
            case .fuelSystemStatusCode, .monitorStatusCode:
                return nil
            case .intakeManifoldPressureKPa, .barometricPressureKPa, .fuelRailPressureKPa:
                formatted = String(format: "%.0f", value)
            default:
                formatted = formatter.percent(value)
            }
            return Row(metric: metric, name: metric.displayName, formattedValue: formatted, unit: metric.unitLabel)
        }
    }
}
