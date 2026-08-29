import Foundation

/// Unit handling in one place. DriveLayer stores SI internally (metres, m/s,
/// Celsius, litres) and converts only at the presentation edge.
enum UnitSystem: String, Codable, CaseIterable, Sendable {
    case metric
    case imperial

    var distanceUnit: UnitLength { self == .metric ? .kilometers : .miles }
    var speedUnit: UnitSpeed { self == .metric ? .kilometersPerHour : .milesPerHour }
    var temperatureUnit: UnitTemperature { self == .metric ? .celsius : .fahrenheit }
    var volumeUnit: UnitVolume { self == .metric ? .liters : .gallons }
}

/// How fuel economy is expressed. India (the reference market) uses km/L.
enum EconomyUnit: String, Codable, CaseIterable, Sendable {
    case kilometresPerLitre
    case litresPer100km
    case milesPerGallonUS
    case milesPerGallonUK

    var shortLabel: String {
        switch self {
        case .kilometresPerLitre: return "km/L"
        case .litresPer100km: return "L/100km"
        case .milesPerGallonUS: return "mpg"
        case .milesPerGallonUK: return "mpg"
        }
    }

    /// Converts from the canonical internal representation (km per litre).
    /// Returns `nil` for non-positive input rather than infinity.
    func value(fromKilometresPerLitre kmpl: Double) -> Double? {
        guard kmpl > 0 else { return nil }
        switch self {
        case .kilometresPerLitre: return kmpl
        case .litresPer100km: return 100.0 / kmpl
        case .milesPerGallonUS: return kmpl * 2.352_145_8
        case .milesPerGallonUK: return kmpl * 2.824_810_5
        }
    }
}

enum Convert {
    static let metresPerSecondToKmh = 3.6

    static func kmh(fromMetresPerSecond value: Double) -> Double { value * metresPerSecondToKmh }
    static func metresPerSecond(fromKmh value: Double) -> Double { value / metresPerSecondToKmh }

    /// Gradient as a percentage from a rise over a run. Guards the zero-run case.
    static func gradientPercent(rise: Double, run: Double) -> Double? {
        guard run > 0.5 else { return nil }
        return (rise / run) * 100
    }
}
