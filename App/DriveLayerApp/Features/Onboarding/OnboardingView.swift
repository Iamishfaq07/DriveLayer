import SwiftUI

/// Six steps, and only two of them are compulsory.
///
/// The app is useful with nothing but a phone, so onboarding never blocks on an
/// adapter and never demands a permission without first saying what it buys.
struct OnboardingView: View {

    @Environment(AppEnvironment.self) private var environment
    @State private var step: Step = .welcome
    @State private var draftName = ""
    @State private var draftProfileID = SupportedVehicles.defaultProfileID

    enum Step: Int, CaseIterable {
        case welcome, vehicle, capabilities, permissions, adapter, ready
    }

    /// Which way the last step change went, so the transition slides the right way:
    /// forward content enters from the right, going back it enters from the left.
    @State private var isAdvancing = true

    var body: some View {
        VStack(spacing: 0) {
            // Six small segments rather than one bar: the driver can see how many
            // steps there are and which one they are on, which a continuous bar hides.
            HStack(spacing: DL.Spacing.tight) {
                ForEach(Step.allCases, id: \.rawValue) { candidate in
                    Capsule()
                        .fill(candidate.rawValue <= step.rawValue ? DLColor.accent : DLColor.primaryText.opacity(DL.Opacity.fill))
                        .frame(height: 3)
                }
            }
            .animation(DL.Motion.standard, value: step)
            .padding(.horizontal, DL.Spacing.screen)
            .padding(.top, DL.Spacing.small)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Step \(step.rawValue + 1) of \(Step.allCases.count)"))

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
                // Each step is its own identity, so changing step replaces the content
                // with a slide rather than mutating it in place.
                .id(step)
                .transition(.asymmetric(
                    insertion: .move(edge: isAdvancing ? .trailing : .leading).combined(with: .opacity),
                    removal: .move(edge: isAdvancing ? .leading : .trailing).combined(with: .opacity)))
            }
            .animation(DL.Motion.arrive, value: step)

            footer
        }
        .background(PanelBackground())
    }

    // MARK: - Steps

    private var welcome: some View {
        VStack(alignment: .leading, spacing: DL.Spacing.medium) {
            // The mark, the same road-to-horizon as the app icon, so the first screen
            // and the home screen are visibly the same thing. Drawn rather than an
            // image: it scales to any size and takes the current appearance.
            RoadMark()
                .frame(width: 96, height: 96)
                .dlArrive(index: 0)
            Text("DriveLayer")
                .dlFont(.hero, weight: .bold)
                .foregroundStyle(DLColor.primaryText)
                .dlArrive(index: 1)
            Text("Intelligence for the car you already own.")
                .font(DL.Font.title)
                .foregroundStyle(DLColor.secondaryText)
                .dlArrive(index: 2)
            Text("DriveLayer reads your car, the road, the weather and your own driving history, and tells you what actually matters. It listens to your car — it never controls it.")
                .font(DL.Font.body)
                .foregroundStyle(DLColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .dlArrive(index: 3)
        }
    }

    private var vehicle: some View {
        VStack(alignment: .leading, spacing: DL.Spacing.medium) {
            stepTitle("Your vehicle", subtitle: "DriveLayer is set up for one car for now — this one.")
            TextField("Name it — \"Harrier\", \"the car\"", text: $draftName)
                .textFieldStyle(.roundedBorder)
            // With one supported car there is nothing to choose, so the step states
            // which vehicle DriveLayer is set up for instead of asking.
            if let only = SupportedVehicles.only {
                HStack(spacing: DL.Spacing.tight) {
                    Image(systemName: "car")
                        .foregroundStyle(DLColor.secondaryText)
                        .accessibilityHidden(true)
                    Text(only.displayName)
                        .font(DL.Font.body.weight(.medium))
                        .foregroundStyle(DLColor.primaryText)
                }
            } else {
                Picker("Profile", selection: $draftProfileID) {
                    ForEach(SupportedVehicles.offered) { profile in
                        Text(profile.displayName).tag(profile.id)
                    }
                }
                .pickerStyle(.menu)
            }
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
        VStack(spacing: DL.Spacing.small) {
            Button {
                advance()
            } label: {
                Text(step == .ready ? "Start driving" : "Continue")
                    .contentTransition(.interpolate)
            }
            .dlPrimaryButton()
            .disabled(step == .vehicle && draftName.trimmingCharacters(in: .whitespaces).isEmpty)
            .opacity(step == .vehicle && draftName.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)

            // Back is a text button beneath, not a peer of Continue. The forward action
            // is the one a new user wants; making both the same weight made people
            // hesitate over which was which.
            Button("Back") {
                isAdvancing = false
                step = Step(rawValue: step.rawValue - 1) ?? .welcome
            }
            .font(DL.Font.callout)
            .foregroundStyle(DLColor.secondaryText)
            .opacity(step == .welcome ? 0 : 1)
            .disabled(step == .welcome)
            .frame(minHeight: 32)
        }
        .animation(DL.Motion.standard, value: step)
        .dlScreenPadding()
        .padding(.bottom, DL.Spacing.medium)
    }

    private func advance() {
        isAdvancing = true
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
