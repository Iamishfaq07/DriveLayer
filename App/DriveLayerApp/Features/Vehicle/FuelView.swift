import SwiftUI

struct FuelView: View {

    @Environment(AppEnvironment.self) private var environment
    @State private var entries: [FuelEntry] = []
    @State private var isAddingEntry = false

    private var formatter: DisplayFormatter { environment.formatter }

    private var economyResults: [FuelEconomyResult] {
        FuelCalculations.economyResults(from: entries)
    }

    var body: some View {
        List {
            statusSection
            if !economyResults.isEmpty { trendSection }
            entriesSection
        }
        .navigationTitle("Fuel")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { isAddingEntry = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $isAddingEntry) {
            AddFuelEntryView { entry in
                environment.store.add(fuelEntry: entry)
                reload()
                environment.drive.refreshAnalysis(force: true)
            }
        }
        .task { reload() }
    }

    private var statusSection: some View {
        let status = environment.drive.fuelStatus
        return Section {
            HStack {
                MetricView(label: "Level",
                           value: formatter.percent(status.levelPercent.value),
                           unit: "%",
                           provenance: status.levelPercent.provenance)
                Spacer()
                MetricView(label: "Range",
                           value: formatter.distance(kilometres: status.estimatedRangeKm.value, fractionDigits: 0),
                           unit: formatter.distanceUnitLabel,
                           provenance: status.estimatedRangeKm.provenance)
                Spacer()
                MetricView(label: "Typical economy",
                           value: formatter.economy(kmPerLitre: status.economyKmPerLitre),
                           unit: formatter.economyUnitLabel,
                           provenance: .estimated)
            }
            .padding(.vertical, DL.Spacing.tight)

            if let basis = status.estimatedRangeKm.basis {
                Text(basis)
                    .font(DL.Font.caption)
                    .foregroundStyle(DLColor.secondaryText)
            }
        }
    }

    private var trendSection: some View {
        Section("Economy over time") {
            VStack(alignment: .leading, spacing: DL.Spacing.small) {
                Sparkline(values: Array(economyResults.map(\.kilometresPerLitre).reversed()))
                HStack {
                    Text("Full-to-full, \(economyResults.count) interval\(economyResults.count == 1 ? "" : "s")")
                        .font(DL.Font.caption)
                        .foregroundStyle(DLColor.secondaryText)
                    Spacer()
                    if let best = economyResults.map(\.kilometresPerLitre).max(),
                       let formatted = formatter.economy(kmPerLitre: best) {
                        Text("Best \(formatted) \(formatter.economyUnitLabel)")
                            .font(DL.Font.caption)
                            .foregroundStyle(DLColor.secondaryText)
                    }
                }
            }
            .padding(.vertical, DL.Spacing.tight)
        }
    }

    @ViewBuilder
    private var entriesSection: some View {
        if entries.isEmpty {
            Section {
                DLEmptyState(symbol: "fuelpump",
                             title: "No fill-ups yet",
                             message: "Add a fill-up with its odometer reading. Two full tanks are enough for DriveLayer to work out your real economy.",
                             actionTitle: "Add a fill-up") { isAddingEntry = true }
                    .listRowBackground(Color.clear)
            }
        } else {
            Section("Fill-ups") {
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(formatter.mediumDate(entry.date) ?? "")
                                .font(DL.Font.body.weight(.medium))
                            Spacer()
                            Text("\(formatter.volume(litres: entry.litres) ?? "—") \(formatter.volumeUnitLabel)")
                                .font(DL.Font.body.monospacedDigit())
                        }
                        HStack(spacing: DL.Spacing.small) {
                            if !entry.isFullTank {
                                Text("Partial")
                                    .font(DL.Font.caption)
                                    .foregroundStyle(DLColor.watch)
                            }
                            if let odometer = entry.odometerKm {
                                Text("\(formatter.distance(kilometres: odometer, fractionDigits: 0) ?? "") \(formatter.distanceUnitLabel)")
                                    .font(DL.Font.caption)
                                    .foregroundStyle(DLColor.secondaryText)
                            } else {
                                Text("No odometer — excluded from economy")
                                    .font(DL.Font.caption)
                                    .foregroundStyle(DLColor.unknown)
                            }
                            Spacer()
                            if let cost = entry.totalCost {
                                Text(cost.formatted(.number.precision(.fractionLength(0))))
                                    .font(DL.Font.caption.monospacedDigit())
                                    .foregroundStyle(DLColor.secondaryText)
                            }
                        }
                    }
                }
                .onDelete { offsets in
                    for index in offsets { environment.store.delete(fuelEntryID: entries[index].id) }
                    reload()
                }
            }
        }
    }

    private func reload() {
        guard let vehicle = environment.selectedVehicle else { return }
        entries = environment.store.fuelEntries(vehicleID: vehicle.id)
    }
}

struct AddFuelEntryView: View {

    let onSave: (FuelEntry) -> Void

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var date = Date()
    @State private var litres = ""
    @State private var pricePerLitre = ""
    @State private var odometer = ""
    @State private var isFullTank = true
    @State private var station = ""

    private var parsedLitres: Double? { Double(litres.replacingOccurrences(of: ",", with: ".")) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Date", selection: $date, displayedComponents: [.date])
                    TextField("Litres", text: $litres)
                        .keyboardType(.decimalPad)
                    TextField("Price per litre", text: $pricePerLitre)
                        .keyboardType(.decimalPad)
                    TextField("Odometer (km)", text: $odometer)
                        .keyboardType(.numberPad)
                    Toggle("Filled the tank", isOn: $isFullTank)
                    TextField("Station (optional)", text: $station)
                }
                Section {
                    Text("Economy is only calculated between two full tanks with odometer readings. Partial fills still count towards cost.")
                        .font(DL.Font.caption)
                        .foregroundStyle(DLColor.secondaryText)
                }
            }
            .navigationTitle("Add fill-up")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(parsedLitres == nil || (parsedLitres ?? 0) <= 0)
                }
            }
        }
    }

    private func save() {
        guard let vehicle = environment.selectedVehicle, let litresValue = parsedLitres else { return }
        let entry = FuelEntry(vehicleID: vehicle.id,
                              date: date,
                              litres: litresValue,
                              pricePerLitre: Double(pricePerLitre.replacingOccurrences(of: ",", with: ".")),
                              odometerKm: Double(odometer),
                              isFullTank: isFullTank,
                              stationName: station.isEmpty ? nil : station)
        onSave(entry)
        dismiss()
    }
}
