import Foundation

/// Where the engine is in its warm-up.
///
/// Five states rather than a temperature, because a temperature alone does not answer
/// the question a driver has. 61 °C means one thing three minutes into a January start
/// and something quite different twenty minutes into a July one.
enum EngineThermalPhase: String, Codable, CaseIterable, Sendable {
    case cold
    case warming
    case operating
    case hot
    /// No coolant reading, so nothing to say. Never rendered as "cold".
    case unknown

    var displayName: String {
        switch self {
        case .cold: return "Cold"
        case .warming: return "Warming up"
        case .operating: return "At operating temperature"
        case .hot: return "Hot"
        case .unknown: return "Unknown"
        }
    }

    var status: SemanticStatus {
        switch self {
        case .cold, .warming, .operating: return .normal
        case .hot: return .watch
        case .unknown: return .unknown
        }
    }
}

/// One completed warm-up, recorded so later ones can be compared against it.
///
/// Bucketed by ambient temperature because that is the single biggest influence on how
/// long a warm-up takes, and comparing a January start against a July one would
/// manufacture a problem out of the weather.
struct WarmUpObservation: Codable, Sendable, Equatable {
    var startedAt: Date
    var secondsToOperating: TimeInterval
    var startingCoolantC: Double
    var ambientC: Double?
    /// Average engine speed over the warm-up, since how it was driven matters.
    var averageRPM: Double?
    var distanceKm: Double?

    /// 5 °C bands. Narrow enough to be a fair comparison, wide enough to accumulate
    /// observations in a reasonable number of drives.
    var ambientBand: Int? {
        guard let ambientC else { return nil }
        return Int((ambientC / 5).rounded(.down))
    }
}

/// What DriveLayer can say about the engine's temperature right now.
struct EngineThermalAssessment: Sendable, Equatable {
    var phase: EngineThermalPhase
    var coolantC: Provenanced<Double>
    var oilC: Provenanced<Double>
    var headline: String
    var detail: String
    /// Present only once there are enough comparable warm-ups to say anything.
    var comparison: String?
    var confidence: InsightConfidence
    var dataPoints: [InsightSourceDatum]

    static let unknown = EngineThermalAssessment(
        phase: .unknown,
        coolantC: .unavailable(),
        oilC: .unavailable(),
        headline: "Engine temperature unavailable",
        detail: "This vehicle isn't reporting coolant temperature, so DriveLayer can't say "
              + "where the engine is in its warm-up.",
        comparison: nil,
        confidence: .low,
        dataPoints: []
    )
}

/// Interprets engine temperature, and learns what normal looks like for this car.
///
/// Deliberately **not** built on rules like "never exceed 2,000 rpm until 90 °C". That
/// advice is repeated everywhere and sourced nowhere, and this project does not ship
/// mechanical claims it cannot attribute. What it does instead is measure this engine's
/// own warm-ups and compare like with like.
enum EngineThermalModel {

    /// Generic engineering boundaries, used only when the profile supplies nothing.
    ///
    /// Labelled as generic wherever they reach the driver. A modern petrol engine runs at
    /// roughly 85–105 °C; below about 40 °C it is unambiguously cold. These are not Tata
    /// figures and are never presented as if they were.
    static let genericColdBelowC: Double = 40
    static let genericOperatingFromC: Double = 80
    static let genericHotFromC: Double = 105

    /// Warm-ups closer together than this are the same one, seen twice.
    static let minimumSecondsBetweenWarmUps: TimeInterval = 10 * 60
    /// Below this many comparable observations, DriveLayer says it is still learning.
    static let minimumObservationsForComparison = 4
    /// A difference smaller than this is noise, not a finding.
    static let notableDeviationFraction: Double = 0.15

    static func phase(coolantC: Double?, profile: VehicleProfile?) -> EngineThermalPhase {
        guard let coolantC else { return .unknown }
        let hotFrom = profile?
            .operatingRange(for: .coolantTemperatureC, condition: .warmedUp)?
            .watchHigh ?? genericHotFromC
        if coolantC >= hotFrom { return .hot }
        if coolantC >= genericOperatingFromC { return .operating }
        if coolantC < genericColdBelowC { return .cold }
        return .warming
    }

    /// Assesses the engine's current thermal state.
    static func assess(coolantC: Provenanced<Double>,
                       oilC: Provenanced<Double>,
                       ambientC: Double?,
                       runtimeSeconds: TimeInterval?,
                       history: [WarmUpObservation],
                       profile: VehicleProfile?) -> EngineThermalAssessment {
        guard let coolant = coolantC.value else { return .unknown }
        let phase = phase(coolantC: coolant, profile: profile)

        var points: [InsightSourceDatum] = [
            .measured("Coolant", String(format: "%.0f °C", coolant))
        ]
        if let oil = oilC.value {
            points.append(.measured("Oil", String(format: "%.0f °C", oil)))
        }
        if let ambientC {
            points.append(.measured("Ambient", String(format: "%.0f °C", ambientC)))
        }

        let detail = describe(phase: phase,
                              coolantC: coolant,
                              ambientC: ambientC,
                              runtimeSeconds: runtimeSeconds,
                              oilC: oilC.value)

        // Only warm-ups in comparable weather count, and only when there are enough.
        let comparable = comparableObservations(to: ambientC, in: history)
        let comparison = compare(runtimeSeconds: runtimeSeconds,
                                 phase: phase,
                                 comparable: comparable)

        return EngineThermalAssessment(
            phase: phase,
            coolantC: coolantC,
            oilC: oilC,
            headline: phase == .hot ? "ENGINE HOT" : phase.displayName.uppercased(),
            detail: detail,
            comparison: comparison,
            confidence: confidence(for: phase, comparable: comparable, hasOil: oilC.value != nil),
            dataPoints: points
        )
    }

