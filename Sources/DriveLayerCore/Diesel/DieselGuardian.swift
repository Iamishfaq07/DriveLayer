import Foundation

/// What DriveLayer can say about diesel usage patterns.
///
/// The distinction this whole feature rests on: DriveLayer can *measure* how you
/// drive, and it cannot measure your particulate filter. So it reports driving
/// patterns as facts and filter condition as an inference — clearly labelled, with no
/// number attached to something it cannot read.
struct DieselUsageAssessment: Sendable, Equatable {
    var isApplicable: Bool
    var status: SemanticStatus
    var headline: String
    var explanation: String
    /// Share of recent drives shorter than the short-trip threshold.
    var shortTripFraction: Provenanced<Double>
    var averageTripDistanceKm: Provenanced<Double>
    /// Share of recent drives that appear to have reached operating temperature.
    var warmUpCompletionRate: Provenanced<Double>
    var idleFraction: Provenanced<Double>
    var tripsConsidered: Int
    var dpf: DPFTelemetry
    var recommendation: String?

    static let notApplicable = DieselUsageAssessment(
        isApplicable: false,
        status: .unknown,
        headline: "Not applicable",
        explanation: "Diesel Guardian only applies to diesel vehicles.",
        shortTripFraction: .unavailable(),
        averageTripDistanceKm: .unavailable(),
        warmUpCompletionRate: .unavailable(),
        idleFraction: .unavailable(),
        tripsConsidered: 0,
        dpf: .unavailable,
        recommendation: nil
    )
}

/// Assesses diesel usage patterns from drive history.
enum DieselGuardian {

    /// Drives shorter than this rarely let a diesel finish warming up.
    static let shortTripThresholdKm: Double = 8
    /// Coolant temperature that counts as warmed up.
    static let warmedUpCoolantC: Double = 70
    /// When coolant isn't reported, a drive of at least this long is *inferred* to
    /// have warmed up. Weaker evidence, and labelled as such.
    static let inferredWarmUpSeconds: TimeInterval = 12 * 60
    /// Below this many drives DriveLayer says it is still learning rather than judging.
    static let minimumTripsForAssessment = 5
    static let assessmentWindowDays = 14

    static func assess(trips: [Trip],
                       profile: VehicleProfile?,
                       dpf: DPFTelemetry = .unavailable,
                       now: Date,
                       calendar: Calendar = .current) -> DieselUsageAssessment {
        guard let profile, profile.fuelType.isDiesel else { return .notApplicable }

        let recent = trips
            .filter(\.isComplete)
            .within(days: assessmentWindowDays, of: now, calendar: calendar)

        guard recent.count >= minimumTripsForAssessment else {
            return DieselUsageAssessment(
                isApplicable: true,
                status: .unknown,
                headline: "Still learning",
                explanation: "DriveLayer needs about \(minimumTripsForAssessment) drives in a fortnight before it can describe your diesel usage pattern. It has \(recent.count).",
                shortTripFraction: .unavailable(),
                averageTripDistanceKm: .unavailable(),
                warmUpCompletionRate: .unavailable(),
                idleFraction: .unavailable(),
                tripsConsidered: recent.count,
                dpf: dpf,
                recommendation: nil
            )
        }

        let distances = recent.map(\.distanceKm)
        let shortTrips = recent.filter { $0.distanceKm < shortTripThresholdKm }
        let shortFraction = Double(shortTrips.count) / Double(recent.count)

        let warmUp = warmUpCompletion(in: recent)
        let totalDuration = recent.reduce(0) { $0 + $1.totalDurationSeconds }
        let totalIdle = recent.reduce(0) { $0 + $1.idleDurationSeconds }
        let idleFraction = totalDuration > 0 ? totalIdle / totalDuration : nil

        let status = self.status(shortFraction: shortFraction, warmUpRate: warmUp.rate)
        let copy = self.copy(status: status,
                             shortFraction: shortFraction,
                             warmUpRate: warmUp.rate,
                             tripCount: recent.count,
                             hasDPFTelemetry: dpf.hasAnyValue)

        return DieselUsageAssessment(
            isApplicable: true,
            status: status,
            headline: copy.headline,
            explanation: copy.explanation,
            shortTripFraction: .measured(shortFraction, at: now)
                .withBasis("Counted from your \(recent.count) drives in the last \(assessmentWindowDays) days."),
            averageTripDistanceKm: Statistics.mean(distances).map { Provenanced.measured($0, at: now) } ?? .unavailable(),
            warmUpCompletionRate: warmUp.rate.map { rate in
                Provenanced(value: rate, provenance: warmUp.provenance, timestamp: now, basis: warmUp.basis)
            } ?? .unavailable(basis: warmUp.basis),
            idleFraction: idleFraction.map { Provenanced.measured($0, at: now) } ?? .unavailable(),
            tripsConsidered: recent.count,
            dpf: dpf,
            recommendation: copy.recommendation
        )
    }

