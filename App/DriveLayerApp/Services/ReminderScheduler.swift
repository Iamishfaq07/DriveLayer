import Foundation
import UserNotifications

/// Delivers the reminders `ReminderPlanner` decides on.
///
/// Deliberately thin: it asks the core what should be scheduled, cancels DriveLayer's
/// previously scheduled reminders, and registers the new set. All the judgement —
/// how far ahead, how often, and what the copy may say — lives in the core where it
/// is unit tested.
@MainActor
@Observable
final class ReminderScheduler {

    enum Authorisation: String, Sendable {
        case notDetermined, denied, authorised, provisional

        var allowsScheduling: Bool { self == .authorised || self == .provisional }
    }

    private(set) var authorisation: Authorisation = .notDetermined
    private(set) var scheduledCount = 0
    private(set) var lastError: String?

    /// Identifier prefix, so DriveLayer only ever cancels its own requests.
    private let prefix = "drivelayer."
    private let center = UNUserNotificationCenter.current()

    func refreshAuthorisation() async {
        let settings = await center.notificationSettings()
        authorisation = Self.map(settings.authorizationStatus)
    }

    /// Asked for only when the driver turns reminders on, never at launch.
    @discardableResult
    func requestAuthorisation() async -> Bool {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            await refreshAuthorisation()
            return granted
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Replaces DriveLayer's pending reminders with the current plan.
    ///
    /// Replacing rather than adding is what keeps this idempotent: it runs after every
    /// analysis pass, and a driver must not accumulate six copies of the same nudge.
    func reschedule(documents: [DocumentRecord],
                    maintenance: [MaintenanceDueStatus],
                    isEnabled: Bool,
                    now: Date = Date()) async {
        await cancelAll()
        guard isEnabled else {
            scheduledCount = 0
            return
        }
        await refreshAuthorisation()
        guard authorisation.allowsScheduling else {
            scheduledCount = 0
            return
        }

        let reminders = ReminderPlanner.reminders(documents: documents, maintenance: maintenance, now: now)
        var scheduled = 0
        for reminder in reminders {
            let content = UNMutableNotificationContent()
            content.title = reminder.title
            content.body = reminder.body
            content.sound = .default
            // Lets a tap open the right screen, and carries no sensitive value.
            content.userInfo = [
                "kind": reminder.kind.rawValue,
                "recordID": reminder.relatedRecordID?.uuidString ?? ""
            ]

            let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute],
                                                             from: reminder.fireDate)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let request = UNNotificationRequest(identifier: prefix + reminder.id,
                                                content: content,
                                                trigger: trigger)
            do {
                try await center.add(request)
                scheduled += 1
            } catch {
                lastError = error.localizedDescription
                PrivacyLog.logger(.app).error("Could not schedule a reminder")
            }
        }
        scheduledCount = scheduled
    }

    func cancelAll() async {
        let pending = await center.pendingNotificationRequests()
        let identifiers = pending.map(\.identifier).filter { $0.hasPrefix(prefix) }
        guard !identifiers.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    /// For the Debug Center: what is actually queued.
    func pendingSummaries() async -> [String] {
        let pending = await center.pendingNotificationRequests()
        return pending
            .filter { $0.identifier.hasPrefix(prefix) }
            .map { request in
                let when = (request.trigger as? UNCalendarNotificationTrigger)?
                    .nextTriggerDate()
                    .map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "unknown"
                return "\(request.content.title) — \(when)"
            }
            .sorted()
    }

    private static func map(_ status: UNAuthorizationStatus) -> Authorisation {
        switch status {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized, .ephemeral: return .authorised
        case .provisional: return .provisional
        @unknown default: return .notDetermined
        }
    }
}
