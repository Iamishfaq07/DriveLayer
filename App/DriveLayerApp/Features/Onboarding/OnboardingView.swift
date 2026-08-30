import SwiftUI

/// Six steps, and only two of them are compulsory.
///
/// The app is useful with nothing but a phone, so onboarding never blocks on an
/// adapter and never demands a permission without first saying what it buys.
struct OnboardingView: View {

    @Environment(AppEnvironment.self) private var environment
    @State private var step: Step = .welcome
    @State private var draftName = ""
    @State private var draftProfileID = VehicleProfileCatalog.harrier2026AdventureXPlusID

    enum Step: Int, CaseIterable {
        case welcome, vehicle, capabilities, permissions, adapter, ready
    }

    var body: some View {
        VStack(spacing: 0) {
            ProgressView(value: Double(step.rawValue), total: Double(Step.allCases.count - 1))
                .tint(DLColor.accent)
                .padding(.horizontal, DL.Spacing.screen)
                .padding(.top, DL.Spacing.small)

            ScrollView {
                VStack(alignment: .leading, spacing: DL.Spacing.large) {
                    switch step {
                    case .welcome: welcome
                    case .vehicle: vehicle
                    case .capabilities: capabilities
                    case .permissions: permissions
                    case .adapter: adapter
                    case .ready: ready
                    }
                }
                .dlScreenPadding()
                .padding(.vertical, DL.Spacing.section)
            }

            footer
        }
        .background(DLColor.background)
    }

    // MARK: - Steps

    private var welcome: some View {
        VStack(alignment: .leading, spacing: DL.Spacing.medium) {
            Text("DriveLayer")
                .dlFont(.hero)
                .foregroundStyle(DLColor.primaryText)
            Text("Intelligence for the car you already own.")
                .font(DL.Font.title)
                .foregroundStyle(DLColor.secondaryText)
            Text("DriveLayer reads your car, the road, the weather and your own driving history, and tells you what actually matters. It listens to your car — it never controls it.")
                .font(DL.Font.body)
                .foregroundStyle(DLColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var vehicle: some View {
        VStack(alignment: .leading, spacing: DL.Spacing.medium) {
            stepTitle("Add your vehicle", subtitle: "Everything DriveLayer learns is kept per vehicle.")
            TextField("Name it — \"Harrier\", \"the car\"", text: $draftName)
                .textFieldStyle(.roundedBorder)
            Picker("Profile", selection: $draftProfileID) {
                ForEach(VehicleProfileCatalog.all) { profile in
                    Text(profile.displayName).tag(profile.id)
                }
            }
            .pickerStyle(.menu)
            if let profile = VehicleProfileCatalog.profile(id: draftProfileID) {
                VStack(alignment: .leading, spacing: DL.Spacing.tight) {
                    Text(profile.validationTier.label)
                        .font(DL.Font.label)
                        .foregroundStyle(DLColor.accent)
                    Text(profile.validationTier.explanation)
                        .font(DL.Font.callout)
                        .foregroundStyle(DLColor.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .dlCard()
            }
        }
    }

    private var capabilities: some View {
        VStack(alignment: .leading, spacing: DL.Spacing.medium) {
            stepTitle("Three levels", subtitle: "DriveLayer is useful straight away and gets sharper as it sees more.")
            ForEach(VehicleCapabilityLevel.allCases, id: \.self) { level in
                VStack(alignment: .leading, spacing: DL.Spacing.tight) {
                    Text(level.title)
                        .font(DL.Font.body.weight(.semibold))
                        .foregroundStyle(DLColor.primaryText)
                    Text(level.summary)
                        .font(DL.Font.callout)
                        .foregroundStyle(DLColor.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .dlCard()
            }
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: DL.Spacing.medium) {
            stepTitle("Two permissions", subtitle: "Both are optional. Here's exactly what each one is for.")
            permissionCard(symbol: "location",
                           title: "Location",
                           detail: "Records drives, measures terrain and gradient, and works out where weather changes on your route. Nothing leaves your phone.") {
                Task { await environment.location.requestAuthorization() }
            }
            permissionCard(symbol: "figure.walk.motion",
                           title: "Motion",
                           detail: "Uses the barometer for accurate altitude, which is what makes gradient useful, and can notice rough road surfaces.") {
                environment.motion.start()
            }
        }
    }

    private var adapter: some View {
        VStack(alignment: .leading, spacing: DL.Spacing.medium) {
            stepTitle("Connect an adapter", subtitle: "Optional. It unlocks live engine data, but DriveLayer works without one.")
            Text("A standard Bluetooth OBD-II adapter plugs into the port under your dashboard. You can set this up later from Settings.")
                .font(DL.Font.callout)
                .foregroundStyle(DLColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            NavigationStack {
                AdapterSetupView()
            }
            .frame(height: 360)
            .clipShape(RoundedRectangle(cornerRadius: DL.Radius.card, style: .continuous))
        }
    }

    private var ready: some View {
        VStack(alignment: .leading, spacing: DL.Spacing.medium) {
            stepTitle("Ready", subtitle: "Drive as you normally would.")
            Text("DriveLayer needs a handful of drives before it knows what's normal for this car. Until then it will say what it can measure and stay quiet about the rest.")
                .font(DL.Font.body)
                .foregroundStyle(DLColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Chrome

    private func stepTitle(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: DL.Spacing.tight) {
            Text(title)
                .dlFont(.display)
                .foregroundStyle(DLColor.primaryText)
            Text(subtitle)
                .font(DL.Font.callout)
                .foregroundStyle(DLColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func permissionCard(symbol: String,
                                title: String,
                                detail: String,
                                action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: DL.Spacing.small) {
            Label(title, systemImage: symbol)
                .font(DL.Font.body.weight(.semibold))
                .foregroundStyle(DLColor.primaryText)
            Text(detail)
                .font(DL.Font.callout)
                .foregroundStyle(DLColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Button("Allow", action: action)
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dlCard()
    }

    private var footer: some View {
        HStack {
            if step != .welcome {
                Button("Back") {
                    step = Step(rawValue: step.rawValue - 1) ?? .welcome
                }
                .buttonStyle(.bordered)
            }
            Spacer()
            Button(step == .ready ? "Start driving" : "Continue") { advance() }
                .buttonStyle(.borderedProminent)
                .tint(DLColor.accent)
                .disabled(step == .vehicle && draftName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .dlScreenPadding()
        .padding(.bottom, DL.Spacing.medium)
    }

    private func advance() {
        if step == .vehicle {
            let vehicle = Vehicle(nickname: draftName.trimmingCharacters(in: .whitespaces),
                                  profileID: draftProfileID,
                                  isPrimary: true)
            environment.add(vehicle: vehicle)
        }
        if step == .ready {
            environment.settings.hasCompletedOnboarding = true
            Task { await environment.bootstrap() }
            return
        }
        step = Step(rawValue: step.rawValue + 1) ?? .ready
    }
}
