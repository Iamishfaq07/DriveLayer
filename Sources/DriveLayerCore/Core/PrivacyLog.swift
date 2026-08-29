import Foundation
#if canImport(os)
import os
#endif

/// Logging with privacy defaults that match the product promise: no tokens, no
/// document contents, no precise coordinates. Anything sensitive must go through
/// a redacting helper rather than string interpolation.
enum PrivacyLog {
    enum Category: String {
        case obd, trips, location, weather, insights, persistence, carplay, copilot, app
    }

    private static let subsystem = "com.drivelayer.app"

    #if canImport(os)
    static func logger(_ category: Category) -> Logger {
        Logger(subsystem: subsystem, category: category.rawValue)
    }
    #endif

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
}
