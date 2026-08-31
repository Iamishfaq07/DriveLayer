import Foundation

/// A plain-text account of what one car actually answered, meant to be sent to
/// someone else.
///
/// `docs/RELEASE.md` asks a first-drive tester to report what their car reports,
/// because no amount of testing here substitutes for one real ECU. Until now the
/// only way to do that was a screenshot of a scrolling screen, or the full data
/// export — which carries trips, coordinates and scanned documents, and is a
/// wildly disproportionate thing to hand over in order to say which parameters an
/// engine answers.
///
/// So this is deliberately narrow. It contains what the car said and what
/// DriveLayer made of it, and nothing about where the car has been or who owns it:
/// no VIN, no nickname, no coordinates, no trips, no odometer, no documents. That
/// is a property of what this function reads, not a promise about what it filters —
/// it is given the capability report and the profile, and neither holds a location.
enum OBDCapabilityDigest {

    /// One parameter the car reported, and whether DriveLayer can make sense of it.
    struct Entry: Sendable, Equatable {
        var code: UInt8
        var name: String
        var isInterpreted: Bool
    }

    /// What the car reported, split by what DriveLayer can do with it.
    ///
    /// The middle group is the interesting one: parameters the ECU offers that
    /// DriveLayer does not yet decode. That list is the roadmap for a specific car,
    /// written by the car itself.
    struct Findings: Sendable, Equatable {
        var interpreted: [Entry]
        var reportedButNotInterpreted: [Entry]
        /// Parameters the profile predicted but the car did not report. A non-empty
        /// list here means the profile is optimistic, which is worth knowing.
        var expectedButAbsent: [Entry]
        /// Whether the profile predicted anything at all.
        ///
        /// Without this, a profile that predicts nothing is indistinguishable from a
        /// profile whose every prediction came true — both leave `expectedButAbsent`
        /// empty. The reference Harrier profile is deliberately in the first group
        /// (`expectedStandardPIDs: []`, because no PID list has been verified for it),
        /// so reporting "the profile matched the car" there would be a confident
        /// statement about a comparison that never happened.
        var profileMadePredictions: Bool
    }

    /// Bitmap-request codes (0x00, 0x20, …) are how a car is asked what it supports.
    /// They are plumbing, not parameters, and listing them as findings would pad the
    /// report with rows no one can act on.
    static func findings(report: OBDCapabilityReport, profile: VehicleProfile?) -> Findings {
        let plumbing = Set(OBDPIDCatalog.supportedPIDRequestCodes)
        let decodable = Set(OBDPIDCatalog.allDescriptors.compactMap { $0.pid.code })
        let reported = report.supportedCodes.subtracting(plumbing)

        func entry(_ code: UInt8) -> Entry {
            Entry(code: code,
                  name: OBDPIDCatalog.displayName(forCode: code),
                  isInterpreted: decodable.contains(code))
        }

        let expected = Set((profile?.expectedStandardPIDs ?? [])
            .filter { $0.mode == .currentData }
            .compactMap { $0.code })
            .subtracting(plumbing)

        return Findings(
            interpreted: reported.intersection(decodable).sorted().map(entry),
            reportedButNotInterpreted: reported.subtracting(decodable).sorted().map(entry),
            expectedButAbsent: expected.subtracting(reported).sorted().map(entry),
            profileMadePredictions: !expected.isEmpty
        )
    }

    /// The report as text, ready to share.
    ///
    /// Plain text rather than JSON: a person reads this one, and it travels through
    /// a message rather than an importer.
    static func text(report: OBDCapabilityReport,
                     profile: VehicleProfile?,
                     capabilityLevel: VehicleCapabilityLevel,
                     adapterDescription: String?,
                     appVersion: String,
                     generatedAt: Date) -> String {
        let found = findings(report: report, profile: profile)
        var lines: [String] = []

        lines.append("DriveLayer capability report")
        lines.append("Generated \(Self.stamp(generatedAt)) by DriveLayer \(appVersion)")
        lines.append("")

        lines.append("VEHICLE")
        if let profile {
            lines.append("  Profile        \(profile.displayName)")
            lines.append("  Profile ID     \(profile.id)")
            lines.append("  Fuel           \(profile.fuelType.rawValue)")
            lines.append("  Engine         \(profile.engine.shortDescription)")
        } else {
            lines.append("  No vehicle profile selected.")
        }
        lines.append("  Capability     \(capabilityLevel.title)")
        lines.append("  Adapter        \(adapterDescription ?? "not recorded")")
        lines.append("  Discovered     \(Self.stamp(report.discoveredAt))")
        lines.append("")

        lines.append("FAULT CODE MODES")
        lines.append("  Stored (03)    \(report.storedDTCSupport.rawValue)")
        lines.append("  Pending (07)   \(report.pendingDTCSupport.rawValue)")
        lines.append("  Permanent (0A) \(report.permanentDTCSupport.rawValue)")
        lines.append("")

        lines.append(contentsOf: Self.section(
            "REPORTED AND INTERPRETED (\(found.interpreted.count))",
            found.interpreted,
            empty: "  None. If the adapter was connected, this is the finding."))

        lines.append(contentsOf: Self.section(
            "REPORTED BUT NOT INTERPRETED (\(found.reportedButNotInterpreted.count))",
            found.reportedButNotInterpreted,
            empty: "  None — DriveLayer decodes everything this car offers."))

        lines.append(contentsOf: Self.section(
            "EXPECTED BY THE PROFILE BUT NOT REPORTED (\(found.expectedButAbsent.count))",
            found.expectedButAbsent,
            empty: found.profileMadePredictions
                ? "  None — every parameter the profile predicted was present."
                : "  The profile predicts no parameters, so there is nothing to compare against."))

        if !report.notes.isEmpty {
            lines.append("NOTES FROM DISCOVERY")
            for note in report.notes { lines.append("  \(note)") }
            lines.append("")
        }

        lines.append("This report describes diagnostic capability only.")
        return lines.joined(separator: "\n")
    }

    private static func section(_ title: String, _ entries: [Entry], empty: String) -> [String] {
        var lines = [title]
        if entries.isEmpty {
            lines.append(empty)
        } else {
            for entry in entries {
                lines.append(String(format: "  %02X  %@", Int(entry.code), entry.name))
            }
        }
        lines.append("")
        return lines
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm 'UTC'"
        return formatter.string(from: date)
    }
}
