import Foundation

enum InsightCategory: String, Codable, CaseIterable, Sendable {
    case vehicle, diesel, battery, fuel, terrain, weather, road, maintenance, trip, safety, efficiency

    var displayName: String {
        switch self {
        case .vehicle: return "Vehicle"
        case .diesel: return "Diesel"
        case .battery: return "Battery"
        case .fuel: return "Fuel"
        case .terrain: return "Terrain"
        case .weather: return "Weather"
        case .road: return "Road"
        case .maintenance: return "Maintenance"
        case .trip: return "Trip"
        case .safety: return "Safety"
        case .efficiency: return "Efficiency"
        }
    }

    var symbolName: String {
        switch self {
        case .vehicle: return "car"
        case .diesel: return "fuelpump.circle"
        case .battery: return "minus.plus.batteryblock"
        case .fuel: return "fuelpump"
        case .terrain: return "mountain.2"
        case .weather: return "cloud.sun"
        case .road: return "road.lanes"
        case .maintenance: return "wrench.and.screwdriver"
        case .trip: return "map"
        case .safety: return "exclamationmark.shield"
        case .efficiency: return "leaf"
        }
    }
}

/// One number behind an insight, with where it came from.
///
/// Insights carry their evidence so the app can answer "how do you know that?" — and
/// so a reader can tell a measurement from an inference at a glance.
struct InsightSourceDatum: Sendable, Equatable, Identifiable {
    var id: String { label }
    var label: String
    var formattedValue: String
    var provenance: DataProvenance

    init(label: String, formattedValue: String, provenance: DataProvenance) {
        self.label = label
        self.formattedValue = formattedValue
        self.provenance = provenance
    }

    static func measured(_ label: String, _ value: String) -> InsightSourceDatum {
        InsightSourceDatum(label: label, formattedValue: value, provenance: .measured)
    }

    static func estimated(_ label: String, _ value: String) -> InsightSourceDatum {
        InsightSourceDatum(label: label, formattedValue: value, provenance: .estimated)
    }

    static func inferred(_ label: String, _ value: String) -> InsightSourceDatum {
        InsightSourceDatum(label: label, formattedValue: value, provenance: .inferred)
    }
}

/// A single thing DriveLayer has to say.
///
/// `id` is derived from the rule and its subject rather than random, so re-running the
/// engine updates an insight instead of stacking duplicates.
struct DriveInsight: Sendable, Equatable, Identifiable {
    var id: String
    var category: InsightCategory
    var severity: SemanticStatus
    /// Short, in the app's headline voice: "BATTERY WATCH", "LONG CLIMB".
    var title: String
    /// One or two sentences. This is what appears on CarPlay and in a widget.
    var summary: String
    /// The longer explanation, shown when parked.
    var details: String?
    /// 0...1. Bounded by the weakest provenance behind it.
    var confidence: Double
    var sourceData: [InsightSourceDatum]
    var recommendedAction: String?
    var createdAt: Date
    var expiresAt: Date?
    /// Whether it is appropriate to put this in front of someone who is driving.
    var isDrivingSafeToDisplay: Bool

    init(id: String,
         category: InsightCategory,
         severity: SemanticStatus,
         title: String,
         summary: String,
         details: String? = nil,
         confidence: Double = 0.8,
         sourceData: [InsightSourceDatum] = [],
         recommendedAction: String? = nil,
         createdAt: Date,
         expiresAt: Date? = nil,
         isDrivingSafeToDisplay: Bool = true) {
        self.id = id
        self.category = category
        self.severity = severity
        self.title = title
        self.summary = summary
        self.details = details
        // Confidence can never exceed what the weakest piece of evidence supports.
        let ceiling = sourceData.map(\.provenance.confidenceCeiling).min() ?? 1.0
        self.confidence = Statistics.clamp(min(confidence, ceiling), 0...1)
        self.sourceData = sourceData
        self.recommendedAction = recommendedAction
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.isDrivingSafeToDisplay = isDrivingSafeToDisplay
    }

