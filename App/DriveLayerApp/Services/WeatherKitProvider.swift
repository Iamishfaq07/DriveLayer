import Foundation
import CoreLocation
#if canImport(WeatherKit)
import WeatherKit
#endif

/// WeatherKit behind the core's `WeatherProviding` protocol.
///
/// `isConfigured` is driven by an Info.plist flag rather than assumed, because
/// WeatherKit needs a paid capability on the developer account. Without it the app
/// says "Weather isn't set up" and everything else keeps working — which is the
/// honest behaviour, and better than a screen full of errors from a missing
/// entitlement.
struct WeatherKitProvider: WeatherProviding {

    let isConfigured: Bool

    init(isConfigured: Bool? = nil) {
        if let isConfigured {
            self.isConfigured = isConfigured
        } else {
            self.isConfigured = (Bundle.main.object(forInfoDictionaryKey: "DLWeatherKitEnabled") as? Bool) ?? false
        }
    }

    #if canImport(WeatherKit)
    private var service: WeatherService { WeatherService.shared }
    #endif

    func currentWeather(at point: GeoPoint) async throws -> WeatherSnapshot {
        guard isConfigured else { throw WeatherError.notConfigured }
        #if canImport(WeatherKit)
        do {
            let weather = try await service.weather(for: location(from: point), including: .current)
            return Self.snapshot(from: weather)
        } catch {
            throw WeatherError.failed(error.localizedDescription)
        }
        #else
        throw WeatherError.notConfigured
        #endif
    }

    func hourlyForecast(at point: GeoPoint, hours: Int) async throws -> [WeatherSnapshot] {
        guard isConfigured else { throw WeatherError.notConfigured }
        #if canImport(WeatherKit)
        do {
            let forecast = try await service.weather(for: location(from: point), including: .hourly)
            return forecast.forecast.prefix(max(1, hours)).map(Self.snapshot(from:))
        } catch {
            throw WeatherError.failed(error.localizedDescription)
        }
        #else
        throw WeatherError.notConfigured
        #endif
    }

    func alerts(at point: GeoPoint) async throws -> [WeatherAlertSummary] {
        guard isConfigured else { throw WeatherError.notConfigured }
        #if canImport(WeatherKit)
        do {
            let alerts = try await service.weather(for: location(from: point), including: .alerts)
            return (alerts ?? []).map { alert in
                WeatherAlertSummary(id: alert.detailsURL.absoluteString,
                                    headline: alert.summary,
                                    severityLabel: "\(alert.severity)",
                                    region: alert.region,
                                    effectiveUntil: nil)
            }
        } catch {
            throw WeatherError.failed(error.localizedDescription)
        }
        #else
        throw WeatherError.notConfigured
        #endif
    }

    #if canImport(WeatherKit)
    private func location(from point: GeoPoint) -> CLLocation {
        CLLocation(latitude: point.latitude, longitude: point.longitude)
    }

    private static func snapshot(from weather: CurrentWeather) -> WeatherSnapshot {
        WeatherSnapshot(timestamp: weather.date,
                        condition: condition(from: weather.condition),
                        temperatureC: weather.temperature.converted(to: .celsius).value,
                        apparentTemperatureC: weather.apparentTemperature.converted(to: .celsius).value,
                        precipitationIntensityMillimetresPerHour: nil,
                        precipitationChance: nil,
                        windSpeedKmh: weather.wind.speed.converted(to: .kilometersPerHour).value,
                        windGustKmh: weather.wind.gust?.converted(to: .kilometersPerHour).value,
                        visibilityMetres: weather.visibility.converted(to: .meters).value,
                        humidityFraction: weather.humidity)
    }

    private static func snapshot(from hour: HourWeather) -> WeatherSnapshot {
        WeatherSnapshot(timestamp: hour.date,
                        condition: condition(from: hour.condition),
                        temperatureC: hour.temperature.converted(to: .celsius).value,
                        apparentTemperatureC: hour.apparentTemperature.converted(to: .celsius).value,
                        precipitationIntensityMillimetresPerHour: hour.precipitationIntensity.converted(to: .millimetersPerHour).value,
                        precipitationChance: hour.precipitationChance,
                        windSpeedKmh: hour.wind.speed.converted(to: .kilometersPerHour).value,
                        windGustKmh: hour.wind.gust?.converted(to: .kilometersPerHour).value,
                        visibilityMetres: hour.visibility.converted(to: .meters).value,
                        humidityFraction: hour.humidity)
    }

    /// Maps WeatherKit's long condition list onto the handful of cases DriveLayer
    /// actually behaves differently for.
    private static func condition(from condition: WeatherCondition) -> WeatherConditionKind {
        switch condition {
        case .clear, .mostlyClear, .hot: return .clear
        case .partlyCloudy: return .partlyCloudy
        case .cloudy, .mostlyCloudy: return .cloudy
        case .drizzle, .freezingDrizzle: return .drizzle
        case .rain, .sunShowers, .freezingRain: return .rain
        case .heavyRain: return .heavyRain
        case .thunderstorms, .isolatedThunderstorms, .scatteredThunderstorms, .strongStorms: return .thunderstorms
        case .snow, .heavySnow, .flurries, .blizzard, .blowingSnow, .sunFlurries, .wintryMix: return .snow
        case .sleet: return .sleet
        case .hail: return .hail
        case .foggy: return .fog
        case .haze, .smoky: return .haze
        case .windy, .breezy: return .windy
        default: return .unknown
        }
    }
    #endif
}
