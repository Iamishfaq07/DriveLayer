import Foundation

/// One area of the Hyperion engine, as DriveLayer sees it.
///
/// Modelled as a list of sections rather than six named fields so it matches
/// `VehicleHealthSystem`, which the app already knows how to render, and so an area that
/// has not been built yet can be present and honest instead of absent and confusing.
struct HyperionSection: Sendable, Equatable, Identifiable {

    enum Area: String, Codable, CaseIterable, Sendable {
        case thermal
        case airAndTurbo
        case fuelSystem
        case aftertreatment
        case battery
        case diagnostics

        var displayName: String {
            switch self {
            case .thermal: return "Engine state"
            case .airAndTurbo: return "Air & turbo"
            case .fuelSystem: return "Fuel system"
            case .aftertreatment: return "Aftertreatment"
            case .battery: return "12V system"
            case .diagnostics: return "Diagnostics"
            }
        }
    }

    var id: String { area.rawValue }
    var area: Area
    var status: SemanticStatus
    var headline: String
    var detail: String
    var comparison: String?
    var confidence: InsightConfidence
    var dataPoints: [InsightSourceDatum]

    /// Set when this area is not assessed yet, with the reason.
    ///
    /// The difference between "nothing unusual" and "not looked at" is the whole point of
    /// carrying it. An unassessed area is excluded from the overall status rather than
    /// dragging it to unknown, and the UI can say which is which.
    var notAssessedReason: String?

    var isAssessed: Bool { notAssessedReason == nil }

    static func notAssessed(_ area: Area, because reason: String) -> HyperionSection {
        HyperionSection(area: area,
                        status: .unknown,
                        headline: "Not assessed yet",
                        detail: reason,
                        comparison: nil,
                        confidence: .low,
                        dataPoints: [],
                        notAssessedReason: reason)
    }
}

/// What DriveLayer makes of the Hyperion engine right now.
///
/// The central engine-intelligence object: the thing a Hyperion screen, CarPlay and Ask
/// Harrier all read, so they cannot drift apart or each invent their own summary.
struct HyperionAssessment: Sendable, Equatable {

    /// Worst status across the areas that were actually assessed.
    var overall: SemanticStatus
    var sections: [HyperionSection]
    /// The "what DriveLayer thinks" line. Never a diagnosis.
    var summary: String

    func section(_ area: HyperionSection.Area) -> HyperionSection? {
        sections.first { $0.area == area }
    }

    var assessedSections: [HyperionSection] { sections.filter(\.isAssessed) }

    /// True while there is nothing to read at all -- no adapter, or a cold start with no
    /// values yet.
    var isSilent: Bool { assessedSections.isEmpty }

    static let unavailable = HyperionAssessment(
        overall: .unknown,
        sections: HyperionSection.Area.allCases.map {
            .notAssessed($0, because: "Connect an adapter to read this.")
        },
        summary: "DriveLayer isn't reading anything from the engine yet."
    )
}

/// Rolls the Hyperion analysers into one assessment.
///
/// The analysers themselves were written first and wired to nothing: `EngineThermalModel`,
/// `HeatSoakAnalyser` and `SensorGate` existed, were tested, and were reachable from no
/// production code at all. This is the seam that makes them reach a driver, which is the
/// only definition of finished that counts.
enum HyperionGuardian {

