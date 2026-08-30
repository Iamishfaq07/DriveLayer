import SwiftUI

/// The Vehicle tab. Owns the navigation container.
///
/// The path is bound from `RootView` so a deep link arriving from a widget can push
/// the glovebox or the maintenance list without this view knowing where it came from.
struct VehicleView: View {
    @Binding var path: [DeepLink]

    var body: some View {
        NavigationStack(path: $path) {
            VehicleContentView()
                .deepLinkDestinations()
        }
    }
}

/// Vehicle health, expressed as systems rather than sensors.
///
/// Split from `VehicleView` so it can also be pushed from Today without nesting one
/// navigation container inside another.
struct VehicleContentView: View {

    @Environment(AppEnvironment.self) private var environment

    private var drive: DriveSessionCoordinator { environment.drive }

    var body: some View {
        List {
            if environment.selectedVehicle == nil {
                DLUnavailableState(reason: .noVehicleSelected)
                    .listRowBackground(Color.clear)
            } else {
                headlineSection
                systemsSection
                connectionSection
                manageSection
            }
        }
        .navigationTitle("Vehicle")
        .refreshable { drive.refreshAnalysis(force: true) }
    }

    @ViewBuilder
    private var headlineSection: some View {
        if let health = drive.health {
            Section {
                VStack(alignment: .leading, spacing: DL.Spacing.small) {
                    HStack(spacing: DL.Spacing.small) {
                        StatusIndicator(status: health.overall, showsLabel: false, size: 22)
                        Text(health.headline)
                            .dlFont(.display)
                            .foregroundStyle(DLColor.primaryText)
                    }
                    if health.isLimitedByMissingData {
                        Text("Some systems can't be assessed right now, so this is a partial picture.")
                            .font(DL.Font.callout)
                            .foregroundStyle(DLColor.secondaryText)
                    }
                }
                .padding(.vertical, DL.Spacing.tight)
            }
        }
    }

    @ViewBuilder
    private var systemsSection: some View {
        if let health = drive.health {
            Section("Systems") {
                ForEach(health.systems) { system in
                    NavigationLink(destination: VehicleSystemDetailView(system: system)) {
                        SystemRow(system: system)
                    }
                }
            }
        }
    }

    private var connectionSection: some View {
        Section("Connection") {
            HStack {
                Text("Adapter")
                Spacer()
                Text(environment.obd.state.userDescription)
                    .font(DL.Font.callout)
                    .foregroundStyle(environment.obd.isConnected ? DLColor.normal : DLColor.secondaryText)
            }
            if let capabilities = environment.obd.capabilities {
                HStack {
                    Text("Parameters reported")
                    Spacer()
                    Text("\(capabilities.supportedCodes.count)")
                        .foregroundStyle(DLColor.secondaryText)
                }
                HStack {
                    Text("Interpreted by DriveLayer")
                    Spacer()
                    Text("\(capabilities.decodableDescriptors.count)")
                        .foregroundStyle(DLColor.secondaryText)
                }
            }
            if let profile = environment.profile {
                HStack {
                    Text("Profile")
                    Spacer()
                    Text("\(profile.displayName) · \(profile.validationTier.label)")
                        .font(DL.Font.callout)
                        .foregroundStyle(DLColor.secondaryText)
                }
            }
            NavigationLink("Adapter setup", destination: AdapterSetupView())
        }
    }

    private var manageSection: some View {
        Section("Manage") {
            // Value-based links, so tapping a row and following a widget end up on
            // the same screen by the same route.
            NavigationLink(value: DeepLink.fuel) { Label("Fuel", systemImage: "fuelpump") }
            NavigationLink(value: DeepLink.maintenance) { Label("Maintenance", systemImage: "wrench.and.screwdriver") }
            NavigationLink(value: DeepLink.documents) { Label("Glovebox", systemImage: "folder") }
            NavigationLink(value: DeepLink.garage) { Label("Garage", systemImage: "car.2") }
            NavigationLink(value: DeepLink.settings) { Label("Settings", systemImage: "gearshape") }
        }
    }
}

/// One system, expanded: what DriveLayer measured, and what it means.
struct VehicleSystemDetailView: View {

