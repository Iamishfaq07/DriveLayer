import Foundation

/// A car in the driver's garage. Distinct from `VehicleProfile`, which describes the
/// *model*: two people with the same Harrier share a profile but never share a Vehicle.
///
/// Registration number and VIN are sensitive. They are stored with file protection,
/// never logged in full, and never sent anywhere by DriveLayer.
struct Vehicle: Codable, Sendable, Equatable, Identifiable {
    var id: UUID
    var nickname: String
    var profileID: String
    var modelYear: Int?
    var registrationNumber: String?
    var vin: String?
    var colour: String?
    var odometerKm: Double?
    var odometerUpdatedAt: Date?
    /// Overrides the profile's tank capacity when the driver knows better.
    var tankCapacityOverrideLitres: Double?
    var purchaseDate: Date?
    var createdAt: Date
    var isPrimary: Bool

    init(id: UUID = UUID(),
         nickname: String,
         profileID: String,
         modelYear: Int? = nil,
         registrationNumber: String? = nil,
         vin: String? = nil,
         colour: String? = nil,
         odometerKm: Double? = nil,
         odometerUpdatedAt: Date? = nil,
         tankCapacityOverrideLitres: Double? = nil,
         purchaseDate: Date? = nil,
         createdAt: Date = Date(),
         isPrimary: Bool = false) {
        self.id = id
        self.nickname = nickname
        self.profileID = profileID
        self.modelYear = modelYear
        self.registrationNumber = registrationNumber
        self.vin = vin
        self.colour = colour
        self.odometerKm = odometerKm
        self.odometerUpdatedAt = odometerUpdatedAt
        self.tankCapacityOverrideLitres = tankCapacityOverrideLitres
        self.purchaseDate = purchaseDate
        self.createdAt = createdAt
        self.isPrimary = isPrimary
    }

    /// Effective tank size: the driver's value wins over the profile's.
    func tankCapacityLitres(profile: VehicleProfile?) -> Double? {
        if let tankCapacityOverrideLitres, tankCapacityOverrideLitres > 0 {
            return tankCapacityOverrideLitres
        }
        return profile?.tankCapacityLitres
    }

    func tankCapacitySource(profile: VehicleProfile?) -> SpecSource? {
        if let tankCapacityOverrideLitres, tankCapacityOverrideLitres > 0 { return .userProvided }
        return profile?.tankCapacitySource
    }

    /// Safe for logs and analytics.
    var redactedDescription: String {
        "Vehicle(\(profileID), id: \(PrivacyLog.redactedIdentifier(id.uuidString)))"
    }
}
