import Foundation

enum DocumentKind: String, Codable, CaseIterable, Sendable {
    case registration
    case insurance
    case pollutionCertificate
    case serviceInvoice
    case tyreInvoice
    case batteryWarranty
    case roadsideAssistance
    case drivingLicence
    case other

    var displayName: String {
        switch self {
        case .registration: return "Registration"
        case .insurance: return "Insurance"
        case .pollutionCertificate: return "PUC certificate"
        case .serviceInvoice: return "Service invoice"
        case .tyreInvoice: return "Tyre invoice"
        case .batteryWarranty: return "Battery warranty"
        case .roadsideAssistance: return "Roadside assistance"
        case .drivingLicence: return "Driving licence"
        case .other: return "Document"
        }
    }

    var symbolName: String {
        switch self {
        case .registration: return "doc.text"
        case .insurance: return "shield"
        case .pollutionCertificate: return "leaf"
        case .serviceInvoice: return "wrench.and.screwdriver"
        case .tyreInvoice: return "circle.circle"
        case .batteryWarranty: return "minus.plus.batteryblock"
        case .roadsideAssistance: return "phone.badge.waveform"
        case .drivingLicence: return "person.text.rectangle"
        case .other: return "doc"
        }
    }

    /// Documents that expire and are worth reminding a driver about.
    var expires: Bool {
        switch self {
        case .insurance, .pollutionCertificate, .roadsideAssistance, .drivingLicence, .registration: return true
        case .serviceInvoice, .tyreInvoice, .batteryWarranty, .other: return false
        }
    }
}

/// An item in the digital glovebox.
///
/// The file itself lives in the app's container with complete file protection, and
/// `referenceNumber` is sensitive — it is never logged, never included in diagnostics,
/// and never leaves the device. Nothing here is uploaded anywhere.
struct DocumentRecord: Codable, Sendable, Equatable, Identifiable {
    var id: UUID
    var vehicleID: UUID?
    var kind: DocumentKind
    var title: String
    var provider: String?
    var referenceNumber: String?
    var issueDate: Date?
    var expiryDate: Date?
    /// Relative path inside the protected documents directory.
    var fileName: String?
    var addedAt: Date
    var note: String?
    /// True when the fields were filled in by on-device text recognition rather than
    /// typed, so the UI can invite the driver to check them.
    var wasExtractedAutomatically: Bool

    init(id: UUID = UUID(),
         vehicleID: UUID? = nil,
         kind: DocumentKind,
         title: String? = nil,
         provider: String? = nil,
         referenceNumber: String? = nil,
         issueDate: Date? = nil,
         expiryDate: Date? = nil,
         fileName: String? = nil,
         addedAt: Date = Date(),
         note: String? = nil,
         wasExtractedAutomatically: Bool = false) {
        self.id = id
        self.vehicleID = vehicleID
        self.kind = kind
        self.title = title ?? kind.displayName
        self.provider = provider
        self.referenceNumber = referenceNumber
        self.issueDate = issueDate
        self.expiryDate = expiryDate
        self.fileName = fileName
        self.addedAt = addedAt
        self.note = note
        self.wasExtractedAutomatically = wasExtractedAutomatically
    }

    /// Safe for logs.
    var redactedDescription: String {
        var text = "Document(\(kind.rawValue)"
        if let referenceNumber {
            text += ", ref: \(PrivacyLog.redactedDocumentNumber(referenceNumber))"
        }
        return text + ")"
    }

    func daysUntilExpiry(now: Date, calendar: Calendar = .current) -> Int? {
        guard let expiryDate else { return nil }
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                       to: calendar.startOfDay(for: expiryDate)).day
    }

    func status(now: Date, calendar: Calendar = .current) -> SemanticStatus {
        guard kind.expires else { return .normal }
        guard let days = daysUntilExpiry(now: now, calendar: calendar) else { return .unknown }
        if days < 0 { return .critical }
        if days <= 14 { return .attention }
        if days <= 45 { return .watch }
        return .normal
    }
}

