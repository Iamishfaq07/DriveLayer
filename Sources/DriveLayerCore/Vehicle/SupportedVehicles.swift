import Foundation

/// Which vehicles DriveLayer currently offers a driver.
///
/// The profile catalog is built for many cars and every part of the intelligence
/// layer reads its vehicle through `VehicleProfile` — that is what let the reference
/// car change engine without Diesel Guardian or the copilot needing a line changed.
/// None of that is undone here.
///
/// What is scoped is the *product*: DriveLayer is deliberately a one-car app for now,
/// because one car is all anything has been checked against. Offering a picker of
/// profiles that have never met the vehicles they claim to describe would be exactly
/// the impressive-looking emptiness this project avoids.
///
/// Widening the list below is the whole change when other cars are ready. Nothing
/// else in the app decides how many vehicles exist — the views ask here.
enum SupportedVehicles {

    /// The profiles a driver may choose from, in the order they should appear.
    ///
    /// The generic profiles stay in the catalog: they are what a second car will be
    /// built on, and the diesel one is the fixture the Diesel Guardian tests need.
    /// They are simply not offered yet.
    static let offeredProfileIDs: [String] = [
        VehicleProfileCatalog.harrier2026AdventureXPlusID
    ]

    static var offered: [VehicleProfile] {
        offeredProfileIDs.compactMap { VehicleProfileCatalog.profile(id: $0) }
    }

    /// True while DriveLayer is a one-car app, which is what hides the pickers.
    static var isSingleVehicle: Bool { offeredProfileIDs.count == 1 }

    /// The only vehicle, when there is only one. `nil` once the list grows, so a
    /// caller cannot silently keep treating a multi-car app as single-car.
    static var only: VehicleProfile? {
        isSingleVehicle ? offered.first : nil
    }

    /// The profile a new vehicle starts on.
    static var defaultProfileID: String {
        offeredProfileIDs.first ?? VehicleProfileCatalog.genericPetrolID
    }
}