    /// Share of drives that appear to have reached operating temperature.
    ///
    /// Measured when the vehicle reported coolant temperature; inferred from drive
    /// duration otherwise. The two are never mixed silently — the provenance says which.
    static func warmUpCompletion(in trips: [Trip]) -> (rate: Double?, provenance: DataProvenance, basis: String) {
        let withCoolant = trips.filter { $0.peakCoolantTemperatureC != nil }
        if withCoolant.count >= max(3, trips.count / 2) {
            let warmed = withCoolant.filter { ($0.peakCoolantTemperatureC ?? 0) >= warmedUpCoolantC }
            return (Double(warmed.count) / Double(withCoolant.count),
                    .measured,
                    "From the coolant temperature your vehicle reported on \(withCoolant.count) drives.")
        }
        guard !trips.isEmpty else {
            return (nil, .unavailable, "No drives to assess.")
        }
        let longEnough = trips.filter { $0.totalDurationSeconds >= inferredWarmUpSeconds }
        return (Double(longEnough.count) / Double(trips.count),
                .inferred,
                "Your vehicle didn't report coolant temperature on most of these drives, so this is inferred from how long each drive lasted.")
    }

    static func status(shortFraction: Double, warmUpRate: Double?) -> SemanticStatus {
        guard let warmUpRate else {
            return shortFraction >= 0.7 ? .watch : .normal
        }
        if shortFraction >= 0.65 && warmUpRate <= 0.4 { return .attention }
        if shortFraction >= 0.5 || warmUpRate <= 0.5 { return .watch }
        return .normal
    }

    private static func copy(status: SemanticStatus,
                             shortFraction: Double,
                             warmUpRate: Double?,
                             tripCount: Int,
                             hasDPFTelemetry: Bool) -> (headline: String, explanation: String, recommendation: String?) {
        let shortPercent = Int((shortFraction * 100).rounded())

        // The caveat that keeps this feature honest, attached wherever a driver might
        // otherwise read a filter condition into a driving pattern.
        let caveat = hasDPFTelemetry
            ? ""
            : " DriveLayer can't read your particulate filter's actual condition — no standard OBD-II parameter reports it — so this describes your driving pattern, not the filter."

        switch status {
        case .attention:
            return ("Mostly short drives",
                    "\(shortPercent)% of your last \(tripCount) drives were shorter than \(Int(shortTripThresholdKm)) km, and most appear not to have reached full operating temperature." + caveat,
                    "Diesels generally prefer an occasional longer run at steady speed. Your owner's manual has the manufacturer's guidance for this — follow that rather than a rule of thumb.")
        case .watch:
            return ("Watch your drive pattern",
                    "\(shortPercent)% of your last \(tripCount) drives were short journeys." + caveat,
                    "A longer run at steady speed now and then is worth planning in. Check your owner's manual for the manufacturer's specific advice.")
        default:
            return ("Normal",
                    "Your recent drives include enough longer journeys for the engine to reach and hold operating temperature." + caveat,
                    nil)
        }
    }
}
