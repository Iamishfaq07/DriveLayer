import Foundation

/// The built-in profile catalog.
///
/// Two rules govern what may be added here:
///  1. Every number carries a `SpecSource`. Nothing is invented.
///  2. No profile ships a manufacturer-specific PID that has not been verified on a
///     real vehicle of that model. Extension points exist; guesses do not.
///
/// The list of planned models lives in docs/VEHICLE_PROFILES.md rather than here,
/// because a profile with unsourced specifications is worse than no profile.
enum VehicleProfileCatalog {

    static let harrier2026AdventureXPlusID = "tata.harrier.2026.adventure-x-plus"
    static let genericDieselID = "generic.diesel"
    static let genericPetrolID = "generic.petrol"

    static var all: [VehicleProfile] {
        [harrier2026AdventureXPlus, genericDiesel, genericPetrol]
    }

    static func profile(id: String) -> VehicleProfile? {
        all.first { $0.id == id }
    }

    /// The reference development vehicle: the 1.5-litre TGDi "Hyperion" turbo petrol.
    ///
    /// Tier is `.experimental`, not `.validated`: no Tata-specific telemetry has been
    /// verified on a real car, so DriveLayer restricts itself to standard OBD-II data
    /// for it.
    ///
    /// Rated power and torque are `nil` rather than filled in. This engine is recent
    /// enough that any figure here would be recalled rather than sourced, which is
    /// what rule 1 above forbids.
    ///
    /// Nothing reads these two fields today — they are recorded for a future display
    /// and have no driver-facing override — so an unsourced number would sit in the
    /// catalog as an unverifiable claim rather than causing visible harm. That is a
    /// reason to leave it out, not a reason to guess.
    static let harrier2026AdventureXPlus = VehicleProfile(
        id: harrier2026AdventureXPlusID,
        manufacturer: "Tata",
        model: "Harrier",
        generation: "Facelift",
        // The owner's stated model year, which is also what the profile id says. It was
        // 2025 here and 2026 in the id, and a profile that disagrees with its own
        // identifier is a profile nobody can check. Recorded as the model year of the
        // car DriveLayer is being built against rather than as a published launch date,
        // which is not something to guess at.
        firstModelYear: 2026,
        lastModelYear: nil,
        trim: "Adventure X+",
        fuelType: .petrol,
        engine: EngineSpec(
            familyName: "Hyperion TGDi",
            displacementLitres: 1.5,
            cylinderCount: 4,
            aspiration: .turbocharged,
            ratedPowerPS: nil,
            ratedTorqueNm: nil
        ),
        transmission: nil,
        // 50 L is the published figure for the diesel variant. The tank is a body
        // part and very likely carries over, but "very likely" is not a source, so
        // it is labelled a generic default rather than a published specification for
        // this engine. Garage → the vehicle shows the figure with this source beside
        // it and lets a driver replace it with one from their own manual.
        tankCapacityLitres: 50,
        tankCapacitySource: .genericDefault,
        nominalBatteryVoltage: 12.0,
        serviceIntervals: [
            ServiceIntervalSpec(
                id: "periodic-service",
                name: "Periodic service",
                distanceKm: 15_000,
                months: 12,
                source: .genericDefault,
                note: "Carried over from the diesel variant's published interval. Petrol intervals often differ — confirm against your owner's manual and service booklet before relying on this."
            ),
            ServiceIntervalSpec(
                id: "air-filter",
                name: "Air filter",
                distanceKm: 30_000,
                months: 24,
                source: .genericDefault,
                note: "Generic guidance, not a Tata-published figure."
            ),
            ServiceIntervalSpec(
                id: "brake-fluid",
                name: "Brake fluid",
                months: 24,
                source: .genericDefault,
                note: "Generic guidance. Follow your manual."
            ),
            ServiceIntervalSpec(
                id: "tyre-rotation",
                name: "Tyre rotation",
                distanceKm: 10_000,
                source: .genericDefault
            )
        ],
        expectedStandardPIDs: [],
        // No extension points. The diesel set is DPF and exhaust-temperature data
        // that a petrol engine does not have, and no petrol-specific Tata request
        // has been verified — a direct-injection engine may well have a particulate
        // filter, but "may well" does not earn a capability entry.
        manufacturerCapabilities: [],
        operatingRanges: petrolOperatingRanges,
        validationTier: .experimental,
        notes: [
            "Standard OBD-II data only. DriveLayer does not use unverified Tata-specific requests.",
            "Tank capacity and the service intervals are carried over from the diesel variant and are labelled generic defaults, not published figures for this engine. Confirm them against your owner's manual — you can enter your own.",
            "Rated power and torque are not recorded. DriveLayer would rather show nothing than a figure it cannot source.",
            "Temperature and voltage bands are generic petrol engineering defaults, not Tata-published limits. DriveLayer learns your car's own baselines from your drives."
        ]
    )

