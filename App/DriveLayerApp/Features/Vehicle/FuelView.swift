import SwiftUI
import Charts

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
            costSection
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
            DLAdaptiveRow {
                MetricView(label: "Level",
                           value: formatter.percent(status.levelPercent.value),
                           unit: "%",
                           provenance: status.levelPercent.provenance)
                    .frame(maxWidth: .infinity, alignment: .leading)
                MetricView(label: "Range",
                           value: formatter.distance(kilometres: status.estimatedRangeKm.value, fractionDigits: 0),
                           unit: formatter.distanceUnitLabel,
                           provenance: status.estimatedRangeKm.provenance)
                    .frame(maxWidth: .infinity, alignment: .leading)
                MetricView(label: "Typical economy",
                           value: formatter.economy(kmPerLitre: status.economyKmPerLitre),
                           unit: formatter.economyUnitLabel,
                           provenance: .estimated)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, DL.Spacing.tight)

            if let basis = status.estimatedRangeKm.basis {
                Text(basis)
                    .font(DL.Font.caption)
                    .foregroundStyle(DLColor.secondaryText)
            }
        }
    }

    /// Economy as a chart rather than a sparkline.
    ///
    /// A sparkline says "roughly this shape". With a date axis and a line for the
    /// usual figure, the same data answers the question a driver actually has — is
    /// this tank worse than my normal, or is my normal just this — which a shape
    /// without a scale cannot.
    ///
    /// Every point is a full-to-full measurement. Partial fills are recorded for cost
    /// and excluded here, so nothing on this chart is interpolated.
    private var trendSection: some View {
        Section("Economy over time") {
            VStack(alignment: .leading, spacing: DL.Spacing.small) {
                if economyResults.count >= 2 {
                    economyChart
                } else {
                    // One interval is a dot, not a trend. Say so rather than drawing a
                    // line between a single point and nothing.
                    Text("One full-to-full interval so far. A second one gives this a trend.")
                        .font(DL.Font.caption)
                        .foregroundStyle(DLColor.secondaryText)
                }
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

    private var economyChart: some View {
        let points = economyResults.compactMap { result -> (date: Date, value: Double)? in
            guard let converted = formatter.economyUnit.value(fromKilometresPerLitre: result.kilometresPerLitre) else {
                return nil
            }
            return (result.toDate, converted)
        }
        // The median rather than the mean: one bad tank should move the "usual" line
        // hardly at all, and with a handful of intervals a mean lets it move a lot.
        let sorted = points.map(\.value).sorted()
        let median: Double? = sorted.isEmpty ? nil
            : (sorted.count % 2 == 1 ? sorted[sorted.count / 2]
                                     : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2)

        return Chart {
            ForEach(points, id: \.date) { point in
                AreaMark(x: .value("Date", point.date), y: .value("Economy", point.value))
                    .foregroundStyle(LinearGradient(colors: [DLColor.accent.opacity(0.28), .clear],
                                                    startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Date", point.date), y: .value("Economy", point.value))
                    .foregroundStyle(DLColor.accent)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .symbol { Circle().fill(DLColor.accent).frame(width: 5, height: 5) }
            }
            if let median {
                RuleMark(y: .value("Usual", median))
                    .foregroundStyle(DLColor.unknown.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, alignment: .leading) {
                        Text("Usual")
                            .font(DL.Font.caption)
                            .foregroundStyle(DLColor.secondaryText)
                    }
            }
        }
        .chartYAxisLabel(formatter.economyUnitLabel)
        .frame(height: 150)
        .accessibilityLabel(Text("Economy over time, \(points.count) full-to-full intervals."))
    }

    /// What the car costs to run, from the fills already recorded.
    ///
    /// `costPerKilometre` was already being computed for every full-to-full interval
    /// and shown nowhere. Cost is the question owners actually ask about a car, and
    /// this answers it without a single new measurement — only fills that carry a
    /// price contribute, so a driver who logs litres but not money sees nothing here
    /// rather than a total quietly missing half its fills.
    @ViewBuilder
    private var costSection: some View {
        let priced = entries.filter { $0.totalCost != nil }
        let perKilometre = economyResults.compactMap(\.costPerKilometre)
        if !priced.isEmpty {
            let total = priced.compactMap(\.totalCost).reduce(0, +)
            let average = perKilometre.isEmpty ? nil : perKilometre.reduce(0, +) / Double(perKilometre.count)
            Section("Running cost") {
                DLAdaptiveRow {
                    MetricView(label: "Fuel recorded",
                               value: formatter.decimal(total),
                               provenance: .measured)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    MetricView(label: "Per \(formatter.distanceUnitLabel)",
                               value: average.flatMap { formatter.decimal(costPerDisplayDistance($0), fractionDigits: 2) },
                               provenance: .estimated)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, DL.Spacing.tight)

                Text(costCaption(pricedCount: priced.count, intervalCount: perKilometre.count))
                    .font(DL.Font.caption)
                    .foregroundStyle(DLColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Says what the totals are actually made of, including what they leave out — a
    /// spend figure quietly missing half the fills is worse than no figure.
    private func costCaption(pricedCount: Int, intervalCount: Int) -> String {
        var parts = ["From \(pricedCount) fill\(pricedCount == 1 ? "" : "s") with a price recorded."]
        if intervalCount > 0 {
            parts.append("Cost per \(formatter.distanceUnitLabel) is averaged over \(intervalCount) full-to-full interval\(intervalCount == 1 ? "" : "s").")
        }
        let unpriced = entries.count - pricedCount
        if unpriced > 0 {
            parts.append("\(unpriced) fill\(unpriced == 1 ? "" : "s") without a price \(unpriced == 1 ? "is" : "are") left out.")
        }
        return parts.joined(separator: " ")
    }

    /// Cost is computed per kilometre; a driver reading miles wants it per mile.
    private func costPerDisplayDistance(_ perKilometre: Double) -> Double {
        formatter.unitSystem == .metric ? perKilometre : perKilometre / 0.621_371
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
