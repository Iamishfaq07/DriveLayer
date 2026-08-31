import Foundation

enum FuelType: String, Codable, CaseIterable, Sendable {
    case petrol, diesel, cng, petrolHybrid, dieselHybrid, electric

    var isDiesel: Bool { self == .diesel || self == .dieselHybrid }

    var displayName: String {
        switch self {
        case .petrol: return "Petrol"
        case .diesel: return "Diesel"
        case .cng: return "CNG"
        case .petrolHybrid: return "Petrol hybrid"
        case .dieselHybrid: return "Diesel hybrid"
        case .electric: return "Electric"
        }
    }

    /// Energy content used only for clearly-labelled fuel estimates.
    /// `nil` where a volumetric estimate makes no sense.
    var typicalDensityKgPerLitre: Double? {
        switch self {
        case .diesel, .dieselHybrid: return 0.832
        case .petrol, .petrolHybrid: return 0.745
        case .cng, .electric: return nil
        }
    }
}

enum TransmissionType: String, Codable, CaseIterable, Sendable {
    case manual, torqueConverterAutomatic, dualClutch, automatedManual, cvt, singleSpeed

    var displayName: String {
        switch self {
        case .manual: return "Manual"
        case .torqueConverterAutomatic: return "Automatic"
        case .dualClutch: return "Dual clutch"
        case .automatedManual: return "AMT"
        case .cvt: return "CVT"
        case .singleSpeed: return "Single speed"
        }
    }
}

enum Aspiration: String, Codable, CaseIterable, Sendable {
    case naturallyAspirated, turbocharged, supercharged, turbochargedElectric
}

struct EngineSpec: Codable, Sendable, Equatable {
    var familyName: String?
    var displacementLitres: Double?
    var cylinderCount: Int?
    var aspiration: Aspiration?
    var ratedPowerPS: Double?
    var ratedTorqueNm: Double?

    var shortDescription: String {
        var parts: [String] = []
        if let displacementLitres { parts.append(String(format: "%.1fL", displacementLitres)) }
        if let familyName { parts.append(familyName) }
        return parts.isEmpty ? "Engine" : parts.joined(separator: " ")
    }
}

/// Where a specification number came from. Shown in the UI so a driver knows
/// whether DriveLayer is repeating a brochure figure or something they told it.
enum SpecSource: String, Codable, CaseIterable, Sendable {
    /// Published manufacturer specification for the model.
    case publishedSpecification
    /// Taken from the owner's manual by the user.
    case ownerManual
    /// Entered by the driver.
    case userProvided
    /// A generic engineering default that is not specific to this vehicle.
    case genericDefault

    var label: String {
        switch self {
        case .publishedSpecification: return "Published specification"
        case .ownerManual: return "Owner's manual"
        case .userProvided: return "You entered this"
        case .genericDefault: return "Generic default"
        }
    }

    /// Generic defaults must be presented as guidance, never as fact about the car.
    var isVehicleSpecific: Bool { self != .genericDefault }
}

/// A metric a vehicle can report or that DriveLayer can derive, used as the key
/// for baselines and expected operating ranges.
enum VehicleMetric: String, Codable, CaseIterable, Sendable {
    case coolantTemperatureC
    case controlModuleVoltageV
    case engineLoadPercent
    case engineRPM
    case intakeAirTemperatureC
    case ambientAirTemperatureC
    case throttlePositionPercent
    case fuelLevelPercent
    case fuelRateLitresPerHour
    case vehicleSpeedKmh
    case intakeManifoldPressureKPa
    case economyKmPerLitre
    case warmUpDurationSeconds
    case idleFractionPercent
    case tripDistanceKm
    // Added for the Hyperion work. Fuel trims and equivalence ratio are the two that
    // matter most: they are how a petrol engine reports what it is doing about the
    // mixture, and they mean nothing without the conditions they were measured in.
    case shortTermFuelTrimPercent
    case longTermFuelTrimPercent
    case commandedEquivalenceRatio
    case fuelRailPressureKPa
    case catalystTemperatureC
    case ethanolPercent
    case barometricPressureKPa
    case oilTemperatureC
    case absoluteLoadPercent
    case acceleratorPedalPercent
    case massAirFlowGramsPerSecond
    case timingAdvanceDegrees
    /// The raw fuel system status bitfield from PID 03.
    ///
    /// Stored as its code rather than as a decoded state because telemetry is numeric all
    /// the way through, and a bitfield is a number. `FuelSystemStatus.decode(code:)`
    /// reconstructs the meaning wherever it is needed, which is cheaper than a parallel
    /// channel for one PID.
    case fuelSystemStatusCode

