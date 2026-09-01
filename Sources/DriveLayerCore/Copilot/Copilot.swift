import Foundation

/// What kind of claim a sentence is making. Every copilot sentence carries one, and
/// the UI shows it, because "your battery is weak" and "your battery voltage has
/// drifted 0.3 V below your own baseline" are different kinds of statement.
enum ClaimType: String, Sendable, Codable, CaseIterable {
    case fact
    case estimate
    case inference
    case generalInformation

    var label: String {
        switch self {
        case .fact: return "Measured"
        case .estimate: return "Estimate"
        case .inference: return "Inference"
        case .generalInformation: return "General information"
        }
    }
}

struct CopilotStatement: Sendable, Equatable {
    var text: String
    var claim: ClaimType
}

struct CopilotAnswer: Sendable, Equatable {
    var statements: [CopilotStatement]
    /// A short version for voice and CarPlay — at most a couple of sentences.
    var spokenText: String
    /// The full version, shown on the phone while parked.
    var detailedText: String
    var wasUnderstood: Bool
    /// Set when the honest answer is "DriveLayer cannot know that".
    var limitationNote: String?

    static func notUnderstood(suggestions: [String]) -> CopilotAnswer {
        let text = "I didn't catch that. You can ask me things like: " + suggestions.prefix(3).joined(separator: "; ") + "."
        return CopilotAnswer(statements: [CopilotStatement(text: text, claim: .generalInformation)],
                             spokenText: "I didn't catch that. Try asking how the car is doing.",
                             detailedText: text,
                             wasUnderstood: false,
                             limitationNote: nil)
    }
}

/// A copilot answers questions from a snapshot. Nothing else.
///
/// The protocol takes a `VehicleContextSnapshot`, never raw telemetry, so a future
/// model-backed implementation physically cannot be handed a sensor stream.
protocol CopilotProviding: Sendable {
    var displayName: String { get }
    var requiresNetwork: Bool { get }
    func answer(question: String, snapshot: VehicleContextSnapshot) async throws -> CopilotAnswer
}

/// The copilot that ships: offline, deterministic, and honest about its limits.
///
/// It matches a question against a fixed set of intents and answers them from the
/// snapshot. It is not a language model and does not pretend to be one — which means
/// it cannot invent a sensor reading, and every answer is traceable to a field.
/// A model-backed provider can be added behind `CopilotProviding` later; this one
/// stays as the offline fallback because a driver in a tunnel still deserves an answer.
struct LocalCopilot: CopilotProviding, Sendable {

    let displayName = "On-device copilot"
    let requiresNetwork = false

    enum Intent: String, CaseIterable, Sendable {
        case vehicleHealth
        case engineStatus
        case batteryStatus
        case fuelAndRange
        case economyToday
        case tripFuel
        case shortDrives
        case weatherAhead
        case lastService
        case regenerationHistory
        case troubleCodeMeaning
        case monthComparison
        // The Hyperion intents. Each answers from the same assessment the Hyperion
        // screen shows, so the copilot cannot say something the screen does not.
        case turboStatus
        case fuelSystemStatus
        case warmUpStatus
        case activeFaults

        /// Keywords, all of which contribute to a match score.
        var keywords: [String] {
            switch self {
            case .vehicleHealth: return ["how is the car", "how's the car", "car doing", "vehicle health", "everything ok", "how is my car"]
            case .engineStatus: return ["engine", "coolant", "temperature", "running hot", "overheat"]
            case .turboStatus: return ["turbo", "boost", "intake", "air system", "manifold", "heat soak"]
            case .fuelSystemStatus: return ["fuel system", "fuel trim", "trims", "closed loop", "open loop", "mixture", "injector"]
            case .warmUpStatus: return ["warmed up", "warm up", "warm-up", "cold engine", "operating temperature", "is it warm"]
            case .activeFaults: return ["any faults", "faults", "any codes", "warning light", "check engine", "anything wrong"]
            case .batteryStatus: return ["battery", "voltage", "charging", "weak"]
            case .fuelAndRange: return ["fuel", "range", "how far", "tank", "petrol", "diesel left", "empty"]
            case .economyToday: return ["mileage", "economy", "consumption", "kmpl", "km per litre", "efficiency"]
            case .tripFuel: return ["this trip use", "trip use", "fuel did", "used on this", "how much fuel"]
            case .shortDrives: return ["short drive", "short trip", "how many drives", "how many trips"]
            case .weatherAhead: return ["weather", "rain", "fog", "snow", "ahead"]
            case .lastService: return ["service", "serviced", "maintenance", "due"]
            case .regenerationHistory: return ["regeneration", "regen", "dpf", "particulate", "soot"]
            case .troubleCodeMeaning: return ["what does", "code mean", "dtc", "fault code", "error code"]
            // "compare with usual" is how the example question puts it; the test that
            // every example routes to an intent is what found this missing.
            case .monthComparison: return ["compared", "compare", "last month", "changed", "versus", "vs last", "with usual", "than usual"]
            }
        }
    }