/// What the on-device scanner managed to read from a document.
///
/// Every field is optional and the whole thing is a suggestion: extraction runs
/// locally with Vision, and DriveLayer asks the driver to confirm rather than
/// silently trusting an OCR result about their insurance expiry.
struct DocumentExtraction: Sendable, Equatable {
    var suggestedKind: DocumentKind?
    var provider: String?
    var referenceNumber: String?
    var issueDate: Date?
    var expiryDate: Date?
    var confidence: Double
    var recognisedLineCount: Int

    static let empty = DocumentExtraction(suggestedKind: nil,
                                          provider: nil,
                                          referenceNumber: nil,
                                          issueDate: nil,
                                          expiryDate: nil,
                                          confidence: 0,
                                          recognisedLineCount: 0)
}

/// Recognises document fields from scanned text. The Vision-backed implementation
/// lives in the app target; this protocol keeps the parsing rules testable.
protocol DocumentTextExtracting: Sendable {
    func extract(fromRecognisedLines lines: [String], now: Date) -> DocumentExtraction
}

/// Field extraction from recognised text lines.
///
/// Kept in the core, and therefore unit tested, because getting an expiry date wrong
/// means a driver misses an insurance renewal.
struct DocumentFieldExtractor: DocumentTextExtracting, Sendable {

    func extract(fromRecognisedLines lines: [String], now: Date) -> DocumentExtraction {
        guard !lines.isEmpty else { return .empty }
        let joined = lines.joined(separator: "\n")
        let upper = joined.uppercased()

        var kind: DocumentKind?
        if upper.contains("INSURANCE") || upper.contains("POLICY") { kind = .insurance }
        else if upper.contains("POLLUTION") || upper.contains("PUC") { kind = .pollutionCertificate }
        else if upper.contains("REGISTRATION") || upper.contains("RC ") { kind = .registration }
        else if upper.contains("INVOICE") || upper.contains("TAX INVOICE") { kind = .serviceInvoice }

        let dates = Self.dates(in: joined)
        let future = dates.filter { $0 > now }.sorted()
        let past = dates.filter { $0 <= now }.sorted()

        // The nearest future date is the best available guess at an expiry, and the
        // most recent past date at an issue date. Both are suggestions to confirm.
        let expiry = future.first
        let issue = past.last

        let reference = Self.referenceNumber(in: lines)

        var confidence = 0.0
        if kind != nil { confidence += 0.3 }
        if expiry != nil { confidence += 0.3 }
        if reference != nil { confidence += 0.2 }
        if issue != nil { confidence += 0.1 }
        confidence = Statistics.clamp(confidence, 0...0.9)

        return DocumentExtraction(suggestedKind: kind,
                                  provider: nil,
                                  referenceNumber: reference,
                                  issueDate: issue,
                                  expiryDate: expiry,
                                  confidence: confidence,
                                  recognisedLineCount: lines.count)
    }

    /// Finds dates in the common written forms, without a locale guess that would
    /// silently swap day and month.
    static func dates(in text: String) -> [Date] {
        var results: [Date] = []
        let patterns = [
            ("dd/MM/yyyy", #"\b\d{2}/\d{2}/\d{4}\b"#),
            ("dd-MM-yyyy", #"\b\d{2}-\d{2}-\d{4}\b"#),
            ("yyyy-MM-dd", #"\b\d{4}-\d{2}-\d{2}\b"#),
            ("dd MMM yyyy", #"\b\d{1,2} [A-Za-z]{3} \d{4}\b"#)
        ]
        for (format, pattern) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            for match in regex.matches(in: text, range: range) {
                guard let matchRange = Range(match.range, in: text) else { continue }
                if let date = formatter.date(from: String(text[matchRange])) {
                    results.append(date)
                }
            }
        }
        return results
    }

    /// A long alphanumeric run is the most likely policy or certificate number.
    static func referenceNumber(in lines: [String]) -> String? {
        let candidates = lines.flatMap { line -> [String] in
            line.split(whereSeparator: { $0 == " " || $0 == ":" || $0 == "\t" }).map(String.init)
        }
        return candidates.first { token in
            // Checked on the raw token, so a date like 01/04/2027 is not mistaken for
            // a policy number once its separators are stripped.
            guard token.allSatisfy({ $0.isLetter || $0.isNumber }) else { return false }
            guard token.count >= 8, token.count <= 24 else { return false }
            return token.contains(where: \.isNumber) && token.contains(where: \.isLetter)
        }
    }
}
