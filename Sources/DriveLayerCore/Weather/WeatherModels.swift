import Foundation

enum WeatherConditionKind: String, Codable, CaseIterable, Sendable {
    case clear, partlyCloudy, cloudy, drizzle, rain, heavyRain, thunderstorms
    case snow, sleet, hail, fog, haze, windy, unknown

    var displayName: String {
        switch self {
        case .clear: return "Clear"
        case .partlyCloudy: return "Partly cloudy"
        case .cloudy: return "Cloudy"
        case .drizzle: return "Drizzle"
        case .rain: return "Rain"
        case .heavyRain: return "Heavy rain"
        case .thunderstorms: return "Thunderstorms"
        case .snow: return "Snow"
        case .sleet: return "Sleet"
        case .hail: return "Hail"
        case .fog: return "Fog"
        case .haze: return "Haze"
        case .windy: return "Windy"
        case .unknown: return "Unknown"
        }
    }

    var symbolName: String {
        switch self {
        case .clear: return "sun.max"
        case .partlyCloudy: return "cloud.sun"
        case .cloudy: return "cloud"
        case .drizzle: return "cloud.drizzle"
        case .rain: return "cloud.rain"
        case .heavyRain: return "cloud.heavyrain"
        case .thunderstorms: return "cloud.bolt.rain"
        case .snow: return "cloud.snow"
        case .sleet: return "cloud.sleet"
        case .hail: return "cloud.hail"
        case .fog: return "cloud.fog"
        case .haze: return "sun.haze"
        case .windy: return "wind"
        case .unknown: return "questionmark.circle"
        }
    }

    /// Conditions that change how a road should be driven.
    var affectsDriving: Bool {
        switch self {
        case .clear, .partlyCloudy, .cloudy, .haze: return false
        case .drizzle, .rain, .heavyRain, .thunderstorms, .snow, .sleet, .hail, .fog, .windy: return true
        case .unknown: return false
        }
    }
}

struct WeatherSnapshot: Codable, Sendable, Equatable {
    var timestamp: Date
    var condition: WeatherConditionKind
    var temperatureC: Double?
    var apparentTemperatureC: Double?
    var precipitationIntensityMillimetresPerHour: Double?
    var precipitationChance: Double?
    var windSpeedKmh: Double?
    var windGustKmh: Double?
    var visibilityMetres: Double?
    var humidityFraction: Double?

    init(timestamp: Date,
         condition: WeatherConditionKind = .unknown,
         temperatureC: Double? = nil,
         apparentTemperatureC: Double? = nil,
         precipitationIntensityMillimetresPerHour: Double? = nil,
         precipitationChance: Double? = nil,
         windSpeedKmh: Double? = nil,
         windGustKmh: Double? = nil,
         visibilityMetres: Double? = nil,
         humidityFraction: Double? = nil) {
        self.timestamp = timestamp
        self.condition = condition
        self.temperatureC = temperatureC
        self.apparentTemperatureC = apparentTemperatureC
        self.precipitationIntensityMillimetresPerHour = precipitationIntensityMillimetresPerHour
        self.precipitationChance = precipitationChance
        self.windSpeedKmh = windSpeedKmh
        self.windGustKmh = windGustKmh
        self.visibilityMetres = visibilityMetres
        self.humidityFraction = humidityFraction
    }

    /// Rain intensity bands, in mm/h.
    var precipitationBand: PrecipitationBand {
        guard let intensity = precipitationIntensityMillimetresPerHour else { return .none }
        switch intensity {
        case ..<0.1: return .none
        case ..<2.5: return .light
        case ..<7.6: return .moderate
        default: return .heavy
        }
    }

    /// True when the combination suggests ice is plausible. Deliberately conservative:
    /// this is a "be aware", not a forecast of ice.
    var suggestsIceRisk: Bool {
        guard let temperature = temperatureC, temperature <= 2 else { return false }
        return precipitationBand != .none || condition == .fog || (humidityFraction ?? 0) > 0.9
    }

    var suggestsFogRisk: Bool {
        if condition == .fog { return true }
        guard let visibility = visibilityMetres else { return false }
        return visibility < 1_000
    }
}

enum PrecipitationBand: String, Codable, CaseIterable, Sendable, Comparable {
    case none, light, moderate, heavy

    var rank: Int {
        switch self {
        case .none: return 0
        case .light: return 1
        case .moderate: return 2
        case .heavy: return 3
        }
    }

    static func < (lhs: PrecipitationBand, rhs: PrecipitationBand) -> Bool { lhs.rank < rhs.rank }

    var displayName: String {
        switch self {
        case .none: return "No rain"
        case .light: return "Light rain"
        case .moderate: return "Rain"
        case .heavy: return "Heavy rain"
        }
    }
}

/// A point on the route with the weather expected when the driver reaches it.
struct RouteWeatherPoint: Sendable, Equatable {
    var distanceMetres: Double
    var expectedAt: Date
    var snapshot: WeatherSnapshot
}

struct WeatherAlertSummary: Sendable, Equatable, Identifiable, Codable {
    var id: String
    var headline: String
    var severityLabel: String
    var region: String?
    var effectiveUntil: Date?
}

/// Weather as DriveLayer needs it. WeatherKit sits behind this in the app target.
///
/// `isConfigured` exists because a weather service is a deployment decision. When it
/// is false the app says so and keeps working; it never falls back to invented data.
protocol WeatherProviding: Sendable {
    var isConfigured: Bool { get }
    func currentWeather(at point: GeoPoint) async throws -> WeatherSnapshot
    func hourlyForecast(at point: GeoPoint, hours: Int) async throws -> [WeatherSnapshot]
    func alerts(at point: GeoPoint) async throws -> [WeatherAlertSummary]
}

enum WeatherError: Error, Equatable, Sendable {
    case notConfigured
    case offline
    case rateLimited
    case failed(String)

    var userMessage: String {
        switch self {
        case .notConfigured: return "Weather isn't set up for this build of DriveLayer."
        case .offline: return "Weather needs a connection. Everything else keeps working."
        case .rateLimited: return "Weather is temporarily unavailable. It'll come back on its own."
        case let .failed(detail): return "Weather couldn't be loaded. \(detail)"
        }
    }
}
