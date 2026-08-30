import Foundation

/// How long to wait before each attempt to get a dropped adapter back.
///
/// A BLE link drops for entirely ordinary reasons — a tunnel, a car park, the phone
/// briefly deciding the radio is busy — and the old behaviour was to set
/// `.failed(.connectionLost)` and stop. Live engine data was then gone for the rest of
/// the drive, with nothing supervising recovery and no way back short of the driver
/// noticing and reconnecting by hand.
///
/// Backoff rather than a fixed interval because the two cases look identical at the
/// start and want opposite things: a two-second radio glitch wants an immediate retry,
/// and an adapter that has been unplugged wants DriveLayer to stop waking the radio
/// every second for the next hour.
struct ReconnectPolicy: Sendable, Equatable {

    /// Delay before attempt 1, 2, 3… The last value repeats for every attempt after it.
    var delaysSeconds: [TimeInterval] = [1, 2, 5, 10, 30]

    /// `nil` keeps trying at the longest delay for as long as the drive lasts, which is
    /// the right default: the adapter reappearing an hour later is exactly the case
    /// worth catching, and a 30-second poll is cheap.
    var maximumAttempts: Int?

    init(delaysSeconds: [TimeInterval] = [1, 2, 5, 10, 30], maximumAttempts: Int? = nil) {
        self.delaysSeconds = delaysSeconds
        self.maximumAttempts = maximumAttempts
    }

    /// Longest delay in the ladder, used once the ladder is exhausted.
    var settledDelaySeconds: TimeInterval { delaysSeconds.last ?? 30 }

    /// How long to wait before `attempt`, counting from 1. `nil` when the policy says
    /// stop trying.
    func delay(forAttempt attempt: Int) -> TimeInterval? {
        guard attempt >= 1 else { return nil }
        if let maximumAttempts, attempt > maximumAttempts { return nil }
        guard !delaysSeconds.isEmpty else { return settledDelaySeconds }
        let index = min(attempt - 1, delaysSeconds.count - 1)
        return delaysSeconds[index]
    }

    /// Wording for the connection row, so a driver sees recovery happening rather than
    /// a bare failure.
    func statusDescription(attempt: Int) -> String {
        guard let delay = delay(forAttempt: attempt) else {
            return "Adapter not responding. Reconnect from Settings when it's available."
        }
        if attempt == 1 {
            return "Lost the adapter. Reconnecting…"
        }
        let seconds = Int(delay.rounded())
        return "Lost the adapter. Retrying every \(seconds)s — the drive is still recording."
    }
}
