import SwiftUI

struct GarageView: View {

    @Environment(AppEnvironment.self) private var environment
    @State private var isAddingVehicle = false

    private var formatter: DisplayFormatter { environment.formatter }

    /// DriveLayer supports one car for now, and the driver has it.
    private var isSingleCar: Bool {
        SupportedVehicles.isSingleVehicle && environment.vehicles.count <= 1
    }

    private var footerText: String {
        isSingleCar
            ? "DriveLayer is set up for one car at the moment. Everything it learns — drives, baselines, fuel, maintenance and documents — belongs to this vehicle, and support for more cars is coming."
            : "Each vehicle keeps its own drives, baselines, fuel log, maintenance and documents. Switching cars never mixes one car's history into another's."
    }

    var body: some View {
        List {
            // With one supported car there is nothing to switch between, so the list
            // of vehicles only appears once there is more than one.
            if !isSingleCar {
                Section("Your vehicles") {
                    ForEach(environment.vehicles) { vehicle in
                        Button {
                            environment.select(vehicleID: vehicle.id)
                        } label: {
                            VehicleRow(vehicle: vehicle,
                                       isSelected: vehicle.id == environment.selectedVehicleID,
                                       formatter: formatter)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if let vehicle = environment.selectedVehicle {
                Section(isSingleCar ? "Your vehicle" : "Selected vehicle") {
                    if isSingleCar {
                        VehicleRow(vehicle: vehicle, isSelected: false, formatter: formatter)
                    }
                    NavigationLink(destination: EditVehicleView(vehicle: vehicle)) {
                        Label("Edit details", systemImage: "pencil")
                    }
                }
            }
            // Offered when there is no car to work with — deleting the only vehicle
            // must not leave the app with no way back — and whenever more than one
            // vehicle is supported.
            if environment.vehicles.isEmpty || !isSingleCar {
                Section {
                    Button {
                        isAddingVehicle = true
                    } label: {
                        Label("Add a vehicle", systemImage: "plus")
                    }
                }
            }
            Section {
                Text(footerText)
                    .font(DL.Font.caption)
                    .foregroundStyle(DLColor.secondaryText)
            }
        }
        .navigationTitle("Garage")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isAddingVehicle) {
            AddVehicleView { vehicle in
                environment.add(vehicle: vehicle)
            }
        }
    }
}

private struct VehicleRow: View {
    let vehicle: Vehicle
    let isSelected: Bool
    let formatter: DisplayFormatter

    private var profile: VehicleProfile? { VehicleProfileCatalog.profile(id: vehicle.profileID) }

    var body: some View {
        HStack(spacing: DL.Spacing.medium) {
            Image(systemName: "car.side")
                .font(.system(size: 20))
                .foregroundStyle(isSelected ? DLColor.accent : DLColor.secondaryText)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(vehicle.nickname)
                    .font(DL.Font.body.weight(.medium))
                    .foregroundStyle(DLColor.primaryText)
                Text([profile?.displayName,
                      vehicle.modelYear.map(String.init),
                      profile?.validationTier.label]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(DL.Font.caption)
                    .foregroundStyle(DLColor.secondaryText)
                if let odometer = vehicle.odometerKm {
                    Text("\(formatter.distance(kilometres: odometer, fractionDigits: 0) ?? "") \(formatter.distanceUnitLabel)")
                        .font(DL.Font.caption.monospacedDigit())
                        .foregroundStyle(DLColor.unknown)
                }
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(DLColor.accent)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Vehicle creation.
///
/// A profile is chosen, not detected: VIN decoding needs a service DriveLayer does
/// not have, and guessing a model from an adapter would be worse than asking.
struct AddVehicleView: View {

    let onSave: (Vehicle) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var nickname = ""
    @State private var profileID = SupportedVehicles.defaultProfileID
    @State private var modelYear = ""
    @State private var registration = ""
    @State private var odometer = ""
    @State private var tankOverride = ""

    private var profile: VehicleProfile? { VehicleProfileCatalog.profile(id: profileID) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Vehicle") {
                    TextField("Name it", text: $nickname)
                    if let only = SupportedVehicles.only {
                        HStack {
                            Text("Vehicle")
                            Spacer()
                            Text(only.displayName)
                                .foregroundStyle(DLColor.secondaryText)
                        }
                    } else {
                        Picker("Profile", selection: $profileID) {
                            ForEach(SupportedVehicles.offered) { candidate in
                                Text(candidate.displayName).tag(candidate.id)
                            }
                        }
                    }
                    TextField("Model year", text: $modelYear)
                        .keyboardType(.numberPad)
                }

                if let profile {
                    Section("What this profile gives you") {
                        HStack {
                            Text("Validation")
                            Spacer()
                            Text(profile.validationTier.label)
                                .foregroundStyle(DLColor.secondaryText)
                        }
                        Text(profile.validationTier.explanation)
                            .font(DL.Font.caption)
                            .foregroundStyle(DLColor.secondaryText)
                        ForEach(profile.notes, id: \.self) { note in
                            Text(note)
                                .font(DL.Font.caption)
                                .foregroundStyle(DLColor.secondaryText)
                        }
                    }
                }

                Section("Details") {
                    TextField("Odometer (km)", text: $odometer)
                        .keyboardType(.numberPad)
                    TextField("Tank capacity override (L)", text: $tankOverride)
                        .keyboardType(.decimalPad)
                    TextField("Registration (optional)", text: $registration)
                        .textInputAutocapitalization(.characters)
                }

                Section {
                    Text("Registration stays on this device, is never logged, and is never sent anywhere.")
                        .font(DL.Font.caption)
                        .foregroundStyle(DLColor.secondaryText)
                }
            }
            .navigationTitle("Add vehicle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { save() }.disabled(nickname.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func save() {
        let vehicle = Vehicle(nickname: nickname.trimmingCharacters(in: .whitespaces),
                              profileID: profileID,
                              modelYear: Int(modelYear),
                              registrationNumber: registration.isEmpty ? nil : registration,
                              odometerKm: Double(odometer),
                              odometerUpdatedAt: Double(odometer) == nil ? nil : Date(),
                              tankCapacityOverrideLitres: Double(tankOverride.replacingOccurrences(of: ",", with: ".")),
                              isPrimary: true)
        onSave(vehicle)
        dismiss()
    }
}

struct EditVehicleView: View {

    @State var vehicle: Vehicle
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var odometer = ""
    @State private var tankOverride = ""
    @State private var isConfirmingDelete = false

    private var profile: VehicleProfile? {
        VehicleProfileCatalog.profile(id: vehicle.profileID)
    }

    var body: some View {
        Form {
            Section("Vehicle") {
                TextField("Name", text: $vehicle.nickname)
                TextField("Odometer (km)", text: $odometer)
                    .keyboardType(.numberPad)
            }
            tankSection
            Section {
                Button(role: .destructive) {
                    isConfirmingDelete = true
                } label: {
                    Label("Delete this vehicle and its data", systemImage: "trash")
                }
            } footer: {
                Text("This removes every drive, baseline, fuel entry, maintenance item and document belonging to this vehicle. It cannot be undone.")
            }
        }
        .navigationTitle(vehicle.nickname)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    vehicle.odometerKm = Double(odometer) ?? vehicle.odometerKm
                    vehicle.odometerUpdatedAt = Date()
                    // An emptied field clears the override, so a driver who mistyped
                    // can get back to the profile's own figure rather than being
                    // stuck with a number they cannot remove.
                    vehicle.tankCapacityOverrideLitres = Double(tankOverride.replacingOccurrences(of: ",", with: "."))
                    environment.store.update(vehicle: vehicle)
                    environment.reloadVehicles()
                    dismiss()
                }
            }
        }
        .onAppear {
            odometer = vehicle.odometerKm.map { String(Int($0)) } ?? ""
            tankOverride = vehicle.tankCapacityOverrideLitres.map { String(format: "%g", $0) } ?? ""
        }
        .confirmationDialog("Delete this vehicle?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button("Delete everything", role: .destructive) {
                environment.deleteSelectedVehicle()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// Tank capacity, its source, and a way to correct it.
    ///
    /// This is the number range estimation multiplies the fuel level by, so it is the
    /// one specification where a wrong value turns into a confident wrong distance.
    /// It was previously settable only when adding a vehicle, which left a driver who
    /// checked their manual afterwards with no way to fix it.
    private var tankSection: some View {
        Section {
            ValueOrReasonRow(label: "Capacity",
                             value: vehicle.tankCapacityLitres(profile: profile).map { String(format: "%g", $0) },
                             unit: "L",
                             reason: "Not recorded")
            ValueOrReasonRow(label: "Source",
                             value: vehicle.tankCapacitySource(profile: profile)?.label,
                             reason: "No profile")
            TextField("Override (litres)", text: $tankOverride)
                .keyboardType(.decimalPad)
        } header: {
            Text("Fuel tank")
        } footer: {
            Text(tankFooter)
        }
    }

    private var tankFooter: String {
        let base = "Range is estimated from this and your fuel level, so a wrong figure becomes a wrong distance. Leave the override empty to use the profile's own value."
        // No profile means no figure to describe the provenance of, so the warning
        // about generic defaults would be describing nothing.
        guard let source = vehicle.tankCapacitySource(profile: profile) else { return base }
        return source.isVehicleSpecific
            ? base
            : "This is a generic default, not a published figure for your exact vehicle. " + base
    }
}
