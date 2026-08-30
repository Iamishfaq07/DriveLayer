import SwiftUI

/// Adapter pairing, plus the simulator switch.
struct AdapterSetupView: View {

    @Environment(AppEnvironment.self) private var environment
    @State private var isConnecting = false

    var body: some View {
        List {
            statusSection
            if !environment.settings.useSimulator {
                discoverySection
            }
            simulatorSection
            Section {
                Text("DriveLayer only ever reads from your vehicle. It sends the standard read-only requests and nothing else — no clearing codes, no configuration, no control.")
                    .font(DL.Font.caption)
                    .foregroundStyle(DLColor.secondaryText)
            }
        }
        .navigationTitle("Adapter")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if !environment.settings.useSimulator { environment.scanner.start() } }
        .onDisappear { environment.scanner.stop() }
    }

    private var statusSection: some View {
        Section("Status") {
            HStack {
                Text("Connection")
                Spacer()
                Text(environment.obd.state.userDescription)
                    .font(DL.Font.callout)
                    .foregroundStyle(environment.obd.isConnected ? DLColor.normal : DLColor.secondaryText)
                    .multilineTextAlignment(.trailing)
            }
            if let identity = environment.obd.adapterIdentity {
                HStack {
                    Text("Adapter")
                    Spacer()
                    Text(identity).font(DL.Font.caption).foregroundStyle(DLColor.secondaryText)
                }
            }
            if let protocolDescription = environment.obd.protocolDescription {
                HStack {
                    Text("Protocol")
                    Spacer()
                    Text(protocolDescription).font(DL.Font.caption).foregroundStyle(DLColor.secondaryText)
                }
            }
            if environment.obd.isConnected {
                Button(role: .destructive) {
                    Task { await environment.disconnectAdapter() }
                } label: {
                    Text("Disconnect")
                }
            }
        }
    }

    private var discoverySection: some View {
        Section("Nearby adapters") {
            if let message = environment.scanner.authorisationMessage {
                Text(message)
                    .font(DL.Font.callout)
                    .foregroundStyle(DLColor.watch)
            }
            if environment.scanner.discoveries.isEmpty {
                HStack(spacing: DL.Spacing.small) {
                    ProgressView()
                    Text("Looking for adapters. Make sure yours is plugged in and the ignition is on.")
                        .font(DL.Font.callout)
                        .foregroundStyle(DLColor.secondaryText)
                }
            } else {
                ForEach(environment.scanner.discoveries) { discovery in
                    Button {
                        connect(to: discovery)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(discovery.name)
                                    .foregroundStyle(DLColor.primaryText)
                                Text("Signal \(discovery.signalStrength) dBm")
                                    .font(DL.Font.caption)
                                    .foregroundStyle(DLColor.secondaryText)
                            }
                            Spacer()
                            if isConnecting {
                                ProgressView()
                            } else {
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(DLColor.unknown)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var simulatorSection: some View {
        @Bindable var settings = environment.settings
        return Section {
            Toggle("Use the simulator", isOn: $settings.useSimulator)
                .onChange(of: settings.useSimulator) { _, isOn in
                    Task {
                        if isOn {
                            await environment.useSimulator(scenario: settings.simulatorScenario)
                        } else {
                            await environment.disconnectAdapter()
                        }
                    }
                }
            if settings.useSimulator {
                Picker("Scenario", selection: $settings.simulatorScenario) {
                    ForEach(OBDScenario.all) { scenario in
                        Text(scenario.title).tag(scenario.id)
                    }
                }
                .onChange(of: settings.simulatorScenario) { _, scenario in
                    Task { await environment.useSimulator(scenario: scenario) }
                }
                Text(OBDScenario.named(settings.simulatorScenario).summary)
                    .font(DL.Font.caption)
                    .foregroundStyle(DLColor.secondaryText)
            }
        } header: {
            Text("Development")
        } footer: {
            Text("The simulator produces a synthetic vehicle that speaks the same protocol as a real adapter. Everything it shows is simulated, and it is labelled as such throughout the app.")
        }
    }

    private func connect(to discovery: BluetoothAdapterScanner.Discovery) {
        isConnecting = true
        Task {
            await environment.connect(toAdapter: discovery.id, name: discovery.name)
            isConnecting = false
        }
    }
}
