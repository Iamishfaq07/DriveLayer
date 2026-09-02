import Foundation

/// The facts a language model is allowed to see, and the guard that checks it stayed
/// inside them.
///
/// This file exists because of one rule this product does not bend: DriveLayer never
/// states a reading it does not have. A language model is very good at sounding
/// certain and quite willing to round 326 to "about 300", which is precisely the
/// failure this rule forbids. So the model is not trusted to be careful - it is
/// bounded on both sides. `CopilotFactSheet` is the only thing it is given, and
/// `AnswerGuard` checks what comes back.
///
/// Both halves are deliberately here in the core, as pure functions over a snapshot,
/// rather than next to the framework binding in the app: this is the part that has to
/// be tested, and `swift test` cannot reach the app target.
enum CopilotFactSheet {

    /// Renders the snapshot as a flat list of `label: value` lines.
    ///
    /// Only fields that are actually present appear. An absent value is omitted
    /// entirely rather than written as "unknown", because a model shown
    /// "Range: unknown" tends to answer around it, while a model shown nothing about
    /// range has nothing to work with and says so - which is the honest answer.
    static func lines(from snapshot: VehicleContextSnapshot) -> [String] {
        var lines: [String] = []

        if let vehicle = snapshot.vehicle {
            lines.append("Vehicle: \(vehicle.nickname), a \(vehicle.profileName), \(vehicle.fuelType)")
            if let odometer = vehicle.odometerKm {
                lines.append("Odometer: \(number(odometer, digits: 0)) km")
            }
        }

        if let health = snapshot.health {
            lines.append("Overall health: \(health.overall)")
            for (system, status) in health.systems.sorted(by: { $0.key < $1.key }) {
                lines.append("\(system) status: \(status)")
            }
        }

        if let fuel = snapshot.fuel {
            if let level = fuel.levelPercent {
                lines.append("Fuel level: \(number(level, digits: 0)) percent")
            }
            if let range = fuel.estimatedRangeKm {
                lines.append("Estimated range: \(number(range, digits: 0)) km")
            }
            if let economy = fuel.economyKmPerLitre {
                lines.append("Fuel economy: \(number(economy, digits: 1)) km per litre (\(fuel.economySource))")
            }
        }

        if let trip = snapshot.lastTrip {
            lines.append("Last drive: \(number(trip.distanceKm, digits: 1)) km over \(number(trip.durationMinutes, digits: 0)) minutes")
            if let economy = trip.economyKmPerLitre {
                lines.append("Last drive economy: \(number(economy, digits: 1)) km per litre")
            }
        }

        if let maintenance = snapshot.maintenance {
            if let name = maintenance.nextItemName, let summary = maintenance.nextItemSummary {
                lines.append("Next service: \(name), \(summary)")
            }
            if maintenance.overdueCount > 0 {
                lines.append("Overdue maintenance items: \(maintenance.overdueCount)")
            }
        }

        if let hyperion = snapshot.hyperion, !hyperion.isSilent {
            lines.append("Engine assessment: \(hyperion.overall). \(hyperion.summary)")
            for area in hyperion.areas {
                if let reason = area.notAssessedReason {
                    lines.append("\(area.name): not assessed, \(reason)")
                } else {
                    lines.append("\(area.name): \(area.status), \(area.headline)")
                }
            }
        }

        if let weather = snapshot.weather {
            if let condition = weather.currentCondition {
                lines.append("Weather now: \(condition)")
            }
            if let temperature = weather.temperatureC {
                lines.append("Temperature: \(number(temperature, digits: 0)) degrees Celsius")
            }
            for change in weather.changesAhead {
                lines.append("Weather ahead: \(change)")
            }
        }

        if let baseline = snapshot.batteryBaselineV {
            lines.append("Usual resting battery voltage: \(number(baseline, digits: 2)) volts")
        }

        if snapshot.activeTroubleCodes.isEmpty {
            lines.append("Active trouble codes: none")
        } else {
            lines.append("Active trouble codes: \(snapshot.activeTroubleCodes.joined(separator: ", "))")
        }

        for insight in snapshot.recentInsights {
            lines.append("Recent finding: \(insight)")
        }

        lines.append("Currently driving: \(snapshot.isDriving ? "yes" : "no")")
        return lines
    }