    private static func describe(phase: EngineThermalPhase,
                                 coolantC: Double,
                                 ambientC: Double?,
                                 runtimeSeconds: TimeInterval?,
                                 oilC: Double?) -> String {
        let temperature = String(format: "%.0f °C", coolantC)
        switch phase {
        case .cold:
            var text = "Coolant temperature is \(temperature)."
            if let ambientC {
                text += String(format: " Outside it is about %.0f °C.", ambientC)
            }
            text += " Nothing needs doing - the engine warms up as you drive."
            return text
        case .warming:
            var text = "Coolant temperature is \(temperature) and rising"
            if let ambientC {
                text += String(format: ", which is normal for today's %.0f °C.", ambientC)
            } else {
                text += " normally."
            }
            if let runtimeSeconds, runtimeSeconds > 60 {
                text += String(format: " Running for %.0f minutes.", runtimeSeconds / 60)
            }
            return text
        case .operating:
            var text = "Coolant temperature is \(temperature), within the normal operating band."
            if let oilC, oilC < coolantC - 15 {
                // Worth saying, and worth not over-claiming: oil lags coolant by design.
                text += String(format: " Oil is still at %.0f °C and lags coolant, which is expected.", oilC)
            }
            return text
        case .hot:
            return "Coolant temperature is \(temperature), above the normal operating band. "
                 + "If it keeps climbing, or a warning appears on the dashboard, stop somewhere "
                 + "safe and let the engine cool before checking coolant level."
        case .unknown:
            return EngineThermalAssessment.unknown.detail
        }
    }

    /// Warm-ups recorded in a similar ambient temperature band.
    static func comparableObservations(to ambientC: Double?,
                                       in history: [WarmUpObservation]) -> [WarmUpObservation] {
        guard let ambientC else { return [] }
        let band = Int((ambientC / 5).rounded(.down))
        // The band itself plus its neighbours: a 5 °C step is a fine comparison and a
        // 15 °C span accumulates observations without mixing summer with winter.
        return history.filter { observation in
            guard let observationBand = observation.ambientBand else { return false }
            return abs(observationBand - band) <= 1
        }
    }

    private static func compare(runtimeSeconds: TimeInterval?,
                                phase: EngineThermalPhase,
                                comparable: [WarmUpObservation]) -> String? {
        // Only meaningful while still warming: once warm, the number is history.
        guard phase == .warming,
              let runtimeSeconds,
              comparable.count >= minimumObservationsForComparison else { return nil }

        let durations = comparable.map(\.secondsToOperating).sorted()
        guard let typical = Statistics.median(durations), typical > 0 else { return nil }

        // Still inside the usual time, so there is nothing to report yet.
        guard runtimeSeconds > typical else { return nil }

        let fraction = (runtimeSeconds - typical) / typical
        guard fraction >= notableDeviationFraction else { return nil }

        return String(format: "This warm-up is taking about %.0f%% longer than your usual "
                            + "cold starts in similar weather (%.0f comparable drives). One slow "
                            + "warm-up is not a fault; DriveLayer will say so if it becomes a pattern.",
                      fraction * 100, Double(comparable.count))
    }

    private static func confidence(for phase: EngineThermalPhase,
                                   comparable: [WarmUpObservation],
                                   hasOil: Bool) -> InsightConfidence {
        switch phase {
        case .unknown:
            return .low
        case .hot:
            // A measured temperature above the band needs no history to be worth saying.
            return hasOil ? .high : .medium
        case .cold, .warming, .operating:
            if comparable.count >= minimumObservationsForComparison { return .high }
            return comparable.isEmpty ? .low : .medium
        }
    }

    /// Folds a finished warm-up into the history, ignoring duplicates.
    static func record(_ observation: WarmUpObservation,
                       into history: [WarmUpObservation],
                       limit: Int = 60) -> [WarmUpObservation] {
        // The same warm-up offered twice - a re-analysis, a reconnect - must not count
        // twice, or the baseline is built from duplicates.
        let isDuplicate = history.contains { existing in
            abs(existing.startedAt.timeIntervalSince(observation.startedAt)) < minimumSecondsBetweenWarmUps
        }
        guard !isDuplicate else { return history }
        return (history + [observation])
            .sorted { $0.startedAt < $1.startedAt }
            .suffix(limit)
            .map { $0 }
    }
}
