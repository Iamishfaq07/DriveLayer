import Foundation

enum DTCSeriousness: String, Codable, CaseIterable, Sendable {
    /// Worth knowing, no action needed right now.
    case informational
    /// Book it into a service at the next convenient opportunity.
    case service
    /// Get it looked at soon; continued driving may make it worse or costlier.
    case prompt
    /// Stop driving where it is safe to do so and get help.
    case urgent

    var label: String {
        switch self {
        case .informational: return "For information"
        case .service: return "Mention at next service"
        case .prompt: return "Get it checked soon"
        case .urgent: return "Stop safely and get help"
        }
    }

    var status: SemanticStatus {
        switch self {
        case .informational: return .watch
        case .service: return .watch
        case .prompt: return .attention
        case .urgent: return .critical
        }
    }
}

/// A plain-language explanation of a trouble code.
///
/// A DTC names a *symptom the ECU observed*, never the failed part. Every field here
/// is written to preserve that distinction — `possibleCauses` is a list of things
/// worth checking, not a diagnosis.
struct DTCExplanation: Sendable, Equatable {
    var code: String
    /// The standard definition of the code.
    var standardDefinition: String
    var plainLanguage: String
    var commonSymptoms: [String]
    var possibleCauses: [String]
    var seriousness: DTCSeriousness
    var drivingGuidance: String
    /// Where the definition comes from, shown in the UI.
    var source: String
    /// True when this is a structural interpretation of the code number rather than
    /// a specific definition DriveLayer holds.
    var isGenericFallback: Bool
}

/// Explanations for generic (SAE-defined) trouble codes.
///
/// Manufacturer-specific codes — the P1xxx range and others — are deliberately not
/// guessed. For anything not in the table DriveLayer explains what the code's
/// structure means and says plainly that it doesn't hold a specific definition.
enum DTCCatalog {

    static func explanation(for code: String) -> DTCExplanation {
        let normalised = code.uppercased().trimmingCharacters(in: .whitespaces)
        if let known = table[normalised] { return known }
        return fallbackExplanation(for: normalised)
    }

    /// Structural interpretation, using only what the code format itself guarantees.
    static func fallbackExplanation(for code: String) -> DTCExplanation {
        let isManufacturerSpecific = code.count >= 2 && (code.dropFirst().first == "1" || code.dropFirst().first == "3")
        let area = subsystemDescription(for: code)

        let plain: String
        if isManufacturerSpecific {
            plain = "This is a manufacturer-specific code. DriveLayer doesn't hold a verified definition for it, so a workshop with the manufacturer's diagnostic data will be able to say more."
        } else {
            plain = "DriveLayer doesn't hold a specific description for this code. From its format it relates to \(area.lowercased())."
        }

        return DTCExplanation(
            code: code,
            standardDefinition: area,
            plainLanguage: plain,
            commonSymptoms: [],
            possibleCauses: [],
            seriousness: .service,
            drivingGuidance: "Without a verified definition DriveLayer can't judge how urgent this is. If the car is driving normally and no warning light is flashing, mention it at your next service; if anything feels wrong, get it checked sooner.",
            source: "Interpreted from the code's structure",
            isGenericFallback: true
        )
    }

    /// The standard subsystem groupings for powertrain codes.
    static func subsystemDescription(for code: String) -> String {
        guard let first = code.first, let system = DTCSystem(rawValue: String(first)) else {
            return "An unrecognised code format"
        }
        guard system == .powertrain, code.count >= 3 else {
            return "\(system.displayName) systems"
        }
        let group = code.dropFirst(2).prefix(1)
        switch group {
        case "0": return "Fuel and air metering, and auxiliary emission controls"
        case "1": return "Fuel and air metering"
        case "2": return "Fuel and air metering (injector circuits)"
        case "3": return "Ignition system or misfire detection"
        case "4": return "Auxiliary emission controls"
        case "5": return "Vehicle speed control and idle control"
        case "6": return "Control module and output circuits"
        case "7", "8", "9": return "Transmission"
        case "A", "B", "C": return "Hybrid propulsion"
        default: return "Powertrain systems"
        }
    }

