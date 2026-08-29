import Foundation

enum MaintenanceKind: String, Codable, CaseIterable, Sendable {
    case periodicService, engineOil, oilFilter, airFilter, fuelFilter, cabinFilter
    case brakePads, brakeFluid, coolant, transmissionFluid
    case tyreRotation, wheelAlignment, wheelBalancing, tyreReplacement
    case battery, wipers, other

    var displayName: String {
        switch self {
        case .periodicService: return "Periodic service"
        case .engineOil: return "Engine oil"
        case .oilFilter: return "Oil filter"
        case .airFilter: return "Air filter"
        case .fuelFilter: return "Fuel filter"
        case .cabinFilter: return "Cabin filter"
        case .brakePads: return "Brake pads"
        case .brakeFluid: return "Brake fluid"
        case .coolant: return "Coolant"
        case .transmissionFluid: return "Transmission fluid"
        case .tyreRotation: return "Tyre rotation"
        case .wheelAlignment: return "Wheel alignment"
        case .wheelBalancing: return "Wheel balancing"
        case .tyreReplacement: return "Tyre replacement"
        case .battery: return "Battery"
        case .wipers: return "Wipers"
        case .other: return "Other"
        }
    }

    var symbolName: String {
        switch self {
        case .periodicService: return "wrench.and.screwdriver"
        case .engineOil, .oilFilter: return "drop"
        case .airFilter, .cabinFilter: return "wind"
        case .fuelFilter: return "fuelpump"
        case .brakePads, .brakeFluid: return "exclamationmark.brakesignal"
        case .coolant: return "thermometer"
        case .transmissionFluid: return "gearshape.2"
        case .tyreRotation, .wheelAlignment, .wheelBalancing, .tyreReplacement: return "circle.circle"
        case .battery: return "minus.plus.batteryblock"
        case .wipers: return "cloud.rain"
        case .other: return "checklist"
        }
    }
}

/// A recurring maintenance obligation. Due by distance, by time, or by whichever
/// comes first — which is how manufacturers actually specify them.
struct MaintenanceItem: Codable, Sendable, Equatable, Identifiable {
    var id: UUID
    var vehicleID: UUID
    var kind: MaintenanceKind
    var name: String
    var intervalDistanceKm: Double?
    var intervalMonths: Int?
    var lastDoneDate: Date?
    var lastDoneOdometerKm: Double?
    var isEnabled: Bool
    var source: SpecSource
    var note: String?

    init(id: UUID = UUID(),
         vehicleID: UUID,
         kind: MaintenanceKind,
         name: String? = nil,
         intervalDistanceKm: Double? = nil,
         intervalMonths: Int? = nil,
         lastDoneDate: Date? = nil,
         lastDoneOdometerKm: Double? = nil,
         isEnabled: Bool = true,
         source: SpecSource = .userProvided,
         note: String? = nil) {
        self.id = id
        self.vehicleID = vehicleID
        self.kind = kind
        self.name = name ?? kind.displayName
        self.intervalDistanceKm = intervalDistanceKm
        self.intervalMonths = intervalMonths
        self.lastDoneDate = lastDoneDate
        self.lastDoneOdometerKm = lastDoneOdometerKm
        self.isEnabled = isEnabled
        self.source = source
        self.note = note
    }

    /// An item with no interval and no history cannot be due for anything.
    var isTrackable: Bool {
        (intervalDistanceKm != nil && lastDoneOdometerKm != nil) || (intervalMonths != nil && lastDoneDate != nil)
    }
}

struct ServiceRecord: Codable, Sendable, Equatable, Identifiable {
    var id: UUID
    var vehicleID: UUID
    var date: Date
    var odometerKm: Double?
    var title: String
    var workshop: String?
    var cost: Double?
    var currencyCode: String?
    var itemsServiced: [MaintenanceKind]
    var invoiceDocumentID: UUID?
    var note: String?

    init(id: UUID = UUID(),
         vehicleID: UUID,
         date: Date,
         odometerKm: Double? = nil,
         title: String,
         workshop: String? = nil,
         cost: Double? = nil,
         currencyCode: String? = nil,
         itemsServiced: [MaintenanceKind] = [],
         invoiceDocumentID: UUID? = nil,
         note: String? = nil) {
        self.id = id
        self.vehicleID = vehicleID
        self.date = date
        self.odometerKm = odometerKm
        self.title = title
        self.workshop = workshop
        self.cost = cost
        self.currencyCode = currencyCode
        self.itemsServiced = itemsServiced
        self.invoiceDocumentID = invoiceDocumentID
        self.note = note
    }
}