    static let exampleQuestions = [
        "How's the car?",
        "How's the engine?",
        "Is the engine warmed up?",
        "How's the turbo?",
        "How is the fuel system?",
        "Any faults?",
        "What's ahead?",
        "Why was mileage lower today?",
        "How does today compare with usual?"
    ]

    func answer(question: String, snapshot: VehicleContextSnapshot) async throws -> CopilotAnswer {
        Self.respond(to: question, snapshot: snapshot)
    }

    /// Synchronous entry point, so previews, tests and CarPlay can call it directly.
    static func respond(to question: String, snapshot: VehicleContextSnapshot) -> CopilotAnswer {
        let normalised = question.lowercased()

        // A trouble code in the question is unambiguous, so it wins over keyword scoring.
        if let code = troubleCode(in: question) {
            return explainCode(code)
        }

        guard let intent = bestIntent(for: normalised) else {
            return .notUnderstood(suggestions: exampleQuestions)
        }

        switch intent {
        case .vehicleHealth: return vehicleHealth(snapshot)
        case .engineStatus: return engineStatus(snapshot)
        case .batteryStatus: return batteryStatus(snapshot)
        case .fuelAndRange: return fuelAndRange(snapshot)
        case .economyToday: return economy(snapshot)
        case .tripFuel: return tripFuel(snapshot)
        case .shortDrives: return shortDrives(snapshot)
        case .weatherAhead: return weatherAhead(snapshot)
        case .lastService: return service(snapshot)
        case .regenerationHistory: return regeneration(snapshot)
        case .monthComparison: return monthComparison(snapshot)
        case .turboStatus: return hyperionArea("Air & turbo", snapshot,
                                               unavailable: "Turbo and intake behaviour need intake and ambient air temperature from the adapter, and I'm not seeing both.")
        case .fuelSystemStatus: return hyperionArea("Fuel system", snapshot,
                                                    unavailable: "The fuel system state needs a connected adapter that reports it, and I'm not seeing one.")
        case .warmUpStatus: return hyperionArea("Engine state", snapshot,
                                                unavailable: "Whether the engine is warmed up needs coolant temperature from the adapter, and I'm not seeing it.")
        case .activeFaults: return activeFaults(snapshot)
        case .troubleCodeMeaning:
            return compose(statements: [CopilotStatement(
                text: "Tell me the code — something like P0401 — and I'll explain what it means.",
                claim: .generalInformation)])
        }
    }

    // MARK: - Intent matching

    static func bestIntent(for question: String) -> Intent? {
        var best: (intent: Intent, score: Int)?
        for intent in Intent.allCases {
            var score = 0
            for keyword in intent.keywords where question.contains(keyword) {
                // Longer phrases are stronger evidence than single words.
                score += keyword.contains(" ") ? 3 : 1
            }
            guard score > 0 else { continue }
            if best == nil || score > best!.score {
                best = (intent, score)
            }
        }
        return best?.intent
    }

    static func troubleCode(in question: String) -> String? {
        let pattern = #"\b[PpCcBbUu][0-3][0-9A-Fa-f]{3}\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(question.startIndex..., in: question)
        guard let match = regex.firstMatch(in: question, range: range),
              let matchRange = Range(match.range, in: question) else { return nil }
        return String(question[matchRange]).uppercased()
    }