    /// - Parameters:
    ///   - peakIntakeDeltaC: highest intake-over-ambient seen recently, so a fall can be
    ///     recognised as cooling rather than reported as a smaller number.
    ///   - intakeDeltaBaseline: this car's learned intake-to-ambient difference, if any.
    static func assess(coolantC: Provenanced<Double>,
                       oilC: Provenanced<Double> = .unavailable(),
                       intakeC: Provenanced<Double> = .unavailable(),
                       ambientC: Double? = nil,
                       speedKmh: Double? = nil,
                       idleSeconds: TimeInterval? = nil,
                       runtimeSeconds: TimeInterval? = nil,
                       peakIntakeDeltaC: Double? = nil,
                       warmUpHistory: [WarmUpObservation] = [],
                       intakeDeltaBaseline: MetricBaseline? = nil,
                       fuelSystem: FuelSystemStatus = .unknown,
                       profile: VehicleProfile? = nil) -> HyperionAssessment {

        var sections: [HyperionSection] = []

        // Engine state, from the warm-up model.
        let thermal = EngineThermalModel.assess(coolantC: coolantC,
                                                oilC: oilC,
                                                ambientC: ambientC,
                                                runtimeSeconds: runtimeSeconds,
                                                history: warmUpHistory,
                                                profile: profile)
        if coolantC.value == nil {
            sections.append(.notAssessed(.thermal, because: "Coolant temperature isn't being reported."))
        } else {
            sections.append(HyperionSection(area: .thermal,
                                            status: thermal.phase.status,
                                            headline: thermal.headline,
                                            detail: thermal.detail,
                                            comparison: thermal.comparison,
                                            confidence: thermal.confidence,
                                            dataPoints: thermal.dataPoints))
        }

        // Air and turbo. Today this is the intake-versus-ambient story; estimated boost
        // from MAP minus barometric pressure joins it when those PIDs are confirmed on a
        // real car, and not before -- guessing at boost is exactly the kind of invented
        // number this product refuses.
        let heatSoak = HeatSoakAnalyser.assess(intakeC: intakeC,
                                               ambientC: ambientC.map { .measured($0) } ?? .unavailable(),
                                               speedKmh: speedKmh,
                                               idleSeconds: idleSeconds,
                                               peakDeltaC: peakIntakeDeltaC,
                                               baseline: intakeDeltaBaseline)
        if heatSoak.phase == .unknown {
            sections.append(.notAssessed(.airAndTurbo,
                                         because: "Intake and ambient air temperature aren't both being reported."))
        } else {
            sections.append(HyperionSection(area: .airAndTurbo,
                                            status: heatSoak.status,
                                            headline: heatSoak.headline,
                                            detail: heatSoak.detail,
                                            comparison: heatSoak.comparison,
                                            confidence: heatSoak.confidence,
                                            dataPoints: heatSoak.dataPoints))
        }

        // The remaining areas are named here deliberately rather than omitted. Each one is
        // a written-down promise with a reason attached, which is harder to forget than a
        // gap and more honest than a reassuring blank.
        // Fuel system. The loop state is readable now; the trims that sit on top of it are
        // not interpreted yet, and the section describes which of the two it is talking
        // about rather than implying the whole area is covered.
        if fuelSystem == .unknown {
            sections.append(.notAssessed(.fuelSystem,
                                         because: "This vehicle is not reporting a fuel system state "
                                                + "DriveLayer recognises."))
        } else {
            var detail = fuelSystem.detail
            if !fuelSystem.allowsFuelTrimComparison {
                detail += " Fuel corrections are not compared against your baseline in this state."
            }
            sections.append(HyperionSection(area: .fuelSystem,
                                            status: fuelSystem.status,
                                            headline: fuelSystem.displayName,
                                            detail: detail,
                                            comparison: nil,
                                            confidence: .high,
                                            dataPoints: [.measured("Fuel loop", fuelSystem.displayName)]))
        }
        sections.append(.notAssessed(.aftertreatment,
                                     because: "Catalyst readiness is read from standard monitors; direct filter "
                                            + "loading isn't exposed through OBD-II."))
        sections.append(.notAssessed(.battery,
                                     because: "Voltage trends need a baseline built across several drives."))
        sections.append(.notAssessed(.diagnostics,
                                     because: "Structured monitor status isn't decoded yet."))

        let assessed = sections.filter(\.isAssessed)
        // Unassessed areas are excluded on purpose. `unknown` outranks `normal` in a
        // roll-up, so counting them would report the whole engine as unknown while every
        // reading DriveLayer actually has says it is fine.
        let overall = assessed.isEmpty ? .unknown : SemanticStatus.rollUp(assessed.map(\.status))

        return HyperionAssessment(overall: overall,
                                  sections: sections,
                                  summary: summarise(assessed: assessed, overall: overall))
    }

    private static func summarise(assessed: [HyperionSection], overall: SemanticStatus) -> String {
        guard !assessed.isEmpty else {
            return "DriveLayer isn't reading anything from the engine yet."
        }
        let notable = assessed.filter { $0.status > .normal }
        guard !notable.isEmpty else {
            return "No unusual Hyperion behaviour detected in what DriveLayer can read so far."
        }
        let areas = notable.map { $0.area.displayName.lowercased() }
        // Named without a verdict attached. The section says what it saw; this line only
        // points at it, because a summary is the easiest place to accidentally diagnose.
        return "Worth a look: " + areas.joined(separator: ", ") + "."
    }
}
