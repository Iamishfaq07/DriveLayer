import SwiftUI

/// The developer's window into what the app actually believes.
///
/// Built early rather than late: almost all of DriveLayer's behaviour depends on data
/// that is awkward to reproduce on demand, and being able to see the simulator's
/// state, the discovered PIDs, the learned baselines and the generated insights
/// side by side is what makes that developable without sitting in a car.
struct DebugCenterView: View {

    @Environment(AppEnvironment.self) private var environment
    @State private var simulatorState: SimulatedVehicleState?
    @State private var unsupported: [OBDPID] = []
    @State private var pendingReminders: [String] = []

    var body: some View {
        List {
            connectionSection
            simulatorSection
            capabilitySection
            liveValuesSection
            insightSection
            baselineSection
            remindersSection
            issuesSection
            storageSection
        }
        .navigationTitle("Debug Center")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
        .refreshable { await refresh() }
    }

    private var connectionSection: some View {
        Section("Connection") {
            LabeledContent("State", value: environment.obd.state.userDescription)
            LabeledContent("Source", value: sourceDescription)
            LabeledContent("Adapter", value: environment.obd.adapterIdentity ?? "—")
            LabeledContent("Protocol", value: environment.obd.protocolDescription ?? "—")
            LabeledContent("Adapter voltage",
                           value: environment.obd.adapterVoltage.value.map { String(format: "%.1f V", $0) } ?? "—")
            if let basis = environment.obd.adapterVoltage.basis {
                Text(basis).font(DL.Font.caption).foregroundStyle(DLColor.secondaryText)
            }
        }
    }

    private var sourceDescription: String {
        switch environment.obd.source {
        case let .bluetooth(_, name): return "Bluetooth — \(name)"
        case let .simulator(scenario): return "Simulator — \(OBDScenario.named(scenario).title)"
        case nil: return "None"
        }
    }

