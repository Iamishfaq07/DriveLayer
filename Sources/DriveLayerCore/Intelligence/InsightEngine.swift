import Foundation

/// Runs the rules and decides what actually reaches the driver.
///
/// The engine's job is as much about suppression as generation. Rules are cheap and
/// independent; the value is in deduplicating them, keeping the newest version of a
/// repeated finding, dropping anything expired, and — while the car is moving — cutting
/// the list to the few things worth reading at speed.
struct InsightEngine: Sendable {

    let rules: [InsightRule]

    /// The most insights that should ever be shown while driving.
    static let drivingDisplayLimit = 3

    static let standardRules: [InsightRule] = [
        EngineTemperatureRule(),
        BatteryHealthRule(),
        EngineLoadRule(),
        FuelRule(),
        TerrainRule(),
        WeatherRule(),
        MaintenanceRule(),
        DocumentExpiryRule(),
        TroubleCodeRule(),
        DieselUsageRule(),
        TripComparisonRule()
    ]

    init(rules: [InsightRule] = InsightEngine.standardRules) {
        self.rules = rules
    }

    /// Evaluates every rule. A rule that throws off a bad assumption should not take
    /// the whole engine with it, so each is isolated to its own array append.
    func evaluate(_ context: InsightContext, existing: [DriveInsight] = []) -> [DriveInsight] {
        var produced: [DriveInsight] = []
        for rule in rules {
            produced.append(contentsOf: rule.evaluate(context))
        }

        // Carry forward anything still valid that this pass did not regenerate, so a
        // finding does not flicker out because its rule had nothing new to say.
        let producedIDs = Set(produced.map(\.id))
        let carriedOver = existing.filter { $0.isValid(at: context.now) && !producedIDs.contains($0.id) }

        let merged = (produced + carriedOver)
            .filter { $0.isValid(at: context.now) }

        return sorted(deduplicate(merged))
    }

    /// Keeps the newest instance of each insight id.
    private func deduplicate(_ insights: [DriveInsight]) -> [DriveInsight] {
        var newest: [String: DriveInsight] = [:]
        for insight in insights {
            if let existing = newest[insight.id], existing.createdAt >= insight.createdAt { continue }
            newest[insight.id] = insight
        }
        return Array(newest.values)
    }

    private func sorted(_ insights: [DriveInsight]) -> [DriveInsight] {
        insights.sorted { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
            return lhs.createdAt > rhs.createdAt
        }
    }

    /// What to show someone who is driving: safe to display, urgent first, few.
    static func forDriving(_ insights: [DriveInsight], limit: Int = drivingDisplayLimit) -> [DriveInsight] {
        Array(insights.filter(\.isDrivingSafeToDisplay).prefix(limit))
    }

    /// The single most important thing, for CarPlay and the widget.
    static func headline(_ insights: [DriveInsight]) -> DriveInsight? {
        insights.filter(\.isDrivingSafeToDisplay).first
    }
}