    // MARK: - Answers

    private static func compose(statements: [CopilotStatement], limitation: String? = nil) -> CopilotAnswer {
        let detailed = statements.map(\.text).joined(separator: " ")
        // Voice answers stay to two sentences: a driver cannot hold more than that.
        let spoken = statements.prefix(2).map(\.text).joined(separator: " ")
        return CopilotAnswer(statements: statements,
                             spokenText: spoken,
                             detailedText: limitation.map { detailed + " " + $0 } ?? detailed,
                             wasUnderstood: true,
                             limitationNote: limitation)
    }

    private static func vehicleHealth(_ snapshot: VehicleContextSnapshot) -> CopilotAnswer {
        guard let health = snapshot.health else {
            return compose(statements: [CopilotStatement(
                text: "I don't have a health picture yet. Connect an adapter or record a few drives first.",
                claim: .fact)])
        }
        var statements = [CopilotStatement(text: "Overall, your vehicle is \(health.overall.lowercased()).", claim: .fact)]

        let notNormal = health.systems.filter { $0.value != SemanticStatus.normal.label && $0.value != SemanticStatus.unknown.label }
        if notNormal.isEmpty {
            statements.append(CopilotStatement(text: "Nothing needs your attention right now.", claim: .fact))
        } else {
            let list = notNormal.map { "\($0.key.lowercased()) is \($0.value.lowercased())" }.sorted().joined(separator: ", and ")
            let sentence = list.prefix(1).uppercased() + String(list.dropFirst())
            statements.append(CopilotStatement(text: "\(sentence).", claim: .fact))
        }
        if let range = snapshot.fuel?.estimatedRangeKm {
            statements.append(CopilotStatement(text: String(format: "You have roughly %.0f kilometres of estimated range.", range),
                                               claim: .estimate))
        }
        if let change = snapshot.weather?.changesAhead.first {
            statements.append(CopilotStatement(text: change, claim: .estimate))
        }
        let limitation = health.isLimitedByMissingData
            ? "Some systems couldn't be checked, so this isn't a complete picture."
            : nil
        return compose(statements: statements, limitation: limitation)
    }

    private static func engineStatus(_ snapshot: VehicleContextSnapshot) -> CopilotAnswer {
        // The Hyperion assessment is the richer answer: it knows the warm-up phase, the
        // intake picture and the comparison to this car's baseline. Fall back to the
        // health system's one-word status only when there is no assessment at all.
        if let hyperion = snapshot.hyperion, !hyperion.isSilent {
            var statements: [CopilotStatement] = [
                CopilotStatement(text: "Overall, the engine reads \(hyperion.overall.lowercased()).", claim: .fact)
            ]
            // Every assessed area gets a sentence; unassessed ones are named so the driver
            // knows the answer is partial rather than assuming it is complete.
            for area in hyperion.areas where area.notAssessedReason == nil && area.status != "Unknown" {
                statements.append(CopilotStatement(text: "\(area.name): \(area.headline.lowercased()).",
                                                   claim: .fact))
                if let comparison = area.comparison {
                    statements.append(CopilotStatement(text: comparison, claim: .inference))
                }
            }
            let unassessed = hyperion.areas.filter { $0.notAssessedReason != nil }.map { $0.name.lowercased() }
            let limitation = unassessed.isEmpty
                ? nil
                : "Not assessed yet: " + unassessed.joined(separator: ", ") + ". Those need readings the car isn't providing."
            return compose(statements: statements, limitation: limitation)
        }

        guard let engineStatus = snapshot.health?.systems["Engine"] else {
            return compose(statements: [CopilotStatement(
                text: "I can't see engine data at the moment. That needs a connected OBD-II adapter.",
                claim: .fact)])
        }
        var statements = [CopilotStatement(text: "Your engine is reading \(engineStatus.lowercased()).", claim: .fact)]
        if let insight = snapshot.recentInsights.first(where: { $0.lowercased().contains("engine") }) {
            statements.append(CopilotStatement(text: insight, claim: .inference))
        }
        return compose(statements: statements)
    }

