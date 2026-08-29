import Foundation

/// A weather provider for development, previews and the Debug Center.
///
/// It is explicitly a mock: `isConfigured` is true so the UI can be exercised, but the
/// Debug Center labels it, and it is never wired up in a release configuration.
struct MockWeatherProvider: WeatherProviding, Sendable {

    enum Scenario: String, CaseIterable, Sendable, Identifiable {
        case clear
        case rainAhead
        case heavyRainAhead
        case fogAhead
        case nearFreezing
        case unavailable

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .clear: return "Clear"
            case .rainAhead: return "Rain in ~22 km"
            case .heavyRainAhead: return "Heavy rain in ~14 km"
            case .fogAhead: return "Fog ahead"
            case .nearFreezing: return "Near freezing"
            case .unavailable: return "Provider unavailable"
            }
        }
    }

    let scenario: Scenario
    let now: @Sendable () -> Date

    init(scenario: Scenario = .rainAhead, now: @escaping @Sendable () -> Date = { Date() }) {
        self.scenario = scenario
        self.now = now
    }

    var isConfigured: Bool { scenario != .unavailable }

    func currentWeather(at point: GeoPoint) async throws -> WeatherSnapshot {
        guard isConfigured else { throw WeatherError.notConfigured }
        switch scenario {
        case .nearFreezing:
            return WeatherSnapshot(timestamp: now(), condition: .cloudy, temperatureC: 1.5,
                                   precipitationIntensityMillimetresPerHour: 0,
                                   visibilityMetres: 6_000, humidityFraction: 0.92)
        case .fogAhead:
            return WeatherSnapshot(timestamp: now(), condition: .partlyCloudy, temperatureC: 17,
                                   precipitationIntensityMillimetresPerHour: 0, visibilityMetres: 9_000)
        default:
            return WeatherSnapshot(timestamp: now(), condition: .partlyCloudy, temperatureC: 26,
                                   apparentTemperatureC: 28,
                                   precipitationIntensityMillimetresPerHour: 0,
                                   precipitationChance: 0.2,
                                   windSpeedKmh: 12, visibilityMetres: 12_000, humidityFraction: 0.55)
        }
    }

    func hourlyForecast(at point: GeoPoint, hours: Int) async throws -> [WeatherSnapshot] {
        guard isConfigured else { throw WeatherError.notConfigured }
        let start = now()
        return (0..<max(1, hours)).map { hour in
            var snapshot = WeatherSnapshot(timestamp: start.addingTimeInterval(Double(hour) * 3_600),
                                           condition: .partlyCloudy, temperatureC: 26 - Double(hour) * 0.4)
            if scenario == .rainAhead && hour >= 1 {
                snapshot.condition = .rain
                snapshot.precipitationIntensityMillimetresPerHour = 3.2
            }
            if scenario == .heavyRainAhead && hour >= 1 {
                snapshot.condition = .heavyRain
                snapshot.precipitationIntensityMillimetresPerHour = 11
            }
            return snapshot
        }
    }

    func alerts(at point: GeoPoint) async throws -> [WeatherAlertSummary] {
        guard isConfigured else { throw WeatherError.notConfigured }
        return []
    }

    /// A synthetic route forecast, used by previews and the Debug Center.
    func routeWeather(distances: [Double]) -> [RouteWeatherPoint] {
        let start = now()
        return distances.map { distance in
            var snapshot = WeatherSnapshot(timestamp: start, condition: .partlyCloudy, temperatureC: 26,
                                           precipitationIntensityMillimetresPerHour: 0, visibilityMetres: 12_000)
            switch scenario {
            case .rainAhead where distance >= 22_000:
                snapshot.condition = .rain
                snapshot.precipitationIntensityMillimetresPerHour = 3.4
            case .heavyRainAhead where distance >= 14_000:
                snapshot.condition = .heavyRain
                snapshot.precipitationIntensityMillimetresPerHour = 12
            case .fogAhead where distance >= 9_000:
                snapshot.condition = .fog
                snapshot.visibilityMetres = 350
            case .nearFreezing:
                snapshot.temperatureC = 1.0
                snapshot.humidityFraction = 0.95
            default:
                break
            }
            let seconds = distance / Convert.metresPerSecond(fromKmh: 80)
            return RouteWeatherPoint(distanceMetres: distance,
                                     expectedAt: start.addingTimeInterval(seconds),
                                     snapshot: snapshot)
        }
    }
}
