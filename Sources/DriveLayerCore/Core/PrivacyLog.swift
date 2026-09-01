import Foundation
#if canImport(os)
import os
#endif

/// A destination for log records. The production sink is chosen by platform; tests
/// substitute their own so that "what would have been logged" is assertable without
/// reading the system log.
protocol PrivacyLogSink: AnyObject {
    func write(level: PrivacyLog.Level, category: PrivacyLog.Category, message: String)
}

/// Logging with privacy defaults that match the product promise: no tokens, no
/// document contents, no precise coordinates. Anything sensitive must go through
/// a redacting helper rather than string interpolation.
///
/// The level-based API below is the only logging surface the core is allowed to
/// use, and that is the point of it. This type previously exposed
/// `logger(_:) -> os.Logger` inside `#if canImport(os)`, and `TelemetryJournal`
/// — Foundation-only product logic, compiled and tested on platforms without
/// `os` — called it at four sites. On macOS that compiles, which is why CI stayed
/// green; anywhere `os` is unavailable the core simply would not build, so the
/// cross-platform `swift test` the package promises was broken in a way the one
/// runner we use could never show. Keeping `os.Logger` unreachable from here is
/// what stops that returning.
enum PrivacyLog {
    enum Category: String, CaseIterable {
        case obd, trips, location, weather, insights, persistence, carplay, copilot, app
    }

    enum Level: String, CaseIterable {
        case debug, info, notice, error, fault
    }

    private static let subsystem = "com.drivelayer.app"

    // MARK: - The logging surface

    /// Detail useful while developing. Dropped entirely off-platform.
    static func debug(_ category: Category, _ message: String) {
        emit(.debug, category, message)
    }

    /// Something worth knowing about but not a failure.
    static func info(_ category: Category, _ message: String) {
        emit(.info, category, message)
    }

    /// Worth keeping in the log, but not a failure of anything.
    static func notice(_ category: Category, _ message: String) {
        emit(.notice, category, message)
    }

    /// A failure the app recovered from, or chose to tolerate.
    static func error(_ category: Category, _ message: String) {
        emit(.error, category, message)
    }

    /// A failure that should not be possible.
    static func fault(_ category: Category, _ message: String) {
        emit(.fault, category, message)
    }

    // MARK: - Redaction helpers

    /// Coordinates are rounded to ~1 km before they may be logged at all.
    static func coarse(latitude: Double, longitude: Double) -> String {
        String(format: "~%.2f,~%.2f", latitude, longitude)
    }

    /// Keeps the shape of an identifier for correlation without revealing it.
    static func redactedIdentifier(_ value: String) -> String {
        guard value.count > 4 else { return "****" }
        return String(repeating: "*", count: value.count - 4) + value.suffix(4)
    }

    /// Document numbers, policy numbers and VINs are never logged in full.
    static func redactedDocumentNumber(_ value: String) -> String {
        redactedIdentifier(value.replacingOccurrences(of: " ", with: ""))
    }

    // MARK: - Test seam

    /// Redirects every record to `sink` until `resetSink()` is called. Tests use
    /// this to assert on what was logged; nothing in the app should call it.
    static func setSink(_ sink: PrivacyLogSink?) {
        storage.set(sink)
    }

    /// Restores the platform sink.
    static func resetSink() {
        storage.set(nil)
    }

    // MARK: - Plumbing

    private static let storage = SinkStorage()

    private static func emit(_ level: Level, _ category: Category, _ message: String) {
        if let sink = storage.current() {
            sink.write(level: level, category: category, message: message)
            return
        }
        emitToPlatform(level, category, message)
    }

    /// A lock rather than an unprotected `static var`: logging is called from the
    /// BLE delegate queue, the location queue and the main actor, and a torn read
    /// of the sink during a test would be a flake nobody would enjoy finding.
    private final class SinkStorage {
        private let lock = NSLock()
        private var sink: PrivacyLogSink?

        func set(_ newValue: PrivacyLogSink?) {
            lock.lock()
            sink = newValue
            lock.unlock()
        }

        func current() -> PrivacyLogSink? {
            lock.lock()
            defer { lock.unlock() }
            return sink
        }
    }

    #if canImport(os)
    private static func emitToPlatform(_ level: Level, _ category: Category, _ message: String) {
        let logger = Logger(subsystem: subsystem, category: category.rawValue)
        // `.public` is deliberate and is safe only because of the rule this type
        // exists to enforce: callers pass literals or values already through
        // `coarse`/`redactedIdentifier`. Interpolating a raw coordinate, document
        // number or token into one of these calls is the bug to look for in review
        // — the privacy marker here will not save it.
        switch level {
        case .debug: logger.debug("\(message, privacy: .public)")
        case .info: logger.info("\(message, privacy: .public)")
        case .notice: logger.notice("\(message, privacy: .public)")
        case .error: logger.error("\(message, privacy: .public)")
        case .fault: logger.fault("\(message, privacy: .public)")
        }
    }
    #else
    private static func emitToPlatform(_ level: Level, _ category: Category, _ message: String) {
        // Off-platform this exists so the core compiles and tests run, not to be a
        // logging system. Failures go to stderr because a silent failure during a
        // command-line test run is worse than a line of noise; debug and info are
        // dropped, since nothing off-platform is a user's device.
        switch level {
        case .debug, .info, .notice:
            return
        case .error, .fault:
            let line = "[\(level.rawValue)] [\(category.rawValue)] \(message)\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
    }
    #endif
}
