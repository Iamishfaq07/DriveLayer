import Foundation

/// The diesel particulate filter values DriveLayer would show *if* a vehicle's
/// profile carried validated, read-only requests for them.
///
/// Every field defaults to unavailable, and there is no code path that fills one in
/// from a guess. If a car does not expose soot load, DriveLayer says so — it does not
/// model a number and present it as a reading.
struct DPFTelemetry: Sendable, Equatable {
    var sootLoadPercent: Provenanced<Double>
    var regenerationStatus: Provenanced<String>
    var distanceSinceRegenerationKm: Provenanced<Double>
    var exhaustGasTemperatureC: Provenanced<Double>
    var differentialPressureKPa: Provenanced<Double>
    var defLevelPercent: Provenanced<Double>

    static let unavailable = DPFTelemetry(
        sootLoadPercent: .unavailable(basis: standardBasis),
        regenerationStatus: .unavailable(basis: standardBasis),
        distanceSinceRegenerationKm: .unavailable(basis: standardBasis),
        exhaustGasTemperatureC: .unavailable(basis: standardBasis),
        differentialPressureKPa: .unavailable(basis: standardBasis),
        defLevelPercent: .unavailable(basis: standardBasis)
    )

    static let standardBasis = "Standard OBD-II does not expose this. It needs a manufacturer-specific request that has been verified for your exact model."

    var hasAnyValue: Bool {
        sootLoadPercent.isAvailable
            || regenerationStatus.isAvailable
            || distanceSinceRegenerationKm.isAvailable
            || exhaustGasTemperatureC.isAvailable
            || differentialPressureKPa.isAvailable
            || defLevelPercent.isAvailable
    }

    /// Builds telemetry from a profile's validated capabilities.
    ///
    /// Returns `.unavailable` whenever the profile has no usable capability, which is
    /// the case for every profile that ships today. This is the extension point for
    /// enhanced support, not a promise that it exists.
    static func from(profile: VehicleProfile?, readings: [ManufacturerCapability.Kind: Double]) -> DPFTelemetry {
        guard let profile, !profile.usableManufacturerCapabilities.isEmpty else { return .unavailable }

        var telemetry = DPFTelemetry.unavailable
        for capability in profile.usableManufacturerCapabilities {
            guard let value = readings[capability.kind] else { continue }
            let basis = "Read from your vehicle using a request validated for this model."
            switch capability.kind {
            case .dpfSootLoad:
                telemetry.sootLoadPercent = .measured(value).withBasis(basis)
            case .distanceSinceRegeneration:
                telemetry.distanceSinceRegenerationKm = .measured(value).withBasis(basis)
            case .exhaustGasTemperature:
                telemetry.exhaustGasTemperatureC = .measured(value).withBasis(basis)
            case .dpfDifferentialPressure:
                telemetry.differentialPressureKPa = .measured(value).withBasis(basis)
            case .defLevel:
                telemetry.defLevelPercent = .measured(value).withBasis(basis)
            case .dpfRegenerationStatus, .transmissionOilTemperature, .other:
                continue
            }
        }
        return telemetry
    }
}
