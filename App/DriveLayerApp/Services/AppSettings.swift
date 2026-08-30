import Foundation
import SwiftUI

/// User preferences, including the privacy controls.
///
/// Everything here defaults to the least data-hungry option: automatic trip
/// detection is off until the driver turns it on, the simulator is off outside
/// debug builds, and retention is finite rather than forever.
@MainActor
@Observable
final class AppSettings {

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.unitSystem = UnitSystem(rawValue: defaults.string(forKey: Key.unitSystem) ?? "") ?? Self.localeDefaultUnitSystem
        self.economyUnit = EconomyUnit(rawValue: defaults.string(forKey: Key.economyUnit) ?? "") ?? Self.localeDefaultEconomyUnit
        self.automaticTripDetection = defaults.bool(forKey: Key.automaticTripDetection)
        self.liveActivitiesEnabled = defaults.object(forKey: Key.liveActivities) as? Bool ?? true
        self.roadImpactDetectionEnabled = defaults.bool(forKey: Key.roadImpactDetection)
        self.remindersEnabled = defaults.bool(forKey: Key.reminders)
        self.telemetryRetentionDays = defaults.object(forKey: Key.telemetryRetentionDays) as? Int ?? 180
        self.useSimulator = defaults.bool(forKey: Key.useSimulator)
        self.simulatorScenario = OBDScenarioID(rawValue: defaults.string(forKey: Key.simulatorScenario) ?? "") ?? .normalHighway
        self.hasCompletedOnboarding = defaults.bool(forKey: Key.hasCompletedOnboarding)
        self.lastAdapterIdentifier = defaults.string(forKey: Key.lastAdapter)
        self.lastAdapterName = defaults.string(forKey: Key.lastAdapterName)
    }

    private enum Key {
        static let unitSystem = "settings.unitSystem"
        static let economyUnit = "settings.economyUnit"
        static let automaticTripDetection = "settings.automaticTripDetection"
        static let liveActivities = "settings.liveActivities"
        static let roadImpactDetection = "settings.roadImpactDetection"
        static let reminders = "settings.reminders"
        static let telemetryRetentionDays = "settings.telemetryRetentionDays"
        static let useSimulator = "settings.useSimulator"
        static let simulatorScenario = "settings.simulatorScenario"
        static let hasCompletedOnboarding = "settings.hasCompletedOnboarding"
        static let lastAdapter = "settings.lastAdapter"
        static let lastAdapterName = "settings.lastAdapterName"
    }

    var unitSystem: UnitSystem { didSet { defaults.set(unitSystem.rawValue, forKey: Key.unitSystem) } }
    var economyUnit: EconomyUnit { didSet { defaults.set(economyUnit.rawValue, forKey: Key.economyUnit) } }
    var automaticTripDetection: Bool { didSet { defaults.set(automaticTripDetection, forKey: Key.automaticTripDetection) } }
    var liveActivitiesEnabled: Bool { didSet { defaults.set(liveActivitiesEnabled, forKey: Key.liveActivities) } }
    var roadImpactDetectionEnabled: Bool { didSet { defaults.set(roadImpactDetectionEnabled, forKey: Key.roadImpactDetection) } }
    var remindersEnabled: Bool { didSet { defaults.set(remindersEnabled, forKey: Key.reminders) } }
    var telemetryRetentionDays: Int { didSet { defaults.set(telemetryRetentionDays, forKey: Key.telemetryRetentionDays) } }
    var useSimulator: Bool { didSet { defaults.set(useSimulator, forKey: Key.useSimulator) } }
    var simulatorScenario: OBDScenarioID { didSet { defaults.set(simulatorScenario.rawValue, forKey: Key.simulatorScenario) } }
    var hasCompletedOnboarding: Bool { didSet { defaults.set(hasCompletedOnboarding, forKey: Key.hasCompletedOnboarding) } }
    var lastAdapterIdentifier: String? { didSet { defaults.set(lastAdapterIdentifier, forKey: Key.lastAdapter) } }
    var lastAdapterName: String? { didSet { defaults.set(lastAdapterName, forKey: Key.lastAdapterName) } }

    var formatter: DisplayFormatter {
        DisplayFormatter(unitSystem: unitSystem, economyUnit: economyUnit)
    }

    /// Retention choices offered in settings. "Keep everything" is deliberately not
    /// the default: telemetry the driver has no use for is a liability, not a feature.
    static let retentionChoices: [Int] = [30, 90, 180, 365]

    private static var localeDefaultUnitSystem: UnitSystem {
        Locale.current.measurementSystem == .metric ? .metric : .imperial
    }

    private static var localeDefaultEconomyUnit: EconomyUnit {
        switch Locale.current.region?.identifier {
        case "US": return .milesPerGallonUS
        case "GB": return .milesPerGallonUK
        case "IN", "PK", "BD", "LK", "NP": return .kilometresPerLitre
        default: return Locale.current.measurementSystem == .metric ? .litresPer100km : .milesPerGallonUS
        }
    }
}