    /// One Hyperion area, by display name, as an answer.
    ///
    /// Three outcomes and each is stated as what it is: assessed (the headline, then the
    /// comparison as an inference), not assessed (the reason, as a fact about what the car
    /// is reporting), or no assessment at all (the caller's `unavailable` line).
    private static func hyperionArea(_ name: String,
                                     _ snapshot: VehicleContextSnapshot,
                                     unavailable: String) -> CopilotAnswer {
        guard let hyperion = snapshot.hyperion, let area = hyperion.area(named: name) else {
            return compose(statements: [CopilotStatement(text: unavailable, claim: .fact)])
        }
        if let reason = area.notAssessedReason {
            return compose(statements: [CopilotStatement(text: "I can't assess \(name.lowercased()) yet. \(reason)",
                                                         claim: .fact)])
        }
        var statements = [CopilotStatement(text: "\(name): \(area.headline.lowercased()).", claim: .fact)]
        if let comparison = area.comparison {
            statements.append(CopilotStatement(text: comparison, claim: .inference))
        }
        // The confidence travels with the answer, so "normal" on two drives is not read
        // as the same statement as "normal" on forty.
        return compose(statements: statements,
                       limitation: area.confidence == "High confidence" ? nil : "\(area.confidence): this firms up with more comparable drives.")
    }

    /// Faults, in the order a driver cares about: the lamp, then stored codes, then the
    /// diagnostics area's own verdict on the self-tests.
    private static func activeFaults(_ snapshot: VehicleContextSnapshot) -> CopilotAnswer {
        var statements: [CopilotStatement] = []
        if !snapshot.activeTroubleCodes.isEmpty {
            let codes = snapshot.activeTroubleCodes.joined(separator: ", ")
            statements.append(CopilotStatement(
                text: "The car is reporting \(snapshot.activeTroubleCodes.count == 1 ? "one stored code" : "\(snapshot.activeTroubleCodes.count) stored codes"): \(codes). Ask me about any of them by number.",
                claim: .fact))
        }
        if let diagnostics = snapshot.hyperion?.area(named: "Diagnostics") {
            if let reason = diagnostics.notAssessedReason {
                statements.append(CopilotStatement(text: reason, claim: .fact))
            } else {
                statements.append(CopilotStatement(text: diagnostics.headline + ".", claim: .fact))
            }
        }
        if statements.isEmpty {
            // Nothing above could speak: no codes, and no diagnostics area in the
            // assessment. Say exactly that. Claiming "the warning light is off" here would
            // be an invention - the lamp state lives in the diagnostics area, and if that
            // area is absent, nobody has read the lamp.
            statements.append(CopilotStatement(
                text: "No stored fault codes have been read, and I haven't been able to check the warning light. Both need a connected adapter.",
                claim: .fact))
        }
        return compose(statements: statements)
    }

    private static func batteryStatus(_ snapshot: VehicleContextSnapshot) -> CopilotAnswer {
        guard let batteryStatus = snapshot.health?.systems["Battery"] else {
            return compose(statements: [CopilotStatement(
                text: "I can't see battery voltage. That needs an adapter that reports control module voltage.",
                claim: .fact)])
        }
        var statements = [CopilotStatement(text: "Battery status is \(batteryStatus.lowercased()).", claim: .fact)]
        if let baseline = snapshot.batteryBaselineV {
            statements.append(CopilotStatement(text: String(format: "Your usual resting voltage is about %.2f volts.", baseline),
                                               claim: .fact))
        }
        if let trend = snapshot.batteryTrendVPerWindow, trend <= -0.2 {
            statements.append(CopilotStatement(
                text: String(format: "It has drifted about %.2f volts lower recently, which often shows up before a battery starts struggling.", trend),
                claim: .inference))
        }
        return compose(statements: statements)
    }

    private static func fuelAndRange(_ snapshot: VehicleContextSnapshot) -> CopilotAnswer {
        guard let fuel = snapshot.fuel else {
            return compose(statements: [CopilotStatement(text: "I don't have fuel information for this vehicle yet.", claim: .fact)])
        }
        var statements: [CopilotStatement] = []
        if let level = fuel.levelPercent {
            statements.append(CopilotStatement(text: String(format: "The tank is at about %.0f percent.", level), claim: .fact))
        }
        if let range = fuel.estimatedRangeKm {
            statements.append(CopilotStatement(text: String(format: "That's roughly %.0f kilometres of estimated range, based on %@.", range, fuel.economySource),
                                               claim: .estimate))
        } else {
            statements.append(CopilotStatement(text: "I can't estimate range yet — I need your tank size and a few more drives.", claim: .fact))
        }
        return compose(statements: statements)
    }

