import Foundation

/// Context used to choose the small set of CarPlay priorities. This is deliberately
/// deterministic and contains no language-model decision making.
enum CarPlayDriveState: String, Codable, Sendable, Equatable {
    case coldStart
    case highway
    case climb
    case lowFuel
    case fault
    case ordinary
}

enum CarPlayTile: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case health
    case warmUp
    case range
    case currentDrive
    case economy
    case terrain
    case destinationReserve
    case fuelRecommendation
    case fault
    case engine
}

struct CarPlayRankingInput: Sendable, Equatable {
    var state: CarPlayDriveState
    var available: Set<CarPlayTile>
    var urgentFault: Bool

    init(state: CarPlayDriveState,
         available: Set<CarPlayTile> = Set(CarPlayTile.allCases),
         urgentFault: Bool = false) {
        self.state = state
        self.available = available
        self.urgentFault = urgentFault
    }
}

/// Orders tiles and holds a prior order for a minimum lifetime, preventing a driver
/// from seeing the CarPlay hierarchy reshuffle on every telemetry tick.
struct CarPlayRankingEngine: Sendable {
    var minimumPresentationLifetime: TimeInterval
    private(set) var lastRanking: [CarPlayTile] = []
    private(set) var rankingLockedUntil: Date?

    init(minimumPresentationLifetime: TimeInterval = 20) {
        self.minimumPresentationLifetime = minimumPresentationLifetime
    }

    mutating func rank(_ input: CarPlayRankingInput, at now: Date) -> [CarPlayTile] {
        if let rankingLockedUntil, now < rankingLockedUntil, !lastRanking.isEmpty {
            return lastRanking.filter(input.available.contains)
        }

        let preferred: [CarPlayTile]
        if input.urgentFault || input.state == .fault {
            preferred = [.fault, .health, .engine, .currentDrive]
        } else {
            switch input.state {
            case .coldStart: preferred = [.warmUp, .health, .range, .currentDrive]
            case .highway: preferred = [.health, .economy, .range, .currentDrive]
            case .climb: preferred = [.health, .engine, .terrain, .range]
            case .lowFuel: preferred = [.range, .destinationReserve, .fuelRecommendation, .health]
            case .ordinary: preferred = [.health, .range, .currentDrive, .economy]
            case .fault: preferred = [.fault, .health, .engine, .currentDrive]
            }
        }

        let result = preferred.filter(input.available.contains)
        lastRanking = result
        rankingLockedUntil = now.addingTimeInterval(minimumPresentationLifetime)
        return result
    }
}