    private static let sae = "Generic SAE J2012 definition"

    private static let table: [String: DTCExplanation] = {
        var result: [String: DTCExplanation] = [:]
        for entry in entries { result[entry.code] = entry }
        return result
    }()

    private static let entries: [DTCExplanation] = [
        DTCExplanation(
            code: "P0401",
            standardDefinition: "Exhaust gas recirculation flow insufficient detected",
            plainLanguage: "The engine expected exhaust gas to be recirculated back into the intake and measured less flow than it wanted.",
            commonSymptoms: ["Warning light on", "Rougher idle", "Slightly higher fuel use", "Possible failed emissions test"],
            possibleCauses: ["Carbon build-up in the EGR passages or valve", "A stuck EGR valve", "A blocked or leaking EGR cooler", "A faulty differential pressure sensor"],
            seriousness: .service,
            drivingGuidance: "Normally safe to keep driving in the short term. Have it looked at, since restricted EGR flow tends to get worse and can affect emissions.",
            source: sae,
            isGenericFallback: false
        ),
        DTCExplanation(
            code: "P0402",
            standardDefinition: "Exhaust gas recirculation flow excessive detected",
            plainLanguage: "More exhaust gas is being recirculated into the intake than the engine asked for.",
            commonSymptoms: ["Warning light on", "Rough or stalling idle", "Hesitation under load"],
            possibleCauses: ["An EGR valve stuck open", "A faulty EGR position or pressure sensor", "A vacuum or control fault"],
            seriousness: .service,
            drivingGuidance: "Usually driveable. Get it inspected, especially if idle is rough or the engine stalls.",
            source: sae,
            isGenericFallback: false
        ),
        DTCExplanation(
            code: "P2002",
            standardDefinition: "Diesel particulate filter efficiency below threshold (bank 1)",
            plainLanguage: "The vehicle judged that its diesel particulate filter is not trapping soot as effectively as expected.",
            commonSymptoms: ["Warning light on", "Reduced power in some vehicles", "Higher fuel use"],
            possibleCauses: ["A filter loaded with soot or ash", "Regenerations that keep being interrupted", "A pressure or temperature sensor fault", "An exhaust leak before the filter"],
            seriousness: .prompt,
            drivingGuidance: "Have this diagnosed properly rather than driving on indefinitely. DriveLayer cannot tell you the filter's actual soot load, and it will not attempt any regeneration or reset — that is workshop work.",
            source: sae,
            isGenericFallback: false
        ),
        DTCExplanation(
            code: "P2463",
            standardDefinition: "Diesel particulate filter restriction — soot accumulation",
            plainLanguage: "The vehicle believes soot has built up in the particulate filter beyond its normal working range.",
            commonSymptoms: ["Warning light on", "Reduced power", "Cooling fan running more"],
            possibleCauses: ["A long run of short, cold journeys", "Interrupted regeneration cycles", "A sensor or EGR fault preventing regeneration"],
            seriousness: .prompt,
            drivingGuidance: "Get it inspected. Manufacturer guidance for this condition usually involves a specific driving pattern or a workshop procedure — follow your manual rather than guessing.",
            source: sae,
            isGenericFallback: false
        ),
        DTCExplanation(
            code: "P242F",
            standardDefinition: "Diesel particulate filter restriction — ash accumulation",
            plainLanguage: "The vehicle believes non-burnable ash has built up in the particulate filter. Ash accumulates over a filter's life and is not removed by regeneration.",
            commonSymptoms: ["Warning light on", "Reduced power", "More frequent regeneration attempts"],
            possibleCauses: ["Normal end-of-life ash loading", "Oil consumption adding ash", "A sensor fault reporting incorrect back-pressure"],
            seriousness: .prompt,
            drivingGuidance: "This needs a workshop: ash loading is typically resolved by cleaning or replacing the filter, not by driving differently.",
            source: sae,
            isGenericFallback: false
        ),
        DTCExplanation(
            code: "P0299",
            standardDefinition: "Turbocharger/supercharger underboost condition",
            plainLanguage: "The engine asked for more boost pressure than it actually measured.",
            commonSymptoms: ["Noticeable loss of power", "Limp mode", "Warning light on"],
            possibleCauses: ["A boost leak in a hose or intercooler pipe", "A sticking variable-geometry turbo mechanism", "A faulty boost pressure sensor", "A restricted air filter or blocked particulate filter"],
            seriousness: .prompt,
            drivingGuidance: "Drive gently and get it checked soon. Persistent underboost is often a leak, which is cheap to fix early and expensive to ignore.",
            source: sae,
            isGenericFallback: false
        ),
        DTCExplanation(
            code: "P0234",
            standardDefinition: "Turbocharger/supercharger overboost condition",
            plainLanguage: "Boost pressure went above what the engine commanded.",
            commonSymptoms: ["Limp mode", "Sudden power cut under acceleration", "Warning light on"],
            possibleCauses: ["A stuck wastegate or VGT actuator", "A faulty boost control valve", "A boost pressure sensor reading incorrectly"],
            seriousness: .prompt,
            drivingGuidance: "Avoid hard acceleration and get it inspected. Sustained overboost can damage the engine.",
            source: sae,
            isGenericFallback: false
        ),
        DTCExplanation(
            code: "P0087",
            standardDefinition: "Fuel rail/system pressure too low",
            plainLanguage: "Fuel pressure in the rail fell below what the engine needs.",
            commonSymptoms: ["Loss of power under load", "Hesitation", "Hard starting", "Limp mode"],
            possibleCauses: ["A clogged fuel filter", "A weak lift or high-pressure pump", "A leaking injector or pressure regulator", "Contaminated fuel"],
            seriousness: .prompt,
            drivingGuidance: "Get it checked promptly. Running a high-pressure diesel system with low pressure can damage the pump.",
            source: sae,
            isGenericFallback: false
        ),
        DTCExplanation(
            code: "P0128",
            standardDefinition: "Coolant thermostat below regulating temperature",
            plainLanguage: "The engine took longer to reach its normal operating temperature than expected.",
            commonSymptoms: ["Slow warm-up", "Weak cabin heating", "Higher fuel use in cold weather"],
            possibleCauses: ["A thermostat stuck open", "A faulty coolant temperature sensor", "A low coolant level"],
            seriousness: .service,
            drivingGuidance: "Safe to drive, but worth fixing: an engine that never fully warms up uses more fuel and, on a diesel, makes particulate filter regeneration less likely.",
            source: sae,
            isGenericFallback: false
        ),
        DTCExplanation(
            code: "P0300",
            standardDefinition: "Random/multiple cylinder misfire detected",
            plainLanguage: "The engine detected misfires that aren't confined to one cylinder.",
            commonSymptoms: ["Rough running", "Flashing warning light", "Loss of power", "Higher fuel use"],
            possibleCauses: ["Fuel delivery problems", "Ignition faults on petrol engines", "Injector faults on diesels", "A vacuum leak", "Low compression"],
            seriousness: .urgent,
            drivingGuidance: "If the warning light is flashing, stop safely and don't continue: an active misfire can destroy the catalytic converter quickly. If it is steady, drive gently to a workshop.",
            source: sae,
            isGenericFallback: false
        ),
        DTCExplanation(
            code: "P0420",
            standardDefinition: "Catalyst system efficiency below threshold (bank 1)",
            plainLanguage: "The vehicle compared the sensors before and after the catalytic converter and judged that it isn't cleaning the exhaust as well as expected.",
            commonSymptoms: ["Warning light on", "Often no change in how the car drives", "Failed emissions test"],
            possibleCauses: ["An ageing catalytic converter", "A faulty downstream oxygen sensor", "An exhaust leak", "An engine fault upstream contaminating the converter"],
            seriousness: .service,
            drivingGuidance: "Usually safe to keep driving. Have the sensors checked before assuming the converter needs replacing — this code often points at a sensor.",
            source: sae,
            isGenericFallback: false
        ),
        DTCExplanation(
            code: "P0171",
            standardDefinition: "System too lean (bank 1)",
            plainLanguage: "The engine had to add fuel to correct a mixture that measured too lean.",
            commonSymptoms: ["Rough idle", "Hesitation", "Warning light on"],
            possibleCauses: ["An intake or vacuum leak", "A dirty mass air flow sensor", "A weak fuel pump or blocked filter", "A faulty oxygen sensor"],
            seriousness: .service,
            drivingGuidance: "Generally driveable. Worth diagnosing, as a persistent lean condition can raise combustion temperatures.",
            source: sae,
            isGenericFallback: false
        ),
        DTCExplanation(
            code: "P0562",
            standardDefinition: "System voltage low",
            plainLanguage: "The control module measured supply voltage below its acceptable range.",
            commonSymptoms: ["Dim lights", "Slow cranking", "Several unrelated warnings at once"],
            possibleCauses: ["A failing battery", "A charging system or alternator fault", "Corroded or loose battery terminals", "A worn drive belt"],
            seriousness: .prompt,
            drivingGuidance: "Have the battery and charging system tested soon — low system voltage can leave you stranded and produces misleading faults elsewhere.",
            source: sae,
            isGenericFallback: false
        ),
        DTCExplanation(
            code: "P0563",
            standardDefinition: "System voltage high",
            plainLanguage: "The control module measured supply voltage above its acceptable range.",
            commonSymptoms: ["Bright or flickering lights", "Warning light on"],
            possibleCauses: ["A faulty voltage regulator or alternator", "A wiring fault"],
            seriousness: .prompt,
            drivingGuidance: "Get it checked promptly — overvoltage can damage electronics.",
            source: sae,
            isGenericFallback: false
        ),
        DTCExplanation(
            code: "P0101",
            standardDefinition: "Mass air flow circuit range/performance problem",
            plainLanguage: "The air flow the sensor reported didn't match what the engine expected for the conditions.",
            commonSymptoms: ["Hesitation", "Rough idle", "Higher fuel use", "Warning light on"],
            possibleCauses: ["A dirty or ageing air flow sensor", "An air leak after the sensor", "A restricted air filter", "An exhaust restriction"],
            seriousness: .service,
            drivingGuidance: "Normally driveable. Worth addressing, as the engine is running on a measurement it doesn't trust.",
            source: sae,
            isGenericFallback: false
        ),
        DTCExplanation(
            code: "P0117",
            standardDefinition: "Engine coolant temperature sensor circuit low input",
            plainLanguage: "The coolant temperature signal was below the range the module accepts, which usually points at the circuit rather than the engine actually being cold.",
            commonSymptoms: ["Warning light on", "Cooling fans behaving oddly", "Poor cold-start behaviour"],
            possibleCauses: ["A short in the sensor wiring", "A failed sensor", "A connector fault"],
            seriousness: .service,
            drivingGuidance: "Treat displayed coolant temperature as unreliable until this is fixed. Watch the dashboard gauge rather than app readings.",
            source: sae,
            isGenericFallback: false
        ),
        DTCExplanation(
            code: "P0118",
            standardDefinition: "Engine coolant temperature sensor circuit high input",
            plainLanguage: "The coolant temperature signal was above the range the module accepts, which usually points at an open circuit.",
            commonSymptoms: ["Warning light on", "Cooling fans running constantly", "Poor running when cold"],
            possibleCauses: ["An open circuit in the sensor wiring", "A failed sensor", "A connector fault"],
            seriousness: .service,
            drivingGuidance: "Treat displayed coolant temperature as unreliable until this is fixed.",
            source: sae,
            isGenericFallback: false
        ),
        DTCExplanation(
            code: "P0016",
            standardDefinition: "Crankshaft position — camshaft position correlation (bank 1 sensor A)",
            plainLanguage: "The crankshaft and camshaft position signals didn't line up the way the engine expects.",
            commonSymptoms: ["Hard starting", "Rough running", "Rattle on start-up", "Warning light on"],
            possibleCauses: ["A stretched timing chain or worn tensioner", "A cam phaser fault", "Low or dirty oil", "A sensor or wiring fault"],
            seriousness: .urgent,
            drivingGuidance: "Have this diagnosed before driving far. Timing-related faults can cause serious engine damage if the cause is mechanical.",
            source: sae,
            isGenericFallback: false
        )
    ]
}
