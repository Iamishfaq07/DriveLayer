import Foundation

/// A reminder DriveLayer intends to deliver.
///
/// Planning is separated from delivery so the rules — how far ahead, how often,
/// what the copy says, and what must never appear in it — are testable without a
/// notification centre, a device, or a granted permission.
struct ScheduledReminder: Sendable, Equatable, Identifiable {

    enum Kind: String, Sendable, Codable, CaseIterable {
        case documentExpiry
        case documentExpired
        case maintenanceDue
        case maintenanceOverdue
    }

    /// Stable and derived from the record it is about, so rescheduling replaces a
    /// reminder rather than stacking a second copy of it.
    var id: String
    var kind: Kind
    var title: String
    var body: String
    var fireDate: Date
    var relatedRecordID: UUID?
}

/// Decides what to remind a driver about, and when.
///
/// Two rules shape everything here. Nothing is scheduled in the past, because a
/// notification that fires the instant it is created is noise. And nothing sensitive
/// reaches the copy: a lock-screen banner is visible to whoever is holding the phone,
/// so a policy or registration number never appears in one.
enum ReminderPlanner {

    /// Days before expiry that a document reminder fires.
    static let documentLeadDays = [30, 7]
    /// Days before a dated maintenance item is due.
    static let maintenanceLeadDays = 7
    /// Reminders fire mid-morning rather than at midnight.
    static let fireHour = 9

    static func reminders(documents: [DocumentRecord],
                          maintenance: [MaintenanceDueStatus],
                          now: Date,
                          calendar: Calendar = .current) -> [ScheduledReminder] {
        documentReminders(documents, now: now, calendar: calendar)
            + maintenanceReminders(maintenance, now: now, calendar: calendar)
    }

    // MARK: - Documents

    static func documentReminders(_ documents: [DocumentRecord],
                                  now: Date,
                                  calendar: Calendar = .current) -> [ScheduledReminder] {
        var results: [ScheduledReminder] = []
        for document in documents where document.kind.expires {
            guard let expiry = document.expiryDate else { continue }
            let name = document.kind.displayName

            for lead in documentLeadDays {
                guard let fire = fireDate(daysBefore: lead, of: expiry, calendar: calendar), fire > now else { continue }
                results.append(ScheduledReminder(
                    id: "document.\(document.id.uuidString).\(lead)",
                    kind: .documentExpiry,
                    title: "\(name) expires soon",
                    // No provider, no reference number: this is a lock-screen banner.
                    body: "Your \(name.lowercased()) expires in \(lead) days.",
                    fireDate: fire,
                    relatedRecordID: document.id
                ))
            }

            // The day itself, once.
            if let fire = fireDate(daysBefore: 0, of: expiry, calendar: calendar), fire > now {
                results.append(ScheduledReminder(
                    id: "document.\(document.id.uuidString).0",
                    kind: .documentExpired,
                    title: "\(name) expires today",
                    body: "Your \(name.lowercased()) expires today.",
                    fireDate: fire,
                    relatedRecordID: document.id
                ))
            }
        }
        return results
    }

    // MARK: - Maintenance

    static func maintenanceReminders(_ statuses: [MaintenanceDueStatus],
                                     now: Date,
                                     calendar: Calendar = .current) -> [ScheduledReminder] {
        var results: [ScheduledReminder] = []
        for status in statuses {
            // A distance-based item has no date to fire on. DriveLayer surfaces those
            // on Today and in the widget rather than inventing a schedule for them.
            guard let remainingDays = status.remainingDays else { continue }

            if remainingDays < 0 {
                // Overdue: one nudge tomorrow morning, not a daily drumbeat.
                guard let fire = fireDate(daysFromNow: 1, now: now, calendar: calendar) else { continue }
                results.append(ScheduledReminder(
                    id: "maintenance.\(status.item.id.uuidString).overdue",
                    kind: .maintenanceOverdue,
                    title: "\(status.item.name) is overdue",
                    body: "It was due \(-remainingDays) days ago.",
                    fireDate: fire,
                    relatedRecordID: status.item.id
                ))
                continue
            }

            let daysAhead = max(1, remainingDays - maintenanceLeadDays)
            guard remainingDays <= 60,
                  let fire = fireDate(daysFromNow: daysAhead, now: now, calendar: calendar),
                  fire > now else { continue }
            results.append(ScheduledReminder(
                id: "maintenance.\(status.item.id.uuidString).due",
                kind: .maintenanceDue,
                title: "\(status.item.name) is due soon",
                body: status.summary,
                fireDate: fire,
                relatedRecordID: status.item.id
            ))
        }
        return results
    }

    // MARK: - Dates

    private static func fireDate(daysBefore days: Int, of date: Date, calendar: Calendar) -> Date? {
        guard let shifted = calendar.date(byAdding: .day, value: -days, to: date) else { return nil }
        return calendar.date(bySettingHour: fireHour, minute: 0, second: 0, of: shifted)
    }

    private static func fireDate(daysFromNow days: Int, now: Date, calendar: Calendar) -> Date? {
        guard let shifted = calendar.date(byAdding: .day, value: days, to: now) else { return nil }
        return calendar.date(bySettingHour: fireHour, minute: 0, second: 0, of: shifted)
    }
}
