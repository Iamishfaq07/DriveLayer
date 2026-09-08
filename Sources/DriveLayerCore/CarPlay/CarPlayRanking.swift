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
    case battery
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
        let isUrgent = input.urgentFault || input.state == .fault
        let preferred = preferredRanking(for: input)
        if !isUrgent, let rankingLockedUntil, now < rankingLockedUntil, !lastRanking.isEmpty {
            var held = lastRanking.filter(input.available.contains)
            held.append(contentsOf: preferred.filter { input.available.contains($0) && !held.contains($0) })
            lastRanking = held
            return held
        }

        let result = preferred.filter(input.available.contains)
        lastRanking = result
        rankingLockedUntil = now.addingTimeInterval(minimumPresentationLifetime)
        return result
    }

    private func preferredRanking(for input: CarPlayRankingInput) -> [CarPlayTile] {
        if input.urgentFault || input.state == .fault {
            return [.fault, .health, .engine, .battery, .currentDrive]
        }
            switch input.state {
            case .coldStart: return [.warmUp, .health, .range, .battery, .currentDrive]
            case .highway: return [.health, .economy, .range, .battery, .currentDrive]
            case .climb: return [.health, .engine, .terrain, .range, .battery]
            case .lowFuel: return [.range, .destinationReserve, .fuelRecommendation, .health]
            case .ordinary: return [.health, .range, .currentDrive, .battery, .economy]
            case .fault: return [.fault, .health, .engine, .battery, .currentDrive]
            }
    }
}

enum CarPlayStateResolver {
    static func resolve(_ context: InsightContext, insights: [DriveInsight]) -> CarPlayDriveState {
        if insights.contains(where: { $0.severity >= .attention }) || !context.troubleCodes.isEmpty {
            return .fault
        }
        if context.fuelStatus?.isLow == true { return .lowFuel }
        if let coolant = context.trustedEntry(.coolantTemperatureC, freshWithin: 60),
           EngineThermalModel.phase(coolantC: coolant.value, profile: context.profile) != .operating {
            return .coldStart
        }
        if (context.gradient?.percent ?? 0) >= 3 { return .climb }
        if context.isDriving, (context.trustedEntry(.vehicleSpeedKmh, freshWithin: 15)?.value ?? 0) >= 80 {
            return .highway
        }
        return .ordinary
    }
}