    private static func economy(_ snapshot: VehicleContextSnapshot) -> CopilotAnswer {
        guard let lastTrip = snapshot.lastTrip, let economy = lastTrip.economyKmPerLitre else {
            return compose(statements: [CopilotStatement(
                text: "I don't have a fuel figure for your last drive, so I can't compare economy.",
                claim: .fact)])
        }
        var statements = [CopilotStatement(text: String(format: "Your last drive returned about %.1f km per litre.", economy), claim: .estimate)]

        if let typical = snapshot.thisMonth?.medianEconomyKmPerLitre, typical > 0 {
            let deltaPercent = (economy - typical) / typical * 100
            if abs(deltaPercent) >= 5 {
                let direction = deltaPercent < 0 ? "below" : "above"
                statements.append(CopilotStatement(
                    text: String(format: "That's about %.0f percent %@ your recent average.", abs(deltaPercent), direction),
                    claim: .fact))
                if deltaPercent < 0, lastTrip.idleMinutes >= 8 {
                    statements.append(CopilotStatement(
                        text: String(format: "You spent about %.0f minutes idling on that drive, which is associated with lower economy.", lastTrip.idleMinutes),
                        claim: .inference))
                }
            } else {
                statements.append(CopilotStatement(text: "That's in line with your recent average.", claim: .fact))
            }
        }
        return compose(statements: statements)
    }

    private static func tripFuel(_ snapshot: VehicleContextSnapshot) -> CopilotAnswer {
        let trip = snapshot.currentTrip ?? snapshot.lastTrip
        guard let trip else {
            return compose(statements: [CopilotStatement(text: "I don't have a drive to report on yet.", claim: .fact)])
        }
        guard let litres = trip.fuelLitres else {
            return compose(statements: [CopilotStatement(
                text: "That drive has no fuel figure. Your vehicle didn't report fuel rate or a usable tank level change.",
                claim: .fact)],
                           limitation: "I won't estimate fuel from distance alone — that would be a guess dressed up as a measurement.")
        }
        var statements = [CopilotStatement(
            text: String(format: "That drive used about %.1f litres over %.1f kilometres.", litres, trip.distanceKm),
            claim: .estimate)]
        if let economy = trip.economyKmPerLitre {
            statements.append(CopilotStatement(text: String(format: "That works out at roughly %.1f km per litre.", economy), claim: .estimate))
        }
        return compose(statements: statements)
    }

    private static func shortDrives(_ snapshot: VehicleContextSnapshot) -> CopilotAnswer {
        guard let week = snapshot.thisWeek else {
            return compose(statements: [CopilotStatement(text: "I haven't recorded any drives this week.", claim: .fact)])
        }
        var statements = [CopilotStatement(
            text: "You've made \(week.tripCount) drives this week, \(week.shortTripCount) of them shorter than \(Int(TripAnalytics.shortTripThresholdKm)) kilometres.",
            claim: .fact)]
        if let diesel = snapshot.diesel, diesel.isApplicable, week.shortTripCount > 0 {
            statements.append(CopilotStatement(text: diesel.explanation, claim: .inference))
        }
        return compose(statements: statements)
    }

    private static func weatherAhead(_ snapshot: VehicleContextSnapshot) -> CopilotAnswer {
        guard let weather = snapshot.weather else {
            return compose(statements: [CopilotStatement(text: "I don't have weather information right now.", claim: .fact)])
        }
        var statements: [CopilotStatement] = []
        if let condition = weather.currentCondition {
            let temperature = weather.temperatureC.map { String(format: " at about %.0f degrees", $0) } ?? ""
            statements.append(CopilotStatement(text: "Right now it's \(condition.lowercased())\(temperature).", claim: .fact))
        }
        if let change = weather.changesAhead.first {
            statements.append(CopilotStatement(text: change, claim: .estimate))
        } else {
            statements.append(CopilotStatement(text: "Nothing significant is expected to change on the road ahead.", claim: .estimate))
        }
        return compose(statements: statements)
    }

