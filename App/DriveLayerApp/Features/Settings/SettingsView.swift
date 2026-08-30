import SwiftUI

struct SettingsView: View {

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.openURL) private var openURL
    @State private var isConfirmingDeleteAll = false
    @State private var isConfirmingResetLearning = false
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
                    .onChange(of: settings.automaticTripDetection) { _, isOn in
                        // Asking iOS is the point. This used to set a boolean and
                        // request nothing, so the switch could sit in the on position
                        // while iOS was refusing the permission the feature needs.
                        guard isOn else { return }
                        environment.location.requestAlwaysAuthorization()
                    }
                automaticDetectionStatusRows
                Toggle("Live Activity while driving", isOn: $settings.liveActivitiesEnabled)
                Toggle("Detect road surface events", isOn: $settings.roadImpactDetectionEnabled)
            } header: {
                Text("Driving")
            } footer: {
                Text("Automatic recording needs \"Always\" location access. Drives can always be started by hand from the Drive tab, which needs no background permission.")
            }

            Section {
                Toggle("Remind me about expiry and service", isOn: $settings.remindersEnabled)
                    .onChange(of: settings.remindersEnabled) { _, isOn in
                        Task {
                            if isOn { await environment.reminders.requestAuthorisation() }
                            environment.drive.refreshAnalysis(force: true)
                        }
                    }
                if settings.remindersEnabled, environment.reminders.authorisation == .denied {
                    Text("Notifications are turned off for DriveLayer in iOS Settings, so reminders can't be delivered.")
                        .font(DL.Font.caption)
                        .foregroundStyle(DLColor.watch)
                }
            } header: {
                Text("Reminders")
            } footer: {
                Text("DriveLayer reminds you 30 days, 7 days and on the day before a document expires, and a week before a dated service is due. Reminders never include a policy or registration number — a lock-screen banner is visible to whoever is holding the phone.")
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
                // Storage is only part of deleting. See PrivacyDeletion.
                Task { await PrivacyDeletion.deleteEverything(in: environment) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every vehicle, drive, baseline, fuel entry, document and telemetry file is removed from this device, the widgets are cleared and pending reminders are cancelled. It cannot be undone.")
        }
        .confirmationDialog("Reset what DriveLayer has learned?",
                            isPresented: $isConfirmingResetLearning,
                            titleVisibility: .visible) {
            Button("Reset learning", role: .destructive) {
                environment.resetLearnedBaselines()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your drives, fuel entries and documents are kept. Only the baselines DriveLayer learned about how this car normally behaves are discarded, and it will start learning again from your next drive.")
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
            Picker("Keep engine samples for", selection: $settings.telemetryRetentionDays) {
                ForEach(AppSettings.retentionChoices, id: \.self) { days in
                    Text(days == 0 ? "Keep everything" : "\(days) days").tag(days)
                }
            }
            .onChange(of: settings.telemetryRetentionDays) { _, _ in
                environment.applyRetentionPolicy()
            }
            Text("This is the raw engine data recorded during drives, which is most of what DriveLayer uses disk for. Your drives, fuel entries, documents and everything DriveLayer has learned about the car are kept regardless.")
                .font(DL.Font.caption)
                .foregroundStyle(DLColor.secondaryText)

            Button(role: .destructive) {
                isConfirmingResetLearning = true
            } label: {
                Label("Reset learned baselines", systemImage: "arrow.counterclockwise")
            }
            .disabled(environment.selectedVehicle == nil)
        } header: {
            Text("Privacy")
        } footer: {
            Text("DriveLayer keeps your data on this device. Nothing is uploaded, nothing is sold, and there is no account. Location is used to record drives and read terrain; documents are stored with full file protection; tokens, coordinates and document numbers are never written to logs.")
        }
    }

    /// What automatic detection is actually doing, shown only when it differs from
    /// what the switch above implies.
    @ViewBuilder
    private var automaticDetectionStatusRows: some View {
        let status = environment.drive.automaticDetectionStatus
        if status != .off {
            HStack {
                Text("Automatic detection")
                    .font(DL.Font.callout)
                Spacer()
                Text(status.summary)
                    .font(DL.Font.caption)
                    .foregroundStyle(status.detectsInBackground ? DLColor.normal : DLColor.watch)
            }
            if let explanation = status.explanation {
                Text(explanation)
                    .font(DL.Font.caption)
                    .foregroundStyle(DLColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if status.needsSettingsApp, let url = URL(string: "app-settings:") {
                Button("Open Settings") { openURL(url) }
                    .font(DL.Font.callout)
            }
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
