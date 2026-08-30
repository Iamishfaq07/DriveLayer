import SwiftUI

struct InsightsView: View {

    @Environment(AppEnvironment.self) private var environment
    @State private var category: InsightCategory?

    private var insights: [DriveInsight] {
        guard let category else { return environment.drive.insights }
        return environment.drive.insights.filter { $0.category == category }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DL.Spacing.medium) {
                filterRow
                if insights.isEmpty {
                    DLEmptyState(symbol: "checkmark.circle",
                                 title: "Nothing to report",
                                 message: category == nil
                                     ? "DriveLayer will speak up when something is worth your attention. Silence here is a good sign."
                                     : "Nothing in this category right now.")
                } else {
                    ForEach(insights) { insight in
                        InsightCard(insight: insight)
                    }
                }
            }
            .dlScreenPadding()
            .padding(.vertical, DL.Spacing.medium)
        }
        .background(DLColor.background)
        .navigationTitle("Insights")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { environment.drive.refreshAnalysis(force: true) }
    }

    private var filterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DL.Spacing.tight) {
                FilterChip(title: "All", isSelected: category == nil) { category = nil }
                ForEach(presentCategories, id: \.self) { candidate in
                    FilterChip(title: candidate.displayName, isSelected: category == candidate) {
                        category = category == candidate ? nil : candidate
                    }
                }
            }
        }
    }

    /// Only categories that currently have something in them — an empty filter is noise.
    private var presentCategories: [InsightCategory] {
        let present = Set(environment.drive.insights.map(\.category))
        return InsightCategory.allCases.filter { present.contains($0) }
    }
}

private struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(DL.Font.caption.weight(.medium))
                .padding(.horizontal, DL.Spacing.small)
                .padding(.vertical, DL.Spacing.tight)
                .background(isSelected ? DLColor.accent.opacity(0.18) : DLColor.primaryText.opacity(DL.Opacity.fill),
                            in: Capsule())
                .foregroundStyle(isSelected ? DLColor.accent : DLColor.secondaryText)
        }
        .buttonStyle(.plain)
    }
}
