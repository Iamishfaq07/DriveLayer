import Foundation

enum TripEndReason: String, Codable, CaseIterable, Sendable {
    case stoppedMoving
    case engineOff
    case manual
    /// The app was terminated mid-drive and the trip was closed from its last sample.
    case recoveredAfterInterruption
    case discardedTooShort
}

enum TripEventKind: String, Codable, CaseIterable, Sendable {
    case hardBraking
    case rapidAcceleration
    case longIdle
    case climbStarted
    case descentStarted
    case coolantAboveNormal
    case lowBatteryVoltage
    case roadImpact
    case adapterDisconnected
    case adapterReconnected
    case troubleCodeAppeared
    case fuelLow

    var displayName: String {
        switch self {
        case .hardBraking: return "Hard braking"
        case .rapidAcceleration: return "Rapid acceleration"
        case .longIdle: return "Long idle"
        case .climbStarted: return "Climb"
        case .descentStarted: return "Descent"
        case .coolantAboveNormal: return "Coolant above normal"
        case .lowBatteryVoltage: return "Low battery voltage"
        case .roadImpact: return "Road impact"
        case .adapterDisconnected: return "Adapter disconnected"
        case .adapterReconnected: return "Adapter reconnected"
        case .troubleCodeAppeared: return "Trouble code"
        case .fuelLow: return "Fuel low"
        }
    }

    var symbolName: String {
        switch self {
        case .hardBraking: return "exclamationmark.brakesignal"
        case .rapidAcceleration: return "gauge.with.dots.needle.67percent"
        case .longIdle: return "clock.badge.exclamationmark"
        case .climbStarted: return "arrow.up.right"
        case .descentStarted: return "arrow.down.right"
        case .coolantAboveNormal: return "thermometer.high"
        case .lowBatteryVoltage: return "minus.plus.batteryblock"
        case .roadImpact: return "road.lanes"
        case .adapterDisconnected: return "antenna.radiowaves.left.and.right.slash"
        case .adapterReconnected: return "antenna.radiowaves.left.and.right"
        case .troubleCodeAppeared: return "wrench.and.screwdriver"
        case .fuelLow: return "fuelpump"
        }
    }
}

struct TripEvent: Codable, Sendable, Equatable, Identifiable {
    var id: UUID
    var kind: TripEventKind
    var timestamp: Date
    var severity: SemanticStatus
    var note: String
    var latitude: Double?
    var longitude: Double?

