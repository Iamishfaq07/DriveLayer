import Foundation

/// How much DriveLayer actually knows about a vehicle. This tier is shown to the
/// driver and gates every vehicle-specific feature. See docs/VEHICLE_PROFILES.md.
enum ProfileValidationTier: String, Codable, CaseIterable, Sendable {
    /// Specs confirmed against published documentation, and any vehicle-specific
    /// telemetry in the profile has been verified on a real car of this model.
    case validated
    /// Model-level specs are known, but no vehicle-specific telemetry is proven.
    case experimental
    /// Nothing model-specific: standard OBD-II behaviour and generic defaults only.
    case generic

    var label: String {
        switch self {
        case .validated: return "Validated"
        case .experimental: return "Experimental"
        case .generic: return "Generic OBD-II"
        }
    }

    var explanation: String {
        switch self {
        case .validated:
            return "Specifications and vehicle-specific data for this model have been verified."
        case .experimental:
            return "Model specifications are known. Vehicle-specific telemetry has not been verified, so DriveLayer sticks to standard OBD-II data."
        case .generic:
            return "DriveLayer will use standard OBD-II data and generic defaults. Add your car's details to sharpen its estimates."
        }
    }
}

/// A read-only manufacturer-specific signal DriveLayer *could* surface once it has
/// been verified on a real vehicle of this model.
///
/// A capability without `validatedRequest` is an extension point, not a feature:
/// nothing is ever requested from the vehicle for it. DriveLayer does not ship
/// guessed manufacturer PIDs — see docs/OBD.md, "Manufacturer-specific PID policy".
struct ManufacturerCapability: Codable, Sendable, Equatable, Identifiable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case dpfSootLoad
        case dpfRegenerationStatus
        case distanceSinceRegeneration
        case exhaustGasTemperature
        case dpfDifferentialPressure
        case defLevel
        case transmissionOilTemperature
        case other
    }

    enum Validation: String, Codable, CaseIterable, Sendable {
        /// Known to exist on some vehicles, never confirmed on this model. Never requested.
        case unvalidated
        /// Observed on this model but not yet trusted for display.
        case observed
        /// Confirmed read-only, reproducible, and safe to display.
        case validated
    }

    var id: String
    var kind: Kind
    var displayName: String
    var validation: Validation
    /// The verified read-only request, present only for `.validated` capabilities.
    var validatedRequest: OBDPID?
    var evidenceNote: String?

    init(id: String,
         kind: Kind,
         displayName: String,
         validation: Validation = .unvalidated,
         validatedRequest: OBDPID? = nil,
         evidenceNote: String? = nil) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        // An unvalidated capability may never carry a request, whatever a caller passes.
        self.validation = validation
        self.validatedRequest = validation == .validated ? validatedRequest : nil
        self.evidenceNote = evidenceNote
    }

    var isUsable: Bool { validation == .validated && validatedRequest != nil }
}

/// The configurable description of a *model*, separate from a driver's individual car.
struct VehicleProfile: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var manufacturer: String
    var model: String
    var generation: String?
    var firstModelYear: Int?
    var lastModelYear: Int?
    var trim: String?
    var fuelType: FuelType
    var engine: EngineSpec
    var transmission: TransmissionType?
    var tankCapacityLitres: Double?
    var tankCapacitySource: SpecSource
    var nominalBatteryVoltage: Double
    var serviceIntervals: [ServiceIntervalSpec]
    /// Standard PIDs this model is *likely* to report. A hint for onboarding copy only —
    /// runtime capability discovery is always authoritative for what gets displayed.
    var expectedStandardPIDs: [OBDPID]
    var manufacturerCapabilities: [ManufacturerCapability]
    var operatingRanges: [OperatingRangeSpec]
    var validationTier: ProfileValidationTier
    var notes: [String]

    init(id: String,
         manufacturer: String,
         model: String,
         generation: String? = nil,
         firstModelYear: Int? = nil,
         lastModelYear: Int? = nil,
         trim: String? = nil,
         fuelType: FuelType,
         engine: EngineSpec = EngineSpec(),
         transmission: TransmissionType? = nil,
         tankCapacityLitres: Double? = nil,
         tankCapacitySource: SpecSource = .genericDefault,
         nominalBatteryVoltage: Double = 12.0,
         serviceIntervals: [ServiceIntervalSpec] = [],
         expectedStandardPIDs: [OBDPID] = [],
         manufacturerCapabilities: [ManufacturerCapability] = [],
         operatingRanges: [OperatingRangeSpec] = [],
         validationTier: ProfileValidationTier = .generic,
         notes: [String] = []) {
        self.id = id
        self.manufacturer = manufacturer
        self.model = model
        self.generation = generation
        self.firstModelYear = firstModelYear
        self.lastModelYear = lastModelYear
        self.trim = trim
        self.fuelType = fuelType
        self.engine = engine
        self.transmission = transmission
        self.tankCapacityLitres = tankCapacityLitres
        self.tankCapacitySource = tankCapacitySource
        self.nominalBatteryVoltage = nominalBatteryVoltage
        self.serviceIntervals = serviceIntervals
        self.expectedStandardPIDs = expectedStandardPIDs
        self.manufacturerCapabilities = manufacturerCapabilities
        self.operatingRanges = operatingRanges
        self.validationTier = validationTier
        self.notes = notes
    }

    var displayName: String {
        [manufacturer, model, trim].compactMap { $0 }.joined(separator: " ")
    }

    /// Prefers a range declared for the exact condition, falling back to `.any`.
    func operatingRange(for metric: VehicleMetric, condition: OperatingCondition = .any) -> OperatingRangeSpec? {
        if let exact = operatingRanges.first(where: { $0.metric == metric && $0.condition == condition }) {
            return exact
        }
        return operatingRanges.first { $0.metric == metric && $0.condition == .any }
    }

    /// Capabilities that may actually be requested from the vehicle.
    var usableManufacturerCapabilities: [ManufacturerCapability] {
        manufacturerCapabilities.filter { $0.isUsable }
    }

    func serviceInterval(id: String) -> ServiceIntervalSpec? {
        serviceIntervals.first { $0.id == id }
    }
}