    var displayName: String {
        switch self {
        case .coolantTemperatureC: return "Coolant temperature"
        case .controlModuleVoltageV: return "Battery voltage"
        case .engineLoadPercent: return "Engine load"
        case .engineRPM: return "Engine speed"
        case .intakeAirTemperatureC: return "Intake air temperature"
        case .ambientAirTemperatureC: return "Ambient temperature"
        case .throttlePositionPercent: return "Throttle position"
        case .fuelLevelPercent: return "Fuel level"
        case .fuelRateLitresPerHour: return "Fuel rate"
        case .vehicleSpeedKmh: return "Speed"
        case .intakeManifoldPressureKPa: return "Manifold pressure"
        case .economyKmPerLitre: return "Fuel economy"
        case .warmUpDurationSeconds: return "Warm-up duration"
        case .idleFractionPercent: return "Idle share"
        case .tripDistanceKm: return "Trip distance"
        case .shortTermFuelTrimPercent: return "Short-term fuel trim"
        case .longTermFuelTrimPercent: return "Long-term fuel trim"
        case .commandedEquivalenceRatio: return "Commanded equivalence ratio"
        case .fuelRailPressureKPa: return "Fuel rail pressure"
        case .catalystTemperatureC: return "Catalyst temperature"
        case .ethanolPercent: return "Ethanol content"
        case .barometricPressureKPa: return "Barometric pressure"
        case .oilTemperatureC: return "Oil temperature"
        case .absoluteLoadPercent: return "Absolute engine load"
        case .acceleratorPedalPercent: return "Accelerator pedal"
        case .massAirFlowGramsPerSecond: return "Mass air flow"
        case .timingAdvanceDegrees: return "Ignition timing"
        case .fuelSystemStatusCode: return "Fuel system status"
        }
    }

    var unitLabel: String {
        switch self {
        case .coolantTemperatureC, .intakeAirTemperatureC, .ambientAirTemperatureC: return "°C"
        case .controlModuleVoltageV: return "V"
        case .engineLoadPercent, .throttlePositionPercent, .fuelLevelPercent, .idleFractionPercent: return "%"
        case .engineRPM: return "rpm"
        case .fuelRateLitresPerHour: return "L/h"
        case .vehicleSpeedKmh: return "km/h"
        case .intakeManifoldPressureKPa: return "kPa"
        case .economyKmPerLitre: return "km/L"
        case .warmUpDurationSeconds: return "s"
        case .tripDistanceKm: return "km"
        case .shortTermFuelTrimPercent, .longTermFuelTrimPercent,
             .ethanolPercent, .absoluteLoadPercent, .acceleratorPedalPercent: return "%"
        case .commandedEquivalenceRatio: return "λ"
        case .fuelRailPressureKPa, .barometricPressureKPa: return "kPa"
        case .catalystTemperatureC, .oilTemperatureC: return "°C"
        case .massAirFlowGramsPerSecond: return "g/s"
        case .timingAdvanceDegrees: return "°"
        case .fuelSystemStatusCode: return ""
        }
    }
}

/// The engine state a range applies to. Battery voltage and coolant temperature
/// mean completely different things at rest and under load, so a range that does
/// not say which state it describes is a source of false alarms.
enum OperatingCondition: String, Codable, CaseIterable, Sendable {
    case any
    case engineRunning
    case engineOff
    /// Engine running and past its warm-up phase.
    case warmedUp
}

/// Expected operating band for a metric. Bands are inclusive and evaluated
/// outermost-first, so a value can never be both `.watch` and `.critical`.
struct OperatingRangeSpec: Codable, Sendable, Equatable {
    var metric: VehicleMetric
    var condition: OperatingCondition
    var normalLow: Double?
    var normalHigh: Double?
    var watchLow: Double?
    var watchHigh: Double?
    var criticalLow: Double?
    var criticalHigh: Double?
    var source: SpecSource

    init(metric: VehicleMetric,
         condition: OperatingCondition = .any,
         normalLow: Double? = nil,
         normalHigh: Double? = nil,
         watchLow: Double? = nil,
         watchHigh: Double? = nil,
         criticalLow: Double? = nil,
         criticalHigh: Double? = nil,
         source: SpecSource) {
        self.metric = metric
        self.condition = condition
        self.normalLow = normalLow
        self.normalHigh = normalHigh
        self.watchLow = watchLow
        self.watchHigh = watchHigh
        self.criticalLow = criticalLow
        self.criticalHigh = criticalHigh
        self.source = source
    }

    func status(for value: Double) -> SemanticStatus {
        if let criticalHigh, value >= criticalHigh { return .critical }
        if let criticalLow, value <= criticalLow { return .critical }
        if let watchHigh, value >= watchHigh { return .attention }
        if let watchLow, value <= watchLow { return .attention }
        if let normalHigh, value > normalHigh { return .watch }
        if let normalLow, value < normalLow { return .watch }
        if normalLow == nil && normalHigh == nil { return .unknown }
        return .normal
    }
}

/// A periodic service item defined by distance, time, or both (whichever comes first).
struct ServiceIntervalSpec: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var name: String
    var distanceKm: Double?
    var months: Int?
    var source: SpecSource
    var note: String?

    init(id: String, name: String, distanceKm: Double? = nil, months: Int? = nil, source: SpecSource, note: String? = nil) {
        self.id = id
        self.name = name
        self.distanceKm = distanceKm
        self.months = months
        self.source = source
        self.note = note
    }
}
