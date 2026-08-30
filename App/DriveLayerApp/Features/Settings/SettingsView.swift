import SwiftUI

struct SettingsView: View {

    @Environment(AppEnvironment.self) private var environment
    @State private var isConfirmingDeleteAll = false
    @State private var exportURL: URL?
    @State private var exportError: String?

    var body: some View {
        @Bindable var settings = environment.settings

        List {
            Section("Units") {
                Picker("Units", selection: $settings.unitSystem) {
                    Text("Metric").tag(UnitSystem.metric)
                    Text("Imperial").tag(UnitSystem.imperial)
                }
                Picker("Fuel economy", selection: $settings.economyUnit) {
                    ForEach(EconomyUnit.allCases, id: \.self) { unit in
                        Text(economyLabel(unit)).tag(unit)
                    }
                }
            }

            Section {
                Toggle("Record drives automatically", isOn: $settings.automaticTripDetection)
                Toggle("Live Activity while driving", isOn: $settings.liveActivitiesEnabled)
                Toggle("Detect road surface events", isOn: $settings.roadImpactDetectionEnabled)
            } header: {
                Text("Driving")
            } footer: {
                Text("Automatic recording needs background location, and iOS will ask you for it. Without it, drives can still be started from the Drive tab.")
            }

            Section("Connection") {
                NavigationLink(destination: AdapterSetupView()) {
                    HStack {
                        Label("OBD adapter", systemImage: "cable.connector")
                        Spacer()
                        Text(environment.obd.isConnected ? "Connected" : "Not connected")
                            .font(DL.Font.caption)
                            .foregroundStyle(DLColor.secondaryText)
                    }
                }
            }

            privacySection
            dataSection

            Section("About") {
                NavigationLink(destination: CapabilityLevelsView()) {
                    Label("What DriveLayer can see", systemImage: "info.circle")
                }
                NavigationLink(destination: DebugCenterView()) {
                    Label("Debug Center", systemImage: "hammer")
                }
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete all DriveLayer data?",
                            isPresented: $isConfirmingDeleteAll,
                            titleVisibility: .visible) {
            Button("Delete everything", role: .destructive) {
                environment.store.deleteEverything()
                environment.reloadVehicles()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every vehicle, drive, baseline, fuel entry, document and telemetry file is removed from this device. It cannot be undone.")
        }
        .alert("Export failed",
               isPresented: Binding(get: { exportError != nil },
                                    set: { if !$0 { exportError = nil } })) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    private var privacySection: some View {
        @Bindable var settings = environment.settings
        return Section {
            Picker("Keep engine history for", selection: $settings.telemetryRetentionDays) {
                ForEach(AppSettings.retentionChoices, id: \.self) { days in
                    Text("\(days) days").tag(days)
                }
            }
            .onChange(of: settings.telemetryRetentionDays) { _, _ in
                environment.applyRetentionPolicy()
            }
        } header: {
            Text("Privacy")
        } footer: {
            Text("DriveLayer keeps your data on this device. Nothing is uploaded, nothing is sold, and there is no account. Location is used to record drives and read terrain; documents are stored with full file protection; tokens, coordinates and document numbers are never written to logs.")
        }
    }

    private var dataSection: some View {
        Section("Your data") {
            Button {
                export()
            } label: {
                Label("Export this vehicle's data", systemImage: "square.and.arrow.up")
            }
            .disabled(environment.selectedVehicle == nil)

            if let exportURL {
                ShareLink(item: exportURL) {
                    Label("Share export", systemImage: "square.and.arrow.up.on.square")
                }
            }

            HStack {
                Text("Telemetry on disk")
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: TelemetryFileStore.shared.totalBytes(), countStyle: .file))
                    .font(DL.Font.caption.monospacedDigit())
                    .foregroundStyle(DLColor.secondaryText)
            }

            Button(role: .destructive) {
                isConfirmingDeleteAll = true
            } label: {
                Label("Delete all data", systemImage: "trash")
            }
        }
    }

    private func economyLabel(_ unit: EconomyUnit) -> String {
        switch unit {
        case .kilometresPerLitre: return "Kilometres per litre"
        case .litresPer100km: return "Litres per 100 km"
        case .milesPerGallonUS: return "Miles per gallon (US)"
        case .milesPerGallonUK: return "Miles per gallon (UK)"
        }
    }

    private func export() {
        guard let vehicle = environment.selectedVehicle else { return }
        do {
            let data = try environment.store.exportBundle(vehicleID: vehicle.id)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("DriveLayer-\(vehicle.nickname).json")
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            exportURL = url
        } catch {
            exportError = error.localizedDescription
        }
    }
}

/// The three capability levels, explained where a driver can find them again.
struct CapabilityLevelsView: View {

    @Environment(AppEnvironment.self) private var environment

    private var current: VehicleCapabilityLevel {
        VehicleCapabilityLevel.current(profile: environment.profile,
                                       isAdapterConnected: environment.obd.isConnected)
    }

    var body: some View {
        List {
            ForEach(VehicleCapabilityLevel.allCases, id: \.self) { level in
                Section {
                    VStack(alignment: .leading, spacing: DL.Spacing.tight) {
                        HStack {
                            Text(level.title)
                                .font(DL.Font.title)
                            Spacer()
                            if level == current {
                                Text("Current")
                                    .font(DL.Font.caption.weight(.semibold))
                                    .foregroundStyle(DLColor.accent)
                            } else if level > current {
                                Text("Not available")
                                    .font(DL.Font.caption)
                                    .foregroundStyle(DLColor.unknown)
                            }
                        }
                        Text(level.summary)
                            .font(DL.Font.callout)
                            .foregroundStyle(DLColor.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, DL.Spacing.tight)
                }
            }
            Section {
                Text("Enhanced vehicle data needs manufacturer-specific requests that have been verified on your exact model. DriveLayer does not ship guessed ones, so no vehicle offers this yet.")
                    .font(DL.Font.caption)
                    .foregroundStyle(DLColor.secondaryText)
            }
        }
        .navigationTitle("What DriveLayer can see")
        .navigationBarTitleDisplayMode(.inline)
    }
}
