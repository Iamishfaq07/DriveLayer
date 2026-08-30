import Foundation

/// A refuelling. `isFullTank` matters more than it looks: full-to-full is the only
/// way to measure real economy, so partial fills are recorded for cost but excluded
/// from economy maths.
struct FuelEntry: Codable, Sendable, Equatable, Identifiable {
    var id: UUID
    var vehicleID: UUID
    var date: Date
    var litres: Double
    var pricePerLitre: Double?
    var totalCost: Double?
    var odometerKm: Double?
    var isFullTank: Bool
    var stationName: String?
    var note: String?

    init(id: UUID = UUID(),
         vehicleID: UUID,
         date: Date,
         litres: Double,
         pricePerLitre: Double? = nil,
         totalCost: Double? = nil,
         odometerKm: Double? = nil,
         isFullTank: Bool = true,
         stationName: String? = nil,
         note: String? = nil) {
        self.id = id
        self.vehicleID = vehicleID
        self.date = date
        self.litres = litres
        self.pricePerLitre = pricePerLitre
        self.totalCost = totalCost ?? pricePerLitre.map { $0 * litres }
        self.odometerKm = odometerKm
        self.isFullTank = isFullTank
        self.stationName = stationName
        self.note = note
    }

    var resolvedPricePerLitre: Double? {
        if let pricePerLitre { return pricePerLitre }
        guard let totalCost, litres > 0 else { return nil }
        return totalCost / litres
    }
}

/// Economy measured between two full tanks.
struct FuelEconomyResult: Sendable, Equatable, Identifiable {
    var id: UUID
    var fromDate: Date
    var toDate: Date
    var distanceKm: Double
    var litres: Double
    var kilometresPerLitre: Double
    var costPerKilometre: Double?
}

enum FuelCalculations {

    /// Computes economy over each full-to-full interval.
    ///
    /// Requires odometer readings on both ends, so entries without one are skipped
    /// rather than estimated. Partial fills between two full tanks are added to the
    /// litres consumed, which is the standard method.
    static func economyResults(from entries: [FuelEntry]) -> [FuelEconomyResult] {
        let ordered = entries
            .filter { $0.litres > 0 }
            .sorted { $0.date < $1.date }
        guard ordered.count >= 2 else { return [] }

        var results: [FuelEconomyResult] = []
        var anchor: FuelEntry?
        var litresSinceAnchor: Double = 0

        for entry in ordered {
            guard let start = anchor else {
                if entry.isFullTank && entry.odometerKm != nil { anchor = entry }
                continue
            }
            litresSinceAnchor += entry.litres
            guard entry.isFullTank else { continue }
            guard let startOdometer = start.odometerKm,
                  let endOdometer = entry.odometerKm,
                  endOdometer > startOdometer else {
                // Without a usable pair of odometer readings this interval is skipped,
                // and the tank we just filled becomes the new anchor.
                anchor = entry.isFullTank && entry.odometerKm != nil ? entry : anchor
                litresSinceAnchor = 0
                continue
            }
            let distance = endOdometer - startOdometer
            if litresSinceAnchor > 0, distance > 0 {
                let economy = distance / litresSinceAnchor
                let cost = entry.resolvedPricePerLitre.map { $0 * litresSinceAnchor / distance }
                results.append(FuelEconomyResult(id: entry.id,
                                                 fromDate: start.date,
                                                 toDate: entry.date,
                                                 distanceKm: distance,
                                                 litres: litresSinceAnchor,
                                                 kilometresPerLitre: economy,
                                                 costPerKilometre: cost))
            }
            anchor = entry
            litresSinceAnchor = 0
        }
        return results
    }

    /// Total spend over a period.
    static func totalSpend(entries: [FuelEntry], since: Date, until: Date) -> Double? {
        let costs = entries
            .filter { $0.date >= since && $0.date <= until }
            .compactMap(\.totalCost)
        guard !costs.isEmpty else { return nil }
        return costs.reduce(0, +)
    }

    /// The economy figure to use for range estimates, newest intervals weighted first.
    /// `nil` when there is nothing to base it on — never a made-up default.
    static func representativeEconomy(from results: [FuelEconomyResult]) -> Double? {
        let recent = results.sorted { $0.toDate > $1.toDate }.prefix(6).map(\.kilometresPerLitre)
        return Statistics.median(Array(recent))
    }
}
