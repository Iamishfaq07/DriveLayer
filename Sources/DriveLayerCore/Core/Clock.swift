import Foundation

/// Injectable time so trip, baseline and reminder logic is deterministic in tests.
protocol DateProviding: Sendable {
    var now: Date { get }
}

struct SystemDateProvider: DateProviding {
    var now: Date { Date() }
}

/// Test/preview clock. Advance it by hand.
final class MutableDateProvider: DateProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) { self.current = start }

    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func advance(by interval: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current = current.addingTimeInterval(interval)
    }

    func set(_ date: Date) {
        lock.lock(); defer { lock.unlock() }
        current = date
    }
}
