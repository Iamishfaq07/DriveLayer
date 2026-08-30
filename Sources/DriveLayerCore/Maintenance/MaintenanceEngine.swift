import Foundation

/// How close a maintenance item is to being due.
struct MaintenanceDueStatus: Sendable, Equatable, Identifiable {
    var id: UUID { item.id }
    var item: MaintenanceItem
    /// Distance remaining. Negative means overdue. `nil` when distance isn't tracked
    /// or the vehicle's odometer isn't known.
    var remainingKm: Double?
    /// Days remaining. Negative means overdue.
    var remainingDays: Int?
    var status: SemanticStatus

    var isOverdue: Bool {
        (remainingKm.map { $0 < 0 } ?? false) || (remainingDays.map { $0 < 0 } ?? false)
    }

    /// The line shown in the UI, e.g. "Due in about 1,120 km or 34 days".
    var summary: String {
        if isOverdue {
            var parts: [String] = []
            if let remainingKm, remainingKm < 0 { parts.append(String(format: "%.0f km", -remainingKm)) }
            if let remainingDays, remainingDays < 0 { parts.append("\(-remainingDays) days") }
            let overBy = parts.joined(separator: " and ")
            return overBy.isEmpty ? "Overdue." : "Overdue by about \(overBy)."
        }
        var parts: [String] = []
        if let remainingKm { parts.append(String(format: "%.0f km", remainingKm)) }
        if let remainingDays { parts.append("\(remainingDays) days") }
        guard !parts.isEmpty else { return "Not enough information to work out when this is due." }
        return "Due in about " + parts.joined(separator: " or ") + "."
    }
}

/// Works out what is due, from distance, time, or whichever comes first.
enum MaintenanceEngine {

    /// Inside this much distance an item moves to `watch`.
    static let watchDistanceKm: Double = 1_000
    /// Inside this many days an item moves to `watch`.
    static let watchDays = 30
    /// Inside this much an item moves to `attention`.
    static let attentionDistanceKm: Double = 250
    static let attentionDays = 7

    static func status(for item: MaintenanceItem,
                       currentOdometerKm: Double?,
                       now: Date,
                       calendar: Calendar = .current) -> MaintenanceDueStatus {
        var remainingKm: Double?
        if let interval = item.intervalDistanceKm,
           let lastOdometer = item.lastDoneOdometerKm,
           let currentOdometerKm {
            remainingKm = (lastOdometer + interval) - currentOdometerKm
        }

        var remainingDays: Int?
        if let months = item.intervalMonths,
           let lastDate = item.lastDoneDate,
           let dueDate = calendar.date(byAdding: .month, value: months, to: lastDate) {
            remainingDays = calendar.dateComponents([.day], from: now, to: dueDate).day
        }

        let status = severity(remainingKm: remainingKm, remainingDays: remainingDays)
        return MaintenanceDueStatus(item: item,
                                    remainingKm: remainingKm,
                                    remainingDays: remainingDays,
                                    status: status)
    }

    private static func severity(remainingKm: Double?, remainingDays: Int?) -> SemanticStatus {
        guard remainingKm != nil || remainingDays != nil else {
            // Not enough information is `unknown`, never `normal`.
            return .unknown
        }
        if (remainingKm.map { $0 < 0 } ?? false) || (remainingDays.map { $0 < 0 } ?? false) {
            return .attention
        }
        if (remainingKm.map { $0 <= attentionDistanceKm } ?? false) || (remainingDays.map { $0 <= attentionDays } ?? false) {
            return .attention
        }
        if (remainingKm.map { $0 <= watchDistanceKm } ?? false) || (remainingDays.map { $0 <= watchDays } ?? false) {
            return .watch
        }
        return .normal
    }

    /// Every item's status, most urgent first.
    static func statuses(for items: [MaintenanceItem],
                         currentOdometerKm: Double?,
                         now: Date,
                         calendar: Calendar = .current) -> [MaintenanceDueStatus] {
        items
            .filter(\.isEnabled)
            .map { status(for: $0, currentOdometerKm: currentOdometerKm, now: now, calendar: calendar) }
            .sorted { lhs, rhs in
                if lhs.status != rhs.status { return lhs.status > rhs.status }
                let lhsKm = lhs.remainingKm ?? .greatestFiniteMagnitude
                let rhsKm = rhs.remainingKm ?? .greatestFiniteMagnitude
                return lhsKm < rhsKm
            }
    }

    /// The next thing due, for the Today screen and widgets.
    static func nextDue(for items: [MaintenanceItem],
                        currentOdometerKm: Double?,
                        now: Date,
                        calendar: Calendar = .current) -> MaintenanceDueStatus? {
        statuses(for: items, currentOdometerKm: currentOdometerKm, now: now, calendar: calendar)
            .first { $0.status != .unknown }
    }

    /// Builds the starting maintenance list for a newly added vehicle from its profile.
    /// Each item carries the profile's `SpecSource`, so the UI can say where the
    /// interval came from and the driver can correct it.
    static func defaultItems(for vehicle: Vehicle, profile: VehicleProfile?) -> [MaintenanceItem] {
        guard let profile else { return [] }
        return profile.serviceIntervals.map { interval in
            MaintenanceItem(vehicleID: vehicle.id,
                            kind: kind(forIntervalID: interval.id),
                            name: interval.name,
                            intervalDistanceKm: interval.distanceKm,
                            intervalMonths: interval.months,
                            lastDoneDate: nil,
                            lastDoneOdometerKm: nil,
                            source: interval.source,
                            note: interval.note)
        }
    }

    private static func kind(forIntervalID id: String) -> MaintenanceKind {
        switch id {
        case "periodic-service": return .periodicService
        case "air-filter": return .airFilter
        case "oil-filter": return .oilFilter
        case "engine-oil": return .engineOil
        case "brake-fluid": return .brakeFluid
        case "tyre-rotation": return .tyreRotation
        default: return .other
        }
    }
}
