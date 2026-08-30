import Foundation

/// Where a fuel economy figure came from, in descending order of trust.
enum EconomySource: String, Sendable, Codable, CaseIterable {
    case fullTankHistory
    case recentTrips
    case singleTrip
    case none

    var explanation: String {
        switch self {
        case .fullTankHistory: return "your full-tank refuelling history"
        case .recentTrips: return "your recent drives"
        case .singleTrip: return "your last drive"
        case .none: return "no data yet"
        }
    }
}

/// The current fuel picture. Every figure is `Provenanced`: level may be measured,
/// litres and range are always derived, and any of them can be genuinely unavailable.
struct FuelStatus: Sendable, Equatable {
    var levelPercent: Provenanced<Double>
    var litresRemaining: Provenanced<Double>
    var estimatedRangeKm: Provenanced<Double>
    var economyKmPerLitre: Double?
    var economySource: EconomySource
    var tankCapacityLitres: Double?

    static let unknown = FuelStatus(levelPercent: .unavailable(),
                                    litresRemaining: .unavailable(),
                                    estimatedRangeKm: .unavailable(),
                                    economyKmPerLitre: nil,
                                    economySource: .none,
                                    tankCapacityLitres: nil)

    /// Below this, the low-fuel insight fires.
    var isLow: Bool {
        guard let level = levelPercent.value else { return false }
        return level <= 12
    }
}

/// Range estimation and "can I get there?" answers.
///
/// Everything here is an estimate and is labelled as one. A range figure that looks
/// like a measurement is worse than no range figure: drivers act on it.
enum FuelIntelligence {

    /// Manufacturers reserve roughly this share of the tank below the gauge's zero.
    /// DriveLayer does not count it as usable range.
    static let unusableTankFraction: Double = 0.08

    static func status(levelPercent: Provenanced<Double>,
                       tankCapacityLitres: Double?,
                       economy: (value: Double, source: EconomySource)?) -> FuelStatus {
        guard let level = levelPercent.value, let capacity = tankCapacityLitres, capacity > 0 else {
            return FuelStatus(levelPercent: levelPercent,
                              litresRemaining: .unavailable(basis: tankCapacityLitres == nil
                                                            ? "Add your tank size to see litres and range."
                                                            : "Your vehicle isn't reporting a fuel level."),
                              estimatedRangeKm: .unavailable(basis: "Range needs a fuel level and a tank size."),
                              economyKmPerLitre: economy?.value,
                              economySource: economy?.source ?? .none,
                              tankCapacityLitres: tankCapacityLitres)
        }

        let litres = capacity * Statistics.clamp(level, 0...100) / 100
        let usableLitres = max(0, litres - capacity * unusableTankFraction)
        let litresValue = Provenanced.estimated(litres,
                                                basis: "From your vehicle's reported tank level and a \(Int(capacity)) L tank.")

        guard let economy, economy.value > 0 else {
            return FuelStatus(levelPercent: levelPercent,
                              litresRemaining: litresValue,
                              estimatedRangeKm: .unavailable(basis: "DriveLayer needs a few drives before it can estimate range."),
                              economyKmPerLitre: nil,
                              economySource: .none,
                              tankCapacityLitres: capacity)
        }

        let range = usableLitres * economy.value
        return FuelStatus(levelPercent: levelPercent,
                          litresRemaining: litresValue,
                          estimatedRangeKm: .estimated(range,
                                                       basis: "Based on \(economy.source.explanation), and excluding the bottom of the tank."),
                          economyKmPerLitre: economy.value,
                          economySource: economy.source,
                          tankCapacityLitres: capacity)
    }

    /// Chooses the best available economy figure and says where it came from.
    static func bestEconomy(fuelEntries: [FuelEntry], recentTrips: [Trip]) -> (value: Double, source: EconomySource)? {
        let fullTank = FuelCalculations.representativeEconomy(from: FuelCalculations.economyResults(from: fuelEntries))
        if let fullTank, fullTank > 0 { return (fullTank, .fullTankHistory) }

        let tripEconomies = recentTrips
            .sorted { $0.startedAt > $1.startedAt }
            .prefix(10)
            .compactMap(\.economyKmPerLitre)
        if tripEconomies.count >= 3, let median = Statistics.median(Array(tripEconomies)) {
            return (median, .recentTrips)
        }
        if let single = tripEconomies.first {
            return (single, .singleTrip)
        }
        return nil
    }

    enum ReserveVerdict: Sendable, Equatable {
        case comfortable(reserveKm: Double)
        case tight(reserveKm: Double)
        case insufficient(shortfallKm: Double)
        case unknown

        var status: SemanticStatus {
            switch self {
            case .comfortable: return .normal
            case .tight: return .watch
            case .insufficient: return .attention
            case .unknown: return .unknown
            }
        }
    }

    /// Whether a journey is reachable on the fuel on board.
    static func assessJourney(distanceKm: Double, status: FuelStatus) -> ReserveVerdict {
        guard let range = status.estimatedRangeKm.value else { return .unknown }
        let reserve = range - distanceKm
        if reserve < 0 { return .insufficient(shortfallKm: -reserve) }
        // A tenth of the journey, or 30 km, whichever is larger, is the comfort margin.
        let comfortMargin = max(30, distanceKm * 0.1)
        return reserve >= comfortMargin ? .comfortable(reserveKm: reserve) : .tight(reserveKm: reserve)
    }

    /// User-facing sentence for a journey assessment. Always says "estimated".
    static func journeyMessage(distanceKm: Double, status: FuelStatus) -> String {
        switch assessJourney(distanceKm: distanceKm, status: status) {
        case let .comfortable(reserve):
            return String(format: "You can reach your destination with roughly %.0f km of estimated reserve.", reserve)
        case let .tight(reserve):
            return String(format: "Your destination is reachable, but with only about %.0f km of estimated reserve. Consider fuelling on the way.", reserve)
        case let .insufficient(shortfall):
            return String(format: "On the current estimate you'd be about %.0f km short. Plan a fuel stop.", shortfall)
        case .unknown:
            return "DriveLayer doesn't have enough information to estimate whether you can reach your destination."
        }
    }
}