    static let genericDiesel = VehicleProfile(
        id: genericDieselID,
        manufacturer: "Generic",
        model: "Diesel vehicle",
        fuelType: .diesel,
        engine: EngineSpec(),
        tankCapacityLitres: nil,
        tankCapacitySource: .genericDefault,
        serviceIntervals: [
            ServiceIntervalSpec(id: "periodic-service", name: "Periodic service", distanceKm: 10_000, months: 12, source: .genericDefault)
        ],
        manufacturerCapabilities: dieselExtensionPoints,
        operatingRanges: dieselOperatingRanges,
        validationTier: .generic,
        notes: ["Standard OBD-II behaviour with generic diesel defaults. Add your car's tank size and service interval for sharper estimates."]
    )

    static let genericPetrol = VehicleProfile(
        id: genericPetrolID,
        manufacturer: "Generic",
        model: "Petrol vehicle",
        fuelType: .petrol,
        engine: EngineSpec(),
        tankCapacityLitres: nil,
        tankCapacitySource: .genericDefault,
        serviceIntervals: [
            ServiceIntervalSpec(id: "periodic-service", name: "Periodic service", distanceKm: 10_000, months: 12, source: .genericDefault)
        ],
        operatingRanges: petrolOperatingRanges,
        validationTier: .generic,
        notes: ["Standard OBD-II behaviour with generic petrol defaults."]
    )

    /// Declared so the app can *show* what enhanced support would add, while being
    /// explicit that none of it is available. Nothing here is ever requested.
    static let dieselExtensionPoints: [ManufacturerCapability] = [
        ManufacturerCapability(id: "dpf.soot-load", kind: .dpfSootLoad, displayName: "DPF soot load"),
        ManufacturerCapability(id: "dpf.regen-status", kind: .dpfRegenerationStatus, displayName: "Regeneration status"),
        ManufacturerCapability(id: "dpf.distance-since-regen", kind: .distanceSinceRegeneration, displayName: "Distance since regeneration"),
        ManufacturerCapability(id: "dpf.differential-pressure", kind: .dpfDifferentialPressure, displayName: "DPF differential pressure"),
        ManufacturerCapability(id: "exhaust.gas-temperature", kind: .exhaustGasTemperature, displayName: "Exhaust gas temperature")
    ]

    /// Generic engineering bands, deliberately wide. They exist to catch genuinely
    /// abnormal readings; "normal for this car" comes from learned baselines instead.
    static let dieselOperatingRanges: [OperatingRangeSpec] = [
        OperatingRangeSpec(metric: .coolantTemperatureC, condition: .warmedUp,
                           normalLow: 78, normalHigh: 103,
                           watchHigh: 108, criticalHigh: 115,
                           source: .genericDefault),
        OperatingRangeSpec(metric: .controlModuleVoltageV, condition: .engineRunning,
                           normalLow: 13.2, normalHigh: 14.8,
                           watchLow: 12.9, watchHigh: 15.0,
                           criticalLow: 11.9, criticalHigh: 15.4,
                           source: .genericDefault),
        OperatingRangeSpec(metric: .controlModuleVoltageV, condition: .engineOff,
                           normalLow: 12.2, normalHigh: 12.9,
                           watchLow: 12.0, criticalLow: 11.6,
                           source: .genericDefault),
        OperatingRangeSpec(metric: .engineLoadPercent, condition: .engineRunning,
                           normalLow: 0, normalHigh: 92,
                           watchHigh: 97,
                           source: .genericDefault),
        OperatingRangeSpec(metric: .intakeAirTemperatureC, condition: .engineRunning,
                           normalLow: -20, normalHigh: 75,
                           watchHigh: 90,
                           source: .genericDefault)
    ]

    static let petrolOperatingRanges: [OperatingRangeSpec] = [
        OperatingRangeSpec(metric: .coolantTemperatureC, condition: .warmedUp,
                           normalLow: 80, normalHigh: 105,
                           watchHigh: 110, criticalHigh: 118,
                           source: .genericDefault),
        OperatingRangeSpec(metric: .controlModuleVoltageV, condition: .engineRunning,
                           normalLow: 13.2, normalHigh: 14.8,
                           watchLow: 12.9, watchHigh: 15.0,
                           criticalLow: 11.9, criticalHigh: 15.4,
                           source: .genericDefault),
        OperatingRangeSpec(metric: .controlModuleVoltageV, condition: .engineOff,
                           normalLow: 12.2, normalHigh: 12.9,
                           watchLow: 12.0, criticalLow: 11.6,
                           source: .genericDefault),
        // Neither band is fuel-specific; petrol was simply missing them.
        OperatingRangeSpec(metric: .engineLoadPercent, condition: .engineRunning,
                           normalLow: 0, normalHigh: 92,
                           watchHigh: 97,
                           source: .genericDefault),
        OperatingRangeSpec(metric: .intakeAirTemperatureC, condition: .engineRunning,
                           normalLow: -20, normalHigh: 75,
                           watchHigh: 90,
                           source: .genericDefault)
    ]
}