    init(id: UUID = UUID(),
         kind: TripEventKind,
         timestamp: Date,
         severity: SemanticStatus = .watch,
         note: String,
         latitude: Double? = nil,
         longitude: Double? = nil) {
        self.id = id
        self.kind = kind
        self.timestamp = timestamp
        self.severity = severity
        self.note = note
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// Weather as it was during the drive, captured once rather than re-fetched later.
struct TripWeatherSummary: Codable, Sendable, Equatable {
    var temperatureC: Double?
    var conditionDescription: String?
    var precipitationIntensityMillimetresPerHour: Double?
    var visibilityMetres: Double?
}

/// A completed or in-progress drive.
///
/// Fuel is a `Provenanced` value, not a bare number: on a car that reports fuel rate
/// it is integrated from a measured signal, on one that only reports tank level it
/// comes from the level change, and on a phone-only drive it is unavailable. The UI
/// must be able to tell those apart.
struct Trip: Codable, Sendable, Equatable, Identifiable {
    var id: UUID
    var vehicleID: UUID
    var startedAt: Date
    var endedAt: Date?
    var endReason: TripEndReason?

    var distanceMetres: Double
    var movingDurationSeconds: TimeInterval
    var idleDurationSeconds: TimeInterval

    var elevationGainMetres: Double
    var elevationLossMetres: Double
    var maximumAltitudeMetres: Double?
    var minimumAltitudeMetres: Double?

    var maximumSpeedKmh: Double?
    var averageMovingSpeedKmh: Double?

    var startOdometerKm: Double?
    var fuelUsedLitres: Provenanced<Double>

    var startLatitude: Double?
    var startLongitude: Double?
    var endLatitude: Double?
    var endLongitude: Double?
    var startPlaceName: String?
    var endPlaceName: String?

    /// A downsampled polyline, enough to draw the route without storing every fix.
    var routePolyline: [RoutePoint]
    var events: [TripEvent]
    var weather: TripWeatherSummary?
    var telemetrySampleCount: Int
    /// Peak and average engine values, kept on the trip so the detail screen does not
    /// have to decode the whole telemetry blob.
    var peakCoolantTemperatureC: Double?
    var averageEngineLoadPercent: Double?
    var minimumControlModuleVoltage: Double?

    struct RoutePoint: Codable, Sendable, Equatable {
        var latitude: Double
        var longitude: Double
        var altitudeMetres: Double?
        var timestamp: Date
    }

    init(id: UUID = UUID(),
         vehicleID: UUID,
         startedAt: Date,
         endedAt: Date? = nil,
         endReason: TripEndReason? = nil,
         distanceMetres: Double = 0,
         movingDurationSeconds: TimeInterval = 0,
         idleDurationSeconds: TimeInterval = 0,
         elevationGainMetres: Double = 0,
         elevationLossMetres: Double = 0,
         maximumAltitudeMetres: Double? = nil,
         minimumAltitudeMetres: Double? = nil,
         maximumSpeedKmh: Double? = nil,
         averageMovingSpeedKmh: Double? = nil,
         startOdometerKm: Double? = nil,
         fuelUsedLitres: Provenanced<Double> = .unavailable(),
         startLatitude: Double? = nil,
         startLongitude: Double? = nil,
         endLatitude: Double? = nil,
         endLongitude: Double? = nil,
         startPlaceName: String? = nil,
         endPlaceName: String? = nil,
         routePolyline: [RoutePoint] = [],
         events: [TripEvent] = [],
         weather: TripWeatherSummary? = nil,
         telemetrySampleCount: Int = 0,
         peakCoolantTemperatureC: Double? = nil,
         averageEngineLoadPercent: Double? = nil,
         minimumControlModuleVoltage: Double? = nil) {
        self.id = id
        self.vehicleID = vehicleID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.endReason = endReason
        self.distanceMetres = distanceMetres
        self.movingDurationSeconds = movingDurationSeconds
        self.idleDurationSeconds = idleDurationSeconds
        self.elevationGainMetres = elevationGainMetres
        self.elevationLossMetres = elevationLossMetres
        self.maximumAltitudeMetres = maximumAltitudeMetres
        self.minimumAltitudeMetres = minimumAltitudeMetres
        self.maximumSpeedKmh = maximumSpeedKmh
        self.averageMovingSpeedKmh = averageMovingSpeedKmh
        self.startOdometerKm = startOdometerKm
        self.fuelUsedLitres = fuelUsedLitres
        self.startLatitude = startLatitude
        self.startLongitude = startLongitude
        self.endLatitude = endLatitude
        self.endLongitude = endLongitude
        self.startPlaceName = startPlaceName
        self.endPlaceName = endPlaceName
        self.routePolyline = routePolyline
        self.events = events
        self.weather = weather
        self.telemetrySampleCount = telemetrySampleCount
        self.peakCoolantTemperatureC = peakCoolantTemperatureC
        self.averageEngineLoadPercent = averageEngineLoadPercent
        self.minimumControlModuleVoltage = minimumControlModuleVoltage
    }

    var isComplete: Bool { endedAt != nil }

    var distanceKm: Double { distanceMetres / 1_000 }

    var totalDurationSeconds: TimeInterval {
        guard let endedAt else { return movingDurationSeconds + idleDurationSeconds }
        return endedAt.timeIntervalSince(startedAt)
    }

    /// Share of the drive spent stationary with the engine running.
    var idleFraction: Double? {
        let total = totalDurationSeconds
        guard total > 0 else { return nil }
        return Statistics.clamp(idleDurationSeconds / total, 0...1)
    }

    /// Fuel economy in km/L. `nil` — never zero — when fuel use is unknown or the
    /// drive is too short for the number to mean anything.
    var economyKmPerLitre: Double? {
        guard let litres = fuelUsedLitres.value, litres > 0.05, distanceMetres > 500 else { return nil }
        return distanceKm / litres
    }

    var averageSpeedKmh: Double? {
        let total = totalDurationSeconds
        guard total > 0, distanceMetres > 0 else { return nil }
        return (distanceMetres / total) * 3.6
    }
}

extension Provenanced: Codable where Value: Codable {}
