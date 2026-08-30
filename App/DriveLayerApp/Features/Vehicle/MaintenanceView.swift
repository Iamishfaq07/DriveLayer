import SwiftUI

struct MaintenanceView: View {

    @Environment(AppEnvironment.self) private var environment
    @State private var statuses: [MaintenanceDueStatus] = []
    @State private var records: [ServiceRecord] = []
    @State private var editingItem: MaintenanceItem?

    private var formatter: DisplayFormatter { environment.formatter }

    var body: some View {
        List {
            odometerSection
            dueSection
            historySection
        }
        .navigationTitle("Maintenance")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editingItem) { item in
            EditMaintenanceItemView(item: item) { updated in
                environment.store.save(maintenanceItem: updated)
                reload()
                environment.drive.refreshAnalysis(force: true)
            }
        }
        .task { reload() }
    }

    @ViewBuilder
    private var odometerSection: some View {
        if let vehicle = environment.selectedVehicle {
            Section("Odometer") {
                if let odometer = vehicle.odometerKm {
                    HStack {
                        Text("Current reading")
                        Spacer()
                        Text("\(formatter.distance(kilometres: odometer, fractionDigits: 0) ?? "—") \(formatter.distanceUnitLabel)")
                            .font(DL.Font.body.monospacedDigit())
                            .foregroundStyle(DLColor.secondaryText)
                    }
                    if let updated = vehicle.odometerUpdatedAt {
                        Text("Updated \(formatter.relative(updated) ?? "recently"). DriveLayer adds each recorded drive to it.")
                            .font(DL.Font.caption)
                            .foregroundStyle(DLColor.secondaryText)
                    }
                } else {
                    Text("Add your odometer reading in the Garage so DriveLayer can work out what's due by distance.")
                        .font(DL.Font.callout)
                        .foregroundStyle(DLColor.secondaryText)
                }
            }
        }
    }

    @ViewBuilder
    private var dueSection: some View {
        if statuses.isEmpty {
            Section {
                DLEmptyState(symbol: "wrench.and.screwdriver",
                             title: "Nothing set up yet",
                             message: "Add a vehicle with a profile and DriveLayer will start with its service schedule.")
                    .listRowBackground(Color.clear)
            }
        } else {
            Section("Schedule") {
                ForEach(statuses) { status in
                    Button {
                        editingItem = status.item
                    } label: {
                        HStack(alignment: .top, spacing: DL.Spacing.small) {
                            Image(systemName: status.item.kind.symbolName)
                                .foregroundStyle(DLColor.secondaryText)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(status.item.name)
                                    .font(DL.Font.body.weight(.medium))
                                    .foregroundStyle(DLColor.primaryText)
                                Text(status.summary)
                                    .font(DL.Font.callout)
                                    .foregroundStyle(DLColor.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                                if status.item.source == .genericDefault {
                                    Text("Generic default — check your manual")
                                        .font(DL.Font.caption)
                                        .foregroundStyle(DLColor.watch)
                                }
                            }
                            Spacer()
                            StatusIndicator(status: status.status, showsLabel: false, size: 16)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var historySection: some View {
        Section("Service history") {
            if records.isEmpty {
                Text("No service records yet. Adding one sets the baseline for everything due by distance or date.")
                    .font(DL.Font.callout)
                    .foregroundStyle(DLColor.secondaryText)
            } else {
                ForEach(records) { record in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(record.title)
                            .font(DL.Font.body.weight(.medium))
                        HStack(spacing: DL.Spacing.small) {
                            Text(formatter.mediumDate(record.date) ?? "")
                            if let odometer = record.odometerKm {
                                Text("\(formatter.distance(kilometres: odometer, fractionDigits: 0) ?? "") \(formatter.distanceUnitLabel)")
                            }
                            if let workshop = record.workshop { Text(workshop) }
                        }
                        .font(DL.Font.caption)
                        .foregroundStyle(DLColor.secondaryText)
                    }
                }
            }
        }
    }

    private func reload() {
        guard let vehicle = environment.selectedVehicle else { return }
        statuses = MaintenanceEngine.statuses(for: environment.store.maintenanceItems(vehicleID: vehicle.id),
                                              currentOdometerKm: vehicle.odometerKm,
                                              now: Date())
        records = environment.store.serviceRecords(vehicleID: vehicle.id)
    }
}

struct EditMaintenanceItemView: View {

    @State var item: MaintenanceItem
    let onSave: (MaintenanceItem) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var lastDoneOdometer: String = ""
    @State private var intervalDistance: String = ""
    @State private var hasLastDoneDate = false
    @State private var lastDoneDate = Date()

    var body: some View {
        NavigationStack {
            Form {
                Section("Interval") {
                    TextField("Every (km)", text: $intervalDistance)
                        .keyboardType(.numberPad)
                    Stepper(item.intervalMonths.map { "Every \($0) months" } ?? "No time interval",
                            value: Binding(get: { item.intervalMonths ?? 0 },
                                           set: { item.intervalMonths = $0 == 0 ? nil : $0 }),
                            in: 0...60)
                }
                Section("Last done") {
                    TextField("Odometer (km)", text: $lastDoneOdometer)
                        .keyboardType(.numberPad)
                    Toggle("Record a date", isOn: $hasLastDoneDate)
                    if hasLastDoneDate {
                        DatePicker("Date", selection: $lastDoneDate, displayedComponents: [.date])
                    }
                }
                Section {
                    Toggle("Track this item", isOn: $item.isEnabled)
                    HStack {
                        Text("Interval source")
                        Spacer()
                        Text(item.source.label)
                            .font(DL.Font.caption)
                            .foregroundStyle(DLColor.secondaryText)
                    }
                    if let note = item.note {
                        Text(note)
                            .font(DL.Font.caption)
                            .foregroundStyle(DLColor.secondaryText)
                    }
                }
            }
            .navigationTitle(item.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } }
            }
            .onAppear {
                intervalDistance = item.intervalDistanceKm.map { String(Int($0)) } ?? ""
                lastDoneOdometer = item.lastDoneOdometerKm.map { String(Int($0)) } ?? ""
                hasLastDoneDate = item.lastDoneDate != nil
                lastDoneDate = item.lastDoneDate ?? Date()
            }
        }
    }

    private func save() {
        var updated = item
        updated.intervalDistanceKm = Double(intervalDistance)
        updated.lastDoneOdometerKm = Double(lastDoneOdometer)
        updated.lastDoneDate = hasLastDoneDate ? lastDoneDate : nil
        // A value the driver typed is theirs, not the profile's.
        if updated.intervalDistanceKm != item.intervalDistanceKm || updated.intervalMonths != item.intervalMonths {
            updated.source = .userProvided
        }
        onSave(updated)
        dismiss()
    }
}