    @ViewBuilder
    private var simulatorSection: some View {
        if environment.settings.useSimulator {
            Section("Simulator") {
                let scenario = OBDScenario.named(environment.settings.simulatorScenario)
                Text(scenario.title).font(DL.Font.body.weight(.medium))
                Text(scenario.summary).font(DL.Font.callout).foregroundStyle(DLColor.secondaryText)
                Text(scenario.exercises).font(DL.Font.caption).foregroundStyle(DLColor.unknown)

                if let state = simulatorState {
                    LabeledContent("Elapsed", value: String(format: "%.0f s", state.elapsed))
                    LabeledContent("Speed", value: String(format: "%.0f km/h", state.speedKmh))
                    LabeledContent("Coolant", value: String(format: "%.1f °C", state.coolantC))
                    LabeledContent("Load", value: String(format: "%.0f %%", state.engineLoadPercent))
                    LabeledContent("Voltage", value: String(format: "%.2f V", state.controlModuleVoltage))
                    LabeledContent("Fuel level", value: String(format: "%.1f %%", state.fuelLevelPercent))
                    LabeledContent("Link", value: state.linkIsDown ? "Down" : "Up")
                }

                Picker("Scenario", selection: Binding(
                    get: { environment.settings.simulatorScenario },
                    set: { scenario in Task { await environment.useSimulator(scenario: scenario) } }
                )) {
                    ForEach(OBDScenario.all) { candidate in
                        Text(candidate.title).tag(candidate.id)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var capabilitySection: some View {
        if let capabilities = environment.obd.capabilities {
            Section("Discovered capability") {
                LabeledContent("Parameters reported", value: "\(capabilities.supportedCodes.count)")
                LabeledContent("Interpreted", value: "\(capabilities.decodableDescriptors.count)")
                LabeledContent("Stored codes", value: capabilities.storedDTCSupport.rawValue)
                LabeledContent("Pending codes", value: capabilities.pendingDTCSupport.rawValue)
                LabeledContent("Permanent codes", value: capabilities.permanentDTCSupport.rawValue)

                DisclosureGroup("Supported PIDs") {
                    Text(capabilities.supportedCodes.sorted().map { String(format: "%02X", Int($0)) }.joined(separator: "  "))
                        .font(DL.Font.caption.monospaced())
                        .foregroundStyle(DLColor.secondaryText)
                }
                if !capabilities.reportedButNotDecodable.isEmpty {
                    DisclosureGroup("Reported but not interpreted") {
                        ForEach(capabilities.reportedButNotDecodable, id: \.self) { code in
                            Text(OBDPIDCatalog.displayName(forCode: code))
                                .font(DL.Font.caption)
                        }
                    }
                }
                if !unsupported.isEmpty {
                    DisclosureGroup("Rested after failures") {
                        ForEach(unsupported, id: \.self) { pid in
                            Text(pid.description).font(DL.Font.caption.monospaced())
                        }
                    }
                }
                ForEach(capabilities.notes, id: \.self) { note in
                    Text(note).font(DL.Font.caption).foregroundStyle(DLColor.watch)
                }
            }
        }
    }

    private var liveValuesSection: some View {
        Section("Live telemetry") {
            let telemetry = environment.obd.telemetry
            if telemetry.isEmpty {
                Text("No values yet.").font(DL.Font.callout).foregroundStyle(DLColor.secondaryText)
            } else {
                ForEach(VehicleMetric.allCases, id: \.self) { metric in
                    if let entry = telemetry.entry(metric) {
                        HStack {
                            Text(metric.displayName).font(DL.Font.caption)
                            Spacer()
                            Text(String(format: "%.2f %@", entry.value, metric.unitLabel))
                                .font(DL.Font.caption.monospacedDigit())
                                .foregroundStyle(DLColor.secondaryText)
                            Text(String(format: "%.0fs", Date().timeIntervalSince(entry.timestamp)))
                                .font(DL.Font.caption)
                                .foregroundStyle(DLColor.unknown)
                        }
                    }
                }
            }
        }
    }

    private var insightSection: some View {
        Section("Generated insights") {
            if environment.drive.insights.isEmpty {
                Text("None right now.").font(DL.Font.callout).foregroundStyle(DLColor.secondaryText)
            } else {
                ForEach(environment.drive.insights) { insight in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(insight.id).font(DL.Font.caption.monospaced())
                            Spacer()
                            Text(String(format: "conf %.2f", insight.confidence))
                                .font(DL.Font.caption.monospacedDigit())
                                .foregroundStyle(DLColor.unknown)
                        }
                        Text(insight.summary).font(DL.Font.caption).foregroundStyle(DLColor.secondaryText)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var baselineSection: some View {
        if let vehicle = environment.selectedVehicle {
            let aggregates = environment.store.baselineAggregates(vehicleID: vehicle.id)
            let baselines = BaselineEngine.buildAll(from: aggregates, now: Date())
            Section("Baselines") {
                LabeledContent("Daily aggregates", value: "\(aggregates.count)")
                if baselines.isEmpty {
                    Text("Not enough history yet.").font(DL.Font.callout).foregroundStyle(DLColor.secondaryText)
                } else {
                    ForEach(baselines.keys.sorted(by: { $0.storageIdentifier < $1.storageIdentifier }), id: \.self) { key in
                        if let baseline = baselines[key] {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(key.storageIdentifier).font(DL.Font.caption.monospaced())
                                Text(String(format: "median %.2f · p10 %.2f · p90 %.2f · %d days%@",
                                            baseline.median, baseline.percentile10, baseline.percentile90,
                                            baseline.dayCount,
                                            baseline.isEstablished ? "" : " (not established)"))
                                    .font(DL.Font.caption.monospacedDigit())
                                    .foregroundStyle(DLColor.secondaryText)
                            }
                        }
                    }
                }
            }
        }
    }

    private var remindersSection: some View {
        Section("Scheduled reminders") {
            LabeledContent("Permission", value: environment.reminders.authorisation.rawValue)
            LabeledContent("Scheduled", value: "\(environment.reminders.scheduledCount)")
            if pendingReminders.isEmpty {
                Text("Nothing queued.").font(DL.Font.callout).foregroundStyle(DLColor.secondaryText)
            } else {
                ForEach(pendingReminders, id: \.self) { summary in
                    Text(summary).font(DL.Font.caption).foregroundStyle(DLColor.secondaryText)
                }
            }
        }
    }

    private var issuesSection: some View {
        Section("Recent issues") {
            if environment.obd.recentIssues.isEmpty {
                Text("None.").font(DL.Font.callout).foregroundStyle(DLColor.secondaryText)
            } else {
                ForEach(environment.obd.recentIssues, id: \.self) { issue in
                    Text(issue).font(DL.Font.caption).foregroundStyle(DLColor.secondaryText)
                }
            }
        }
    }

    private var storageSection: some View {
        Section("Storage") {
            LabeledContent("Telemetry on disk",
                           value: ByteCountFormatter.string(fromByteCount: TelemetryFileStore.shared.totalBytes(),
                                                            countStyle: .file))
            if let error = environment.store.lastError {
                Text(error).font(DL.Font.caption).foregroundStyle(DLColor.critical)
            }
        }
    }

    private func refresh() async {
        unsupported = await environment.obd.unsupportedPIDs()
        pendingReminders = await environment.reminders.pendingSummaries()
        simulatorState = nil
    }
}
