import Foundation

/// Identifies "the same journey again" without needing map matching.
///
/// Start and end points are snapped to a coarse grid — roughly 500 m — and combined
/// with a distance band. That is enough to recognise a commute while refusing to
/// merge two different drives that happen to start on the same street.
struct RouteSignature: Hashable, Sendable, Codable {
    var startCell: String
    var endCell: String

    /// Grid size in degrees. About 550 m of latitude.
    static let cellSizeDegrees: Double = 0.005

    static func cell(latitude: Double, longitude: Double) -> String {
        let latitudeCell = (latitude / cellSizeDegrees).rounded()
        let longitudeCell = (longitude / cellSizeDegrees).rounded()
        return "\(Int(latitudeCell)):\(Int(longitudeCell))"
    }

    init?(trip: Trip) {
        guard let startLatitude = trip.startLatitude,
              let startLongitude = trip.startLongitude,
              let endLatitude = trip.endLatitude,
              let endLongitude = trip.endLongitude else { return nil }
        self.startCell = Self.cell(latitude: startLatitude, longitude: startLongitude)
        self.endCell = Self.cell(latitude: endLatitude, longitude: endLongitude)
    }
}

/// How this drive compared with the driver's usual run of the same route.
///
/// The wording rules matter as much as the arithmetic. DriveLayer says "associated
/// with" and "likely influenced by", never "because": it has correlation, not cause.
struct TripComparison: Sendable, Equatable {
    var comparableTripCount: Int
    var durationSeconds: TimeInterval
    var typicalDurationSeconds: TimeInterval
    var economyKmPerLitre: Double?
    var typicalEconomyKmPerLitre: Double?
    var idleSeconds: TimeInterval
    var typicalIdleSeconds: TimeInterval

    var durationDeltaPercent: Double {
        guard typicalDurationSeconds > 0 else { return 0 }
        return (durationSeconds - typicalDurationSeconds) / typicalDurationSeconds * 100
    }

    var economyDeltaPercent: Double? {
        guard let economyKmPerLitre, let typicalEconomyKmPerLitre, typicalEconomyKmPerLitre > 0 else { return nil }
        return (economyKmPerLitre - typicalEconomyKmPerLitre) / typicalEconomyKmPerLitre * 100
    }

    var idleDeltaSeconds: TimeInterval { idleSeconds - typicalIdleSeconds }

    /// A sentence a driver would actually find useful, or `nil` when nothing about
    /// this drive stood out. Saying nothing is a valid, and often correct, output.
    var summary: String? {
        var clauses: [String] = []

        if let economyDelta = economyDeltaPercent, abs(economyDelta) >= 8 {
            let direction = economyDelta < 0 ? "lower" : "higher"
            clauses.append("Fuel economy was about \(Int(abs(economyDelta).rounded()))% \(direction) than your usual run of this route")
        } else if abs(durationDeltaPercent) >= 15 {
            let direction = durationDeltaPercent > 0 ? "longer" : "shorter"
            clauses.append("This drive took about \(Int(abs(durationDeltaPercent).rounded()))% \(direction) than usual")
        }

        guard !clauses.isEmpty else { return nil }

        // Only offer an association when the candidate explanation is itself unusual.
        let extraIdleMinutes = idleDeltaSeconds / 60
        if extraIdleMinutes >= 4 {
            clauses.append("associated with about \(Int(extraIdleMinutes.rounded())) more minutes of idling")
        } else if extraIdleMinutes <= -4 {
            clauses.append("associated with about \(Int(abs(extraIdleMinutes).rounded())) fewer minutes of idling")
        }

        return clauses.joined(separator: ", ") + "."
    }
}

enum TripComparisonEngine {

    /// How many previous drives are needed before "typical" means anything.
    static let minimumComparableTrips = 3
    /// Distances within this fraction of each other count as the same journey.
    static let distanceTolerance = 0.2

    /// Finds previous drives of the same journey.
    static func comparableTrips(to trip: Trip, in history: [Trip]) -> [Trip] {
        guard let signature = RouteSignature(trip: trip), trip.distanceMetres > 0 else { return [] }
        return history.filter { candidate in
            guard candidate.id != trip.id, candidate.isComplete else { return false }
            guard candidate.startedAt < trip.startedAt else { return false }
            guard let candidateSignature = RouteSignature(trip: candidate),
                  candidateSignature == signature else { return false }
            let ratio = candidate.distanceMetres / trip.distanceMetres
            return abs(ratio - 1) <= distanceTolerance
        }
    }

    /// Compares a drive with the driver's usual run of the same route.
    /// Returns `nil` when there isn't enough history to have a "usual".
    static func compare(_ trip: Trip, against history: [Trip]) -> TripComparison? {
        let comparable = comparableTrips(to: trip, in: history)
        guard comparable.count >= minimumComparableTrips else { return nil }

        let typicalDuration = Statistics.median(comparable.map(\.totalDurationSeconds)) ?? 0
        let typicalIdle = Statistics.median(comparable.map(\.idleDurationSeconds)) ?? 0
        let economies = comparable.compactMap(\.economyKmPerLitre)

        return TripComparison(
            comparableTripCount: comparable.count,
            durationSeconds: trip.totalDurationSeconds,
            typicalDurationSeconds: typicalDuration,
            economyKmPerLitre: trip.economyKmPerLitre,
            typicalEconomyKmPerLitre: economies.isEmpty ? nil : Statistics.median(economies),
            idleSeconds: trip.idleDurationSeconds,
            typicalIdleSeconds: typicalIdle
        )
    }
}