enum ExpenseCategory: String, Codable, CaseIterable, Sendable {
    case fuel, service, repair, tyres, insurance, tax, parking, toll, fine, accessory, other

    var displayName: String {
        switch self {
        case .fuel: return "Fuel"
        case .service: return "Service"
        case .repair: return "Repair"
        case .tyres: return "Tyres"
        case .insurance: return "Insurance"
        case .tax: return "Tax"
        case .parking: return "Parking"
        case .toll: return "Toll"
        case .fine: return "Fine"
        case .accessory: return "Accessory"
        case .other: return "Other"
        }
    }
}

struct VehicleExpense: Codable, Sendable, Equatable, Identifiable {
    var id: UUID
    var vehicleID: UUID
    var date: Date
    var category: ExpenseCategory
    var amount: Double
    var currencyCode: String
    var note: String?
    var odometerKm: Double?

    init(id: UUID = UUID(),
         vehicleID: UUID,
         date: Date,
         category: ExpenseCategory,
         amount: Double,
         currencyCode: String,
         note: String? = nil,
         odometerKm: Double? = nil) {
        self.id = id
        self.vehicleID = vehicleID
        self.date = date
        self.category = category
        self.amount = amount
        self.currencyCode = currencyCode
        self.note = note
        self.odometerKm = odometerKm
    }
}

struct TyreRecord: Codable, Sendable, Equatable, Identifiable {
    enum Position: String, Codable, CaseIterable, Sendable {
        case frontLeft, frontRight, rearLeft, rearRight, spare, allFour
    }

    var id: UUID
    var vehicleID: UUID
    var fittedDate: Date
    var fittedOdometerKm: Double?
    var brand: String?
    var sizeDescription: String?
    var positions: [Position]
    var recommendedPressureFrontPsi: Double?
    var recommendedPressureRearPsi: Double?
    var invoiceDocumentID: UUID?
    var note: String?

    init(id: UUID = UUID(),
         vehicleID: UUID,
         fittedDate: Date,
         fittedOdometerKm: Double? = nil,
         brand: String? = nil,
         sizeDescription: String? = nil,
         positions: [Position] = [.allFour],
         recommendedPressureFrontPsi: Double? = nil,
         recommendedPressureRearPsi: Double? = nil,
         invoiceDocumentID: UUID? = nil,
         note: String? = nil) {
        self.id = id
        self.vehicleID = vehicleID
        self.fittedDate = fittedDate
        self.fittedOdometerKm = fittedOdometerKm
        self.brand = brand
        self.sizeDescription = sizeDescription
        self.positions = positions
        self.recommendedPressureFrontPsi = recommendedPressureFrontPsi
        self.recommendedPressureRearPsi = recommendedPressureRearPsi
        self.invoiceDocumentID = invoiceDocumentID
        self.note = note
    }
}

struct BatteryRecord: Codable, Sendable, Equatable, Identifiable {
    var id: UUID
    var vehicleID: UUID
    var fittedDate: Date
    var fittedOdometerKm: Double?
    var brand: String?
    var capacityAmpHours: Double?
    var warrantyMonths: Int?
    var note: String?

    init(id: UUID = UUID(),
         vehicleID: UUID,
         fittedDate: Date,
         fittedOdometerKm: Double? = nil,
         brand: String? = nil,
         capacityAmpHours: Double? = nil,
         warrantyMonths: Int? = nil,
         note: String? = nil) {
        self.id = id
        self.vehicleID = vehicleID
        self.fittedDate = fittedDate
        self.fittedOdometerKm = fittedOdometerKm
        self.brand = brand
        self.capacityAmpHours = capacityAmpHours
        self.warrantyMonths = warrantyMonths
        self.note = note
    }

    func ageInMonths(now: Date, calendar: Calendar = .current) -> Int? {
        calendar.dateComponents([.month], from: fittedDate, to: now).month
    }

    /// Remaining warranty in months, or `nil` when no warranty was recorded.
    func warrantyRemainingMonths(now: Date, calendar: Calendar = .current) -> Int? {
        guard let warrantyMonths, let age = ageInMonths(now: now, calendar: calendar) else { return nil }
        return warrantyMonths - age
    }
}
