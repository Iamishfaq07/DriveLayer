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

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DL.Spacing.medium) {
                        if exchanges.isEmpty { suggestions }
                        ForEach(exchanges) { exchange in
                            ExchangeView(exchange: exchange)
                        }
                    }
                    .dlScreenPadding()
                    .padding(.vertical, DL.Spacing.medium)
                }
                inputBar
            }
            .background(DLColor.background)
            .navigationTitle("Copilot")
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
            Text("Ask about your car")
                .font(DL.Font.title)
                .foregroundStyle(DLColor.primaryText)
            Text("Answers come from what DriveLayer has actually recorded. When it doesn't know something, it says so.")
                .font(DL.Font.callout)
                .foregroundStyle(DLColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(LocalCopilot.exampleQuestions, id: \.self) { example in
                Button {
                    ask(example)
                } label: {
                    HStack {
                        Text(example)
                            .font(DL.Font.callout)
                            .multilineTextAlignment(.leading)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.caption)
                            .foregroundStyle(DLColor.unknown)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .dlCard(padding: DL.Spacing.small)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var inputBar: some View {
        HStack(spacing: DL.Spacing.small) {
            TextField("Ask about your car", text: $question, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...3)
                .padding(.horizontal, DL.Spacing.small)
                .padding(.vertical, DL.Spacing.tight)
                .background(DLColor.surfaceRaised, in: RoundedRectangle(cornerRadius: DL.Radius.small))
                .onSubmit { ask(question) }
            Button {
                ask(question)
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(DL.Spacing.small)
        .background(DLColor.surface)
    }

    private func ask(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let snapshot = environment.drive.copilotSnapshot()
        let answer = LocalCopilot.respond(to: trimmed, snapshot: snapshot)
        exchanges.append(Exchange(question: trimmed, answer: answer))
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
