import Foundation

/// Aggregate views over a set of drives. Every figure is optional: with no qualifying
/// drives the answer is "we don't know yet", not zero.
struct TripAnalytics: Sendable, Equatable {
    var tripCount: Int
    var totalDistanceKm: Double
    var totalDurationSeconds: TimeInterval
    var totalIdleSeconds: TimeInterval
    var totalFuelLitres: Double?
    var averageEconomyKmPerLitre: Double?
    var medianEconomyKmPerLitre: Double?
    var shortTripCount: Int
    var longestTripKm: Double?
    var averageTripKm: Double?
    var idleFraction: Double?

    /// Drives shorter than this are the ones that matter for diesel warm-up.
    static let shortTripThresholdKm: Double = 8

    static let empty = TripAnalytics(tripCount: 0,
                                     totalDistanceKm: 0,
                                     totalDurationSeconds: 0,
                                     totalIdleSeconds: 0,
                                     totalFuelLitres: nil,
                                     averageEconomyKmPerLitre: nil,
                                     medianEconomyKmPerLitre: nil,
                                     shortTripCount: 0,
                                     longestTripKm: nil,
                                     averageTripKm: nil,
                                     idleFraction: nil)

    static func summarise(_ trips: [Trip]) -> TripAnalytics {
        let completed = trips.filter(\.isComplete)
        guard !completed.isEmpty else { return .empty }

        let distances = completed.map(\.distanceKm)
        let totalDistance = distances.reduce(0, +)
        let totalDuration = completed.reduce(0) { $0 + $1.totalDurationSeconds }
        let totalIdle = completed.reduce(0) { $0 + $1.idleDurationSeconds }

        // Economy is computed per drive and then aggregated, rather than dividing two
        // totals: a single drive with unknown fuel would silently distort the ratio.
        let economies = completed.compactMap(\.economyKmPerLitre)
        let knownFuel = completed.compactMap { $0.fuelUsedLitres.value }

        return TripAnalytics(
            tripCount: completed.count,
            totalDistanceKm: totalDistance,
            totalDurationSeconds: totalDuration,
            totalIdleSeconds: totalIdle,
            totalFuelLitres: knownFuel.isEmpty ? nil : knownFuel.reduce(0, +),
            averageEconomyKmPerLitre: Statistics.mean(economies),
            medianEconomyKmPerLitre: Statistics.median(economies),
            shortTripCount: completed.filter { $0.distanceKm < shortTripThresholdKm }.count,
            longestTripKm: distances.max(),
            averageTripKm: Statistics.mean(distances),
            idleFraction: totalDuration > 0 ? totalIdle / totalDuration : nil
        )
    }

    /// Share of drives that were short. `nil` when there are no drives to divide by.
    var shortTripFraction: Double? {
        guard tripCount > 0 else { return nil }
        return Double(shortTripCount) / Double(tripCount)
    }
}

extension Array where Element == Trip {
    /// Drives that started within the window, newest first.
    func within(days: Int, of reference: Date, calendar: Calendar = .current) -> [Trip] {
        guard let cutoff = calendar.date(byAdding: .day, value: -days, to: reference) else { return [] }
        return filter { $0.startedAt >= cutoff && $0.startedAt <= reference }
            .sorted { $0.startedAt > $1.startedAt }
    }
}
