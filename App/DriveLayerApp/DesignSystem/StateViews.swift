import SwiftUI

/// The states every feature has to answer. Having them as components means no screen
/// invents its own wording for "we don't have this", and none of them can quietly
/// render missing data as zero.
struct DLEmptyState: View {
    let symbol: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: DL.Spacing.medium) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(DLColor.unknown)
                .accessibilityHidden(true)
            VStack(spacing: DL.Spacing.tight) {
                Text(title)
                    .font(DL.Font.title)
                    .foregroundStyle(DLColor.primaryText)
                Text(message)
                    .font(DL.Font.callout)
                    .foregroundStyle(DLColor.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(DLColor.accent)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DL.Spacing.large)
        .padding(.horizontal, DL.Spacing.medium)
    }
}

/// Renders an `UnavailabilityReason` using its own copy, so the explanation a driver
/// sees is defined next to the condition that caused it.
struct DLUnavailableState: View {
    let reason: UnavailabilityReason
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        DLEmptyState(symbol: symbol,
                     title: reason.title,
                     message: reason.message,
                     actionTitle: actionTitle,
                     action: action)
    }

    private var symbol: String {
        switch reason {
        case .obdNotConnected: return "cable.connector"
        case .pidNotSupportedByVehicle: return "sensor"
        case .locationPermissionDenied, .locationPermissionNotDetermined: return "location.slash"
        case .motionPermissionDenied: return "figure.walk.motion"
        case .weatherServiceUnconfigured: return "cloud.slash"
        case .offline: return "wifi.slash"
        case .noVehicleSelected: return "car"
        case .notEnoughHistory: return "chart.line.uptrend.xyaxis"
        case .featureRequiresValidatedProfile: return "checkmark.seal"
        }
    }
}

struct DLErrorState: View {
    let message: String
    var retry: (() -> Void)?

    var body: some View {
        DLEmptyState(symbol: "exclamationmark.triangle",
                     title: "Something went wrong",
                     message: message,
                     actionTitle: retry == nil ? nil : "Try again",
                     action: retry)
    }
}

struct DLLoadingState: View {
    var message: String = "Loading"

    var body: some View {
        VStack(spacing: DL.Spacing.small) {
            ProgressView()
            Text(message)
                .font(DL.Font.callout)
                .foregroundStyle(DLColor.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DL.Spacing.large)
    }
}

/// A row that shows a value or, when there isn't one, why.
struct ValueOrReasonRow: View {
    let label: String
    let value: String?
    var unit: String?
    var provenance: DataProvenance = .measured
    var reason: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(DL.Font.body)
                .foregroundStyle(DLColor.primaryText)
            Spacer(minLength: DL.Spacing.medium)
            if let value {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(value)
                        .font(DL.Font.body.monospacedDigit())
                        .foregroundStyle(DLColor.provenance(provenance))
                    if let unit {
                        Text(unit)
                            .font(DL.Font.caption)
                            .foregroundStyle(DLColor.secondaryText)
                    }
                }
            } else {
                Text(reason ?? "Not reported")
                    .font(DL.Font.callout)
                    .foregroundStyle(DLColor.unknown)
                    .multilineTextAlignment(.trailing)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(spokenDescription))
    }

    private var spokenDescription: String {
        guard let value else { return "\(label): \(reason ?? "not reported")" }
        var spoken = "\(label): \(value)"
        if let unit { spoken += " \(unit)" }
        if provenance != .measured, let qualifier = provenance.userFacingQualifier {
            spoken += ", \(qualifier)"
        }
        return spoken
    }
}