    static func text(from snapshot: VehicleContextSnapshot) -> String {
        lines(from: snapshot).joined(separator: "\n")
    }

    /// What the model is told before it sees anything. Short on purpose: a long list
    /// of prohibitions reads as a suggestion, and the guard is what actually enforces
    /// the important one.
    static let instructions = """
    You are the assistant inside a specific car, speaking to its driver while they \
    are driving.

    Answer only from the FACTS you are given. Never state a number that does not \
    appear in the FACTS - do not round, convert, average or add them up. If the \
    FACTS do not answer the question, say plainly that you do not have that reading.

    Two short sentences at most. You are being read aloud to someone at the wheel.
    """

    static func prompt(question: String, snapshot: VehicleContextSnapshot) -> String {
        """
        FACTS:
        \(text(from: snapshot))

        QUESTION: \(question)
        """
    }

    private static func number(_ value: Double, digits: Int) -> String {
        String(format: "%.\(digits)f", value)
    }
}

/// Checks a generated answer against the facts it was allowed to use.
///
/// The rule is narrow and mechanical on purpose: **every number in the answer must
/// be a number the model was given**. That does not make a model truthful in general
/// - it cannot catch a wrong adjective or a bad inference - but it does catch the one
/// failure this product treats as unacceptable, which is a fabricated reading
/// presented as measured.
///
/// It fails closed. An answer that cannot be verified is discarded and the
/// deterministic copilot answers instead, so the worst case is the app behaving
/// exactly as it did before there was a model in it.
enum AnswerGuard {

    enum Verdict: Equatable {
        case verified
        /// Carries the offending numbers, so a rejection can be logged as a fact
        /// rather than a shrug.
        case unverifiedNumbers([String])
    }

    /// - Parameter question: numbers the driver used are allowed back in the answer,
    ///   so "is 12 volts low?" can be echoed without tripping the guard.
    static func check(answer: String, against facts: String, question: String = "") -> Verdict {
        // A plain array, scanned: matching is by numeric closeness rather than by
        // exact text, so a hashed lookup would not answer the question being asked.
        let permitted = numbers(in: facts) + numbers(in: question)
        let used = numbers(in: answer)
        let unverified = used.filter { candidate in
            !permitted.contains { $0.isCloseEnough(to: candidate) }
        }
        return unverified.isEmpty ? .verified : .unverifiedNumbers(unverified.map(\.text))
    }

    static func isVerified(answer: String, against facts: String, question: String = "") -> Bool {
        check(answer: answer, against: facts, question: question) == .verified
    }

    struct Number: Hashable {
        var text: String
        var value: Double

        /// Formatting differences are not fabrication: 12.4 and 12.40 are the same
        /// reading. Anything beyond a rounding difference is not.
        func isCloseEnough(to other: Number) -> Bool {
            abs(value - other.value) < 0.005
        }
    }

    /// Digit runs only. A model writing "one or two things" is not making a numeric
    /// claim, and treating spelled-out numbers as readings would reject ordinary
    /// English without catching any more fabrication than this already does.
    static func numbers(in text: String) -> [Number] {
        var found: [Number] = []
        var current = ""

        func flush() {
            defer { current = "" }
            let trimmed = current.hasSuffix(".") ? String(current.dropLast()) : current
            guard !trimmed.isEmpty, trimmed != "-", let value = Double(trimmed) else { return }
            found.append(Number(text: trimmed, value: value))
        }

        for character in text {
            if character.isNumber {
                current.append(character)
            } else if character == "." && !current.isEmpty {
                // A decimal point continues a number; a full stop ends one. Which it
                // is only becomes clear at the next character, so keep it and strip a
                // trailing one when the run closes.
                current.append(character)
            } else if character == "-" && current.isEmpty {
                current.append(character)
            } else {
                flush()
            }
        }
        flush()
        return found
    }
}
