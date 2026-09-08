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
    var isComplete: Bool { statuses.allSatisfy(\.isSuccessful) }
    var hasSuccessfulZeroCodeScan: Bool { isComplete && allCodes.isEmpty }

    var coverage: Double {
        Double(statuses.filter { $0.isSuccessful }.count) / Double(statuses.count)
    }

    var summary: String {
        if hasSuccessfulZeroCodeScan { return "No diagnostic trouble codes found" }
        if statuses.contains(where: { if case .failed = $0 { return true }; return false }) {
            return "Diagnostic scan incomplete"
        }
        if statuses.contains(.unavailable) || statuses.allSatisfy({ $0 == .notAttempted }) {
            return "Diagnostics unavailable"
        }
        if !allCodes.isEmpty { return "(allCodes.count) diagnostic code\(allCodes.count == 1 ? "" : "s") found" }
        return "Diagnostic scan incomplete"
    }
}
