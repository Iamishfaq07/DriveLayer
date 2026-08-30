import Foundation

/// Turns core values into display strings in the driver's chosen units.
///
/// Every method returns an optional where the underlying value can be absent, so a
/// formatter can never be the place a missing reading becomes "0".
struct DisplayFormatter: Sendable {

    var unitSystem: UnitSystem
    var economyUnit: EconomyUnit
    var locale: Locale

    init(unitSystem: UnitSystem = .metric,
         economyUnit: EconomyUnit = .kilometresPerLitre,
         locale: Locale = .autoupdatingCurrent) {
        self.unitSystem = unitSystem
        self.economyUnit = economyUnit
        self.locale = locale
    }

    private func number(_ value: Double, fractionDigits: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = fractionDigits
        formatter.maximumFractionDigits = fractionDigits
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.\(fractionDigits)f", value)
    }

    // MARK: - Distance and speed

    func distance(metres: Double?, fractionDigits: Int? = nil) -> String? {
        guard let metres else { return nil }
        return distance(kilometres: metres / 1_000, fractionDigits: fractionDigits)
    }

    func distance(kilometres: Double?, fractionDigits: Int? = nil) -> String? {
        guard let kilometres else { return nil }
        let value = unitSystem == .metric ? kilometres : kilometres * 0.621_371
        // Long distances do not need a decimal; short ones are useless without it.
        let digits = fractionDigits ?? (abs(value) >= 100 ? 0 : 1)
        return number(value, fractionDigits: digits)
    }

    var distanceUnitLabel: String { unitSystem == .metric ? "km" : "mi" }

    func speed(kmh: Double?) -> String? {
        guard let kmh else { return nil }
        return number(unitSystem == .metric ? kmh : kmh * 0.621_371, fractionDigits: 0)
    }

    var speedUnitLabel: String { unitSystem == .metric ? "km/h" : "mph" }

    // MARK: - Temperature, volume, economy

    func temperature(celsius: Double?) -> String? {
        guard let celsius else { return nil }
        return number(unitSystem == .metric ? celsius : celsius * 9 / 5 + 32, fractionDigits: 0)
    }

    var temperatureUnitLabel: String { unitSystem == .metric ? "°C" : "°F" }

    func volume(litres: Double?, fractionDigits: Int = 1) -> String? {
        guard let litres else { return nil }
        return number(unitSystem == .metric ? litres : litres * 0.264_172, fractionDigits: fractionDigits)
    }

    var volumeUnitLabel: String { unitSystem == .metric ? "L" : "gal" }

    func economy(kmPerLitre: Double?) -> String? {
        guard let kmPerLitre, let converted = economyUnit.value(fromKilometresPerLitre: kmPerLitre) else { return nil }
        return number(converted, fractionDigits: 1)
    }

    var economyUnitLabel: String { economyUnit.shortLabel }

    func voltage(_ volts: Double?) -> String? {
        guard let volts else { return nil }
        return number(volts, fractionDigits: 2)
    }

    func percent(_ value: Double?) -> String? {
        guard let value else { return nil }
        return number(value, fractionDigits: 0)
    }

    func rpm(_ value: Double?) -> String? {
        guard let value else { return nil }
        return number(value, fractionDigits: 0)
    }

    // MARK: - Time

    /// "47 min", "1 h 12 min". Never "0 min" for an absent duration.
    func duration(seconds: TimeInterval?) -> String? {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return nil }
        let totalMinutes = Int((seconds / 60).rounded())
        if totalMinutes < 60 { return "\(totalMinutes) min" }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return minutes == 0 ? "\(hours) h" : "\(hours) h \(minutes) min"
    }

    func shortTime(_ date: Date?) -> String? {
        guard let date else { return nil }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    func mediumDate(_ date: Date?) -> String? {
        guard let date else { return nil }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    func relative(_ date: Date?, to reference: Date = Date()) -> String? {
        guard let date else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: reference)
    }

    /// The greeting on the Today screen.
    func greeting(for date: Date, calendar: Calendar = .current) -> String {
        switch calendar.component(.hour, from: date) {
        case 0..<5: return "Good night"
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        default: return "Good evening"
        }
    }
}
