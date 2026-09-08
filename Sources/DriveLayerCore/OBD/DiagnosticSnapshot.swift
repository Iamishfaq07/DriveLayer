import Foundation

/// Outcome of one diagnostic mode request. An empty code list is meaningful only
/// when the corresponding mode completed successfully.
enum DiagnosticRequestStatus: Sendable, Equatable, Codable {
    case notAttempted
    case successful
    case unsupported
    case unavailable
    case failed(String)

    var isSuccessful: Bool {
        if case .successful = self { return true }
        return false
    }

    var description: String {
        switch self {
        case .notAttempted: return "not attempted"
        case .successful: return "successful"
        case .unsupported: return "unsupported"
        case .unavailable: return "unavailable"
        case .failed: return "failed"
        }
    }
}

/// A truthful snapshot of the diagnostic scan, including incomplete coverage.
struct DiagnosticSnapshot: Sendable, Equatable, Codable {
    var scanStartedAt: Date?
    var scanCompletedAt: Date?
    var storedCodes: [DiagnosticTroubleCode]
    var pendingCodes: [DiagnosticTroubleCode]
    var permanentCodes: [DiagnosticTroubleCode]
    var storedStatus: DiagnosticRequestStatus
    var pendingStatus: DiagnosticRequestStatus
    var permanentStatus: DiagnosticRequestStatus
    var monitorStatus: MonitorStatus?

    init(scanStartedAt: Date? = nil,
         scanCompletedAt: Date? = nil,
         storedCodes: [DiagnosticTroubleCode] = [],
         pendingCodes: [DiagnosticTroubleCode] = [],
         permanentCodes: [DiagnosticTroubleCode] = [],
         storedStatus: DiagnosticRequestStatus = .notAttempted,
         pendingStatus: DiagnosticRequestStatus = .notAttempted,
         permanentStatus: DiagnosticRequestStatus = .notAttempted,
         monitorStatus: MonitorStatus? = nil) {
        self.scanStartedAt = scanStartedAt
        self.scanCompletedAt = scanCompletedAt
        self.storedCodes = storedCodes
        self.pendingCodes = pendingCodes
        self.permanentCodes = permanentCodes
        self.storedStatus = storedStatus
        self.pendingStatus = pendingStatus
        self.permanentStatus = permanentStatus
        self.monitorStatus = monitorStatus
    }

    var allCodes: [DiagnosticTroubleCode] { storedCodes + pendingCodes + permanentCodes }
    var statuses: [DiagnosticRequestStatus] { [storedStatus, pendingStatus, permanentStatus] }
    var relevantStatuses: [DiagnosticRequestStatus] { statuses.filter { $0 != .unsupported } }
    var isComplete: Bool { !relevantStatuses.isEmpty && relevantStatuses.allSatisfy(\.isSuccessful) }
    var hasSuccessfulZeroCodeScan: Bool { isComplete && allCodes.isEmpty }

    var coverage: Double {
        guard !relevantStatuses.isEmpty else { return 0 }
        return Double(relevantStatuses.filter { $0.isSuccessful }.count) / Double(relevantStatuses.count)
    }

    var summary: String {
        if !allCodes.isEmpty {
            return "\(allCodes.count) diagnostic code\(allCodes.count == 1 ? "" : "s") found"
                + (isComplete ? "" : " · scan coverage incomplete")
        }
        if hasSuccessfulZeroCodeScan && statuses.contains(.unsupported) {
            return "No diagnostic trouble codes found in supported modes"
        }
        if hasSuccessfulZeroCodeScan { return "No diagnostic trouble codes found" }
        if statuses.contains(where: { if case .failed = $0 { return true }; return false }) {
            return "Diagnostic scan incomplete"
        }
        if statuses.contains(.unavailable) || statuses.allSatisfy({ $0 == .notAttempted }) {
            return "Diagnostics unavailable"
        }
        return "Diagnostic scan incomplete"
    }
}
