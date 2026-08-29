import Foundation

enum OBDValue: Equatable, Sendable {
    case number(Double)
    case text(String)
    case boolean(Bool)

    var doubleValue: Double? {
        if case let .number(value) = self { return value }
        return nil
    }
}

/// One decoded value from the vehicle, with enough context to display or store it
/// without consulting the catalog again.
struct OBDReading: Equatable, Sendable {
    let pid: OBDPID
    let name: String
    let metric: VehicleMetric?
    let value: OBDValue
    let unitLabel: String
    let timestamp: Date
    /// False when the value decoded correctly but falls outside the physically
    /// plausible band for that PID — a classic symptom of a cheap adapter or a
    /// dropped byte. Callers must not feed implausible readings into baselines.
    let isPlausible: Bool

    var numericValue: Double? { value.doubleValue }
}

/// How often a value is worth asking for. Coolant does not change in 200 ms and
/// polling it as if it does costs battery and bus bandwidth for nothing.
enum OBDRefreshClass: String, Codable, CaseIterable, Sendable {
    case fast      // driver-visible motion: rpm, speed, load
    case medium    // temperatures under load, throttle
    case slow      // fuel level, voltage, ambient
    case rare      // static or near-static values

    var interval: TimeInterval {
        switch self {
        case .fast: return 1.0
        case .medium: return 5.0
        case .slow: return 30.0
        case .rare: return 300.0
        }
    }

    /// Interval used when the app is backgrounded or the screen is off: everything
    /// slows down, nothing stops silently.
    var backgroundInterval: TimeInterval {
        switch self {
        case .fast: return 5.0
        case .medium: return 15.0
        case .slow: return 60.0
        case .rare: return 600.0
        }
    }
}
