import SwiftUI

/// The copilot conversation.
///
/// Answers come from `LocalCopilot`: on-device, deterministic, and unable to invent a
/// sensor reading. Every sentence carries a badge saying whether it is a measurement,
/// an estimate, an inference or general information — which is the whole point.
struct CopilotView: View {

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var question = ""
    @State private var exchanges: [Exchange] = []

    struct Exchange: Identifiable {
        let id = UUID()
        var question: String
        var answer: CopilotAnswer
    }

    @FocusState private var isComposing: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: DL.Spacing.medium) {
                            if exchanges.isEmpty { suggestions }
                            ForEach(exchanges) { exchange in
                                ExchangeView(exchange: exchange)
                                    .id(exchange.id)
                                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                                            removal: .opacity))
                            }
                        }
                        .dlScreenPadding()
                        .padding(.vertical, DL.Spacing.medium)
                        // An anchor below the last answer, so the scroll lands with the
                        // answer's bottom edge just above the input rather than its top
                        // edge under the navigation bar.
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    // The answer used to appear below the fold with nothing to say it
                    // had. Scrolling to it is the difference between a conversation and
                    // a form that quietly grew a row.
                    .onChange(of: exchanges.count) { _, _ in
                        withAnimation(DL.Motion.arrive) { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                }
                inputBar
            }
            .background(PanelBackground())
            .navigationTitle("Ask Harrier")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: DL.Spacing.small) {
            VStack(alignment: .leading, spacing: DL.Spacing.tight) {
                Text("Ask about your Harrier")
                    .dlFont(.display, weight: .semibold)
                    .foregroundStyle(DLColor.primaryText)
                Text("Answers come from what DriveLayer has actually recorded. When it doesn't know something, it says so.")
                    .font(DL.Font.callout)
                    .foregroundStyle(DLColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, DL.Spacing.small)
            .dlArrive(index: 0)

            ForEach(Array(LocalCopilot.exampleQuestions.enumerated()), id: \.element) { index, example in
                Button {
                    ask(example)
                } label: {
                    HStack(spacing: DL.Spacing.small) {
                        Image(systemName: "bubble.left")
                            .font(.callout)
                            .foregroundStyle(DLColor.accent)
                            .accessibilityHidden(true)
                        Text(example)
                            .font(DL.Font.body)
                            .foregroundStyle(DLColor.primaryText)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(DLColor.unknown)
                            .accessibilityHidden(true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .dlCard(padding: DL.Spacing.small + 2)
                }
                .dlPressable()
                .dlArrive(index: index + 1)
            }
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: DL.Spacing.small) {
            TextField("Ask about your Harrier", text: $question, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...3)
                .focused($isComposing)
                .padding(.horizontal, DL.Spacing.medium)
                .padding(.vertical, DL.Spacing.small)
                .background(DLColor.surfaceRaised, in: Capsule())
                .overlay(
                    Capsule().strokeBorder(isComposing ? DLColor.accent.opacity(0.6) : .clear, lineWidth: 1)
                )
                .animation(DL.Motion.quick, value: isComposing)
                .onSubmit { ask(question) }
            Button {
                ask(question)
            } label: {
                Image(systemName: "arrow.up")
                    .font(.body.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(canSend ? DLColor.accent : DLColor.unknown, in: Circle())
                    .contentTransition(.symbolEffect(.replace))
            }
            .disabled(!canSend)
            .animation(DL.Motion.quick, value: canSend)
            .sensoryFeedback(.impact(weight: .light), trigger: exchanges.count)
            .accessibilityLabel("Ask")
        }
        .padding(.horizontal, DL.Spacing.medium)
        .padding(.vertical, DL.Spacing.small)
        .background(
            // The bar sits on the same material as a card, edge included, so the
            // bottom of the screen has a floor rather than a colour change.
            Rectangle()
                .fill(DLColor.surface)
                .overlay(alignment: .top) { Divider().opacity(DL.Opacity.separator) }
                .ignoresSafeArea(edges: .bottom)
        )
    }

    private var canSend: Bool { !question.trimmingCharacters(in: .whitespaces).isEmpty }

    private func ask(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let snapshot = environment.drive.copilotSnapshot()
        let answer = LocalCopilot.respond(to: trimmed, snapshot: snapshot)
        withAnimation(DL.Motion.arrive) {
            exchanges.append(Exchange(question: trimmed, answer: answer))
        }
        question = ""
    }
}

private struct ExchangeView: View {
    let exchange: CopilotView.Exchange

    var body: some View {
        VStack(alignment: .leading, spacing: DL.Spacing.small) {
            Text(exchange.question)
                .font(DL.Font.body.weight(.medium))
                .foregroundStyle(DLColor.primaryText)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .multilineTextAlignment(.trailing)

            VStack(alignment: .leading, spacing: DL.Spacing.small) {
                ForEach(Array(exchange.answer.statements.enumerated()), id: \.offset) { _, statement in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(statement.text)
                            .font(DL.Font.body)
                            .foregroundStyle(DLColor.primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        ClaimBadge(claim: statement.claim)
                    }
                }
                if let limitation = exchange.answer.limitationNote {
                    Text(limitation)
                        .font(DL.Font.caption)
                        .foregroundStyle(DLColor.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .dlCard()
        }
    }
}

/// The badge that keeps an inference from reading like a measurement.
private struct ClaimBadge: View {
    let claim: ClaimType

    var body: some View {
        Text(claim.label.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.6)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.16), in: Capsule())
            .foregroundStyle(tint)
    }

    private var tint: Color {
        switch claim {
        case .fact: return DLColor.normal
        case .estimate: return DLColor.accent
        case .inference: return DLColor.watch
        case .generalInformation: return DLColor.unknown
        }
    }
}