    func isValid(at date: Date) -> Bool {
        guard let expiresAt else { return true }
        return date < expiresAt
    }

    /// Ordering for lists and for what CarPlay shows first: severity dominates,
    /// then confidence, then recency.
    var priority: Double {
        Double(severity.rank) * 100 + confidence * 10
    }
}

/// Everything the rules are allowed to look at.
///
/// Assembling this explicitly — rather than letting rules reach into services — is
/// what keeps the engine testable: a rule is a pure function of this struct.
struct InsightContext: Sendable {
    var now: Date
    var vehicle: Vehicle?
    var profile: VehicleProfile?
    var isAdapterConnected: Bool
    var telemetry: VehicleTelemetry?
    var capabilities: OBDCapabilityReport?
    var currentTrip: Trip?
    var recentTrips: [Trip]
    var baselines: [BaselineKey: MetricBaseline]
    var gradient: GradientEstimate?
    var terrainFeature: TerrainFeature?
    var currentWeather: WeatherSnapshot?
    var weatherChanges: [WeatherChange]
    var troubleCodes: [DiagnosticTroubleCode]
    var maintenanceStatuses: [MaintenanceDueStatus]
    var documents: [DocumentRecord]
    var fuelStatus: FuelStatus?
    var dieselAssessment: DieselUsageAssessment?
    var isDriving: Bool

    init(now: Date,
         vehicle: Vehicle? = nil,
         profile: VehicleProfile? = nil,
         isAdapterConnected: Bool = false,
         telemetry: VehicleTelemetry? = nil,
         capabilities: OBDCapabilityReport? = nil,
         currentTrip: Trip? = nil,
         recentTrips: [Trip] = [],
         baselines: [BaselineKey: MetricBaseline] = [:],
         gradient: GradientEstimate? = nil,
         terrainFeature: TerrainFeature? = nil,
         currentWeather: WeatherSnapshot? = nil,
         weatherChanges: [WeatherChange] = [],
         troubleCodes: [DiagnosticTroubleCode] = [],
         maintenanceStatuses: [MaintenanceDueStatus] = [],
         documents: [DocumentRecord] = [],
         fuelStatus: FuelStatus? = nil,
         dieselAssessment: DieselUsageAssessment? = nil,
         isDriving: Bool = false) {
        self.now = now
        self.vehicle = vehicle
        self.profile = profile
        self.isAdapterConnected = isAdapterConnected
        self.telemetry = telemetry
        self.capabilities = capabilities
        self.currentTrip = currentTrip
        self.recentTrips = recentTrips
        self.baselines = baselines
        self.gradient = gradient
        self.terrainFeature = terrainFeature
        self.currentWeather = currentWeather
        self.weatherChanges = weatherChanges
        self.troubleCodes = troubleCodes
        self.maintenanceStatuses = maintenanceStatuses
        self.documents = documents
        self.fuelStatus = fuelStatus
        self.dieselAssessment = dieselAssessment
        self.isDriving = isDriving
    }

    func baseline(_ metric: VehicleMetric, _ context: BaselineContext) -> MetricBaseline? {
        baselines[BaselineKey(metric: metric, context: context)]
    }

    /// The baseline for the current driving context, falling back to the general one.
    func bestBaseline(_ metric: VehicleMetric, preferring context: BaselineContext) -> MetricBaseline? {
        if let specific = baseline(metric, context), specific.isEstablished { return specific }
        return baseline(metric, .any)
    }

    func value(_ metric: VehicleMetric, freshWithin interval: TimeInterval = 30) -> Double? {
        telemetry?.value(metric, freshWithin: interval, now: now)
    }
}

/// A rule turns context into zero or more insights. Pure, so each one is a unit test.
protocol InsightRule: Sendable {
    var identifier: String { get }
    func evaluate(_ context: InsightContext) -> [DriveInsight]
}