    let system: VehicleHealthSystem
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: DL.Spacing.small) {
                    StatusIndicator(status: system.status)
                    Text(system.headline)
                        .font(DL.Font.title)
                        .foregroundStyle(DLColor.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail = system.detail {
                        Text(detail)
                            .font(DL.Font.callout)
                            .foregroundStyle(DLColor.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, DL.Spacing.tight)
            }

            if let reason = system.unavailability {
                Section {
                    DLUnavailableState(reason: reason)
                        .listRowBackground(Color.clear)
                }
            }

            if !system.dataPoints.isEmpty {
                Section("What this is based on") {
                    ForEach(system.dataPoints) { datum in
                        ValueOrReasonRow(label: datum.label,
                                         value: datum.formattedValue,
                                         provenance: datum.provenance)
                    }
                }
            }

            if system.kind == .diagnostics, !environment.obd.troubleCodes.isEmpty {
                Section("Trouble codes") {
                    ForEach(environment.obd.troubleCodes) { code in
                        NavigationLink(destination: TroubleCodeDetailView(code: code)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(code.code)
                                    .font(DL.Font.body.weight(.medium).monospaced())
                                Text(DTCCatalog.explanation(for: code.code).standardDefinition)
                                    .font(DL.Font.caption)
                                    .foregroundStyle(DLColor.secondaryText)
                            }
                        }
                    }
                    Text("DriveLayer reads codes. It never clears them — clearing a code erases the evidence a workshop needs and doesn't fix anything.")
                        .font(DL.Font.caption)
                        .foregroundStyle(DLColor.secondaryText)
                }
            }

            if system.kind == .dieselUsage, let assessment = environment.drive.dieselAssessment {
                dieselSection(assessment)
            }
        }
        .navigationTitle(system.kind.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func dieselSection(_ assessment: DieselUsageAssessment) -> some View {
        if let recommendation = assessment.recommendation {
            Section("Suggestion") {
                Text(recommendation)
                    .font(DL.Font.callout)
                    .foregroundStyle(DLColor.primaryText)
            }
        }
        Section("Particulate filter data") {
            ValueOrReasonRow(label: "Soot load",
                             value: assessment.dpf.sootLoadPercent.value.map { String(format: "%.0f", $0) },
                             unit: "%",
                             provenance: assessment.dpf.sootLoadPercent.provenance,
                             reason: "Unavailable")
            ValueOrReasonRow(label: "Distance since regeneration",
                             value: assessment.dpf.distanceSinceRegenerationKm.value.map { String(format: "%.0f", $0) },
                             unit: "km",
                             provenance: assessment.dpf.distanceSinceRegenerationKm.provenance,
                             reason: "Unavailable")
            Text(DPFTelemetry.standardBasis)
                .font(DL.Font.caption)
                .foregroundStyle(DLColor.secondaryText)
        }
    }
}

/// A trouble code, explained without pretending to name the failed part.
struct TroubleCodeDetailView: View {

    let code: DiagnosticTroubleCode

    private var explanation: DTCExplanation { DTCCatalog.explanation(for: code.code) }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: DL.Spacing.tight) {
                    Text(code.code)
                        .dlFont(.display, usesMonospacedDigits: true)
                        .foregroundStyle(DLColor.primaryText)
                    Text(explanation.standardDefinition)
                        .font(DL.Font.body)
                        .foregroundStyle(DLColor.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: DL.Spacing.tight) {
                        StatusIndicator(status: explanation.seriousness.status, showsLabel: false, size: 14)
                        Text(explanation.seriousness.label)
                            .font(DL.Font.caption)
                            .foregroundStyle(DLColor.secondaryText)
                        Text("·")
                            .foregroundStyle(DLColor.unknown)
                        Text(code.status.displayName)
                            .font(DL.Font.caption)
                            .foregroundStyle(DLColor.secondaryText)
                    }
                }
                .padding(.vertical, DL.Spacing.tight)
            }

            Section("What it means") {
                Text(explanation.plainLanguage)
                    .font(DL.Font.callout)
                Text(code.status.explanation)
                    .font(DL.Font.caption)
                    .foregroundStyle(DLColor.secondaryText)
            }

            if !explanation.commonSymptoms.isEmpty {
                Section("Common symptoms") {
                    ForEach(explanation.commonSymptoms, id: \.self) { Text($0).font(DL.Font.callout) }
                }
            }

            if !explanation.possibleCauses.isEmpty {
                Section("Worth checking") {
                    ForEach(explanation.possibleCauses, id: \.self) { Text($0).font(DL.Font.callout) }
                    Text("A trouble code describes what the vehicle observed, not which part has failed. These are places to look, not a diagnosis.")
                        .font(DL.Font.caption)
                        .foregroundStyle(DLColor.secondaryText)
                }
            }

            Section("Driving") {
                Text(explanation.drivingGuidance)
                    .font(DL.Font.callout)
            }

            Section {
                HStack {
                    Text("Source")
                    Spacer()
                    Text(explanation.source)
                        .font(DL.Font.caption)
                        .foregroundStyle(DLColor.secondaryText)
                }
            }
        }
        .navigationTitle(code.code)
        .navigationBarTitleDisplayMode(.inline)
    }
}
