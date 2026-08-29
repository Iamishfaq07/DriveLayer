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

    /// The reference development vehicle.
    ///
    /// Tier is `.experimental`, not `.validated`: the model specifications below come
    /// from published figures, but no Tata-specific telemetry has been verified on a
    /// real car, so DriveLayer restricts itself to standard OBD-II data for it.
    static let harrier2026AdventureXPlus = VehicleProfile(
        id: harrier2026AdventureXPlusID,
        manufacturer: "Tata",
        model: "Harrier",
        generation: "Facelift",
        firstModelYear: 2023,
        lastModelYear: nil,
        trim: "Adventure X+",
        fuelType: .diesel,
        engine: EngineSpec(
            familyName: "Kryotec",
            displacementLitres: 2.0,
            cylinderCount: 4,
            aspiration: .turbocharged,
            ratedPowerPS: 170,
            ratedTorqueNm: 350
        ),
        transmission: nil,
        tankCapacityLitres: 50,
        tankCapacitySource: .publishedSpecification,
        nominalBatteryVoltage: 12.0,
        serviceIntervals: [
            ServiceIntervalSpec(
                id: "periodic-service",
                name: "Periodic service",
                distanceKm: 15_000,
                months: 12,
                source: .publishedSpecification,
                note: "Confirm against your owner's manual and service booklet — intervals vary by market and usage."
            ),
            ServiceIntervalSpec(
                id: "air-filter",
                name: "Air filter",
                distanceKm: 30_000,
                months: 24,
                source: .genericDefault,
                note: "Generic diesel guidance, not a Tata-published figure."
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
        manufacturerCapabilities: dieselExtensionPoints,
        operatingRanges: dieselOperatingRanges,
        validationTier: .experimental,
        notes: [
            "Standard OBD-II data only. DriveLayer does not use unverified Tata-specific requests.",
            "Tank capacity and the periodic service interval are published figures — confirm them against your owner's manual.",
            "Temperature and voltage bands are generic diesel engineering defaults, not Tata-published limits. DriveLayer learns your car's own baselines from your drives."
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
                           source: .genericDefault)
    ]
}