    private static func service(_ snapshot: VehicleContextSnapshot) -> CopilotAnswer {
        guard let maintenance = snapshot.maintenance else {
            return compose(statements: [CopilotStatement(
                text: "You haven't set up any maintenance items yet. Add your last service and I'll track what's due.",
                claim: .fact)])
        }
        var statements: [CopilotStatement] = []
        if let name = maintenance.nextItemName, let summary = maintenance.nextItemSummary {
            statements.append(CopilotStatement(text: "\(name): \(summary)", claim: .estimate))
        }
        if maintenance.overdueCount > 0 {
            statements.append(CopilotStatement(
                text: "\(maintenance.overdueCount) item\(maintenance.overdueCount == 1 ? " is" : "s are") overdue.",
                claim: .fact))
        }
        if statements.isEmpty {
            statements.append(CopilotStatement(text: "Nothing is due at the moment.", claim: .fact))
        }
        return compose(statements: statements)
    }

    /// The question DriveLayer must refuse to answer with a number.
    private static func regeneration(_ snapshot: VehicleContextSnapshot) -> CopilotAnswer {
        guard let diesel = snapshot.diesel, diesel.isApplicable else {
            return compose(statements: [CopilotStatement(
                text: "This vehicle isn't a diesel, so particulate filter behaviour doesn't apply.",
                claim: .fact)])
        }
        guard diesel.hasDirectFilterData else {
            var statements = [CopilotStatement(
                text: "I can't tell you when your filter last regenerated. Standard OBD-II doesn't report soot load or regeneration status, and I won't guess at a number.",
                claim: .fact)]
            if let percent = diesel.shortTripPercent {
                statements.append(CopilotStatement(
                    text: String(format: "What I can tell you is that %.0f percent of your recent drives were short journeys.", percent),
                    claim: .fact))
                statements.append(CopilotStatement(text: diesel.explanation, claim: .inference))
            }
            return compose(statements: statements,
                           limitation: "For the filter's actual condition you'd need a workshop tool with manufacturer diagnostics.")
        }
        return compose(statements: [CopilotStatement(text: diesel.explanation, claim: .fact)])
    }

    private static func monthComparison(_ snapshot: VehicleContextSnapshot) -> CopilotAnswer {
        guard let thisMonth = snapshot.thisMonth, let lastMonth = snapshot.lastMonth else {
            return compose(statements: [CopilotStatement(
                text: "I need two months of drives before I can compare them.",
                claim: .fact)])
        }
        var statements = [CopilotStatement(
            text: String(format: "Over the last 30 days you drove %.0f kilometres across %d drives, against %.0f kilometres and %d drives in the month before.",
                         thisMonth.distanceKm, thisMonth.tripCount, lastMonth.distanceKm, lastMonth.tripCount),
            claim: .fact)]

        if let now = thisMonth.medianEconomyKmPerLitre, let before = lastMonth.medianEconomyKmPerLitre, before > 0 {
            let delta = (now - before) / before * 100
            let direction = delta >= 0 ? "better" : "worse"
            statements.append(CopilotStatement(
                text: String(format: "Fuel economy is about %.0f percent %@, at %.1f km per litre against %.1f.", abs(delta), direction, now, before),
                claim: .estimate))
        }
        return compose(statements: statements)
    }

    private static func explainCode(_ code: String) -> CopilotAnswer {
        let explanation = DTCCatalog.explanation(for: code)
        var statements = [
            CopilotStatement(text: "\(code) is \(explanation.standardDefinition).",
                             claim: explanation.isGenericFallback ? .inference : .generalInformation),
            CopilotStatement(text: explanation.plainLanguage, claim: .generalInformation)
        ]
        statements.append(CopilotStatement(text: explanation.drivingGuidance, claim: .generalInformation))
        return compose(statements: statements,
                       limitation: "A trouble code describes what the vehicle observed, not which part has failed.")
    }
}
