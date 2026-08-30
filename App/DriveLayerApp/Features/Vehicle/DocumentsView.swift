import SwiftUI

/// The digital glovebox.
///
/// Documents live in the app's own protected container and never leave the device.
/// Nothing here syncs, uploads, or is readable while the phone is locked.
struct DocumentsView: View {

    @Environment(AppEnvironment.self) private var environment
    @State private var documents: [DocumentRecord] = []
    @State private var isAdding = false

    private var formatter: DisplayFormatter { environment.formatter }

    var body: some View {
        List {
            if documents.isEmpty {
                Section {
                    DLEmptyState(symbol: "folder",
                                 title: "Glovebox is empty",
                                 message: "Keep your registration, insurance and PUC here so they're with you when you need them. They stay on this device.",
                                 actionTitle: "Add a document") { isAdding = true }
                        .listRowBackground(Color.clear)
                }
            } else {
                expiringSection
                Section("All documents") {
                    ForEach(documents) { document in
                        DocumentRow(document: document, formatter: formatter)
                    }
                    .onDelete { offsets in
                        for index in offsets { environment.store.delete(documentID: documents[index].id) }
                        reload()
                    }
                }
            }
            Section {
                Text("Documents are stored with full file protection and are not uploaded anywhere. Reference numbers are never written to logs.")
                    .font(DL.Font.caption)
                    .foregroundStyle(DLColor.secondaryText)
            }
        }
        .navigationTitle("Glovebox")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { isAdding = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $isAdding) {
            AddDocumentView { document in
                environment.store.add(document: document)
                reload()
                environment.drive.refreshAnalysis(force: true)
            }
        }
        .task { reload() }
    }

    @ViewBuilder
    private var expiringSection: some View {
        let expiring = documents.filter { $0.status(now: Date()) >= .watch }
        if !expiring.isEmpty {
            Section("Needs attention") {
                ForEach(expiring) { document in
                    DocumentRow(document: document, formatter: formatter)
                }
            }
        }
    }

    private func reload() {
        documents = environment.store.documents(vehicleID: environment.selectedVehicle?.id)
    }
}

private struct DocumentRow: View {
    let document: DocumentRecord
    let formatter: DisplayFormatter

    var body: some View {
        HStack(alignment: .top, spacing: DL.Spacing.small) {
            Image(systemName: document.kind.symbolName)
                .foregroundStyle(DLColor.secondaryText)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(document.title)
                    .font(DL.Font.body.weight(.medium))
                if let expiry = document.expiryDate {
                    Text("Expires \(formatter.mediumDate(expiry) ?? "")")
                        .font(DL.Font.caption)
                        .foregroundStyle(DLColor.secondaryText)
                } else if document.kind.expires {
                    Text("No expiry recorded")
                        .font(DL.Font.caption)
                        .foregroundStyle(DLColor.unknown)
                }
                if document.wasExtractedAutomatically {
                    Text("Read from the scan — worth checking")
                        .font(DL.Font.caption)
                        .foregroundStyle(DLColor.watch)
                }
            }
            Spacer()
            if document.kind.expires {
                StatusIndicator(status: document.status(now: Date()), showsLabel: false, size: 15)
            }
        }
    }
}

struct AddDocumentView: View {

    let onSave: (DocumentRecord) -> Void

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var kind: DocumentKind = .insurance
    @State private var title = ""
    @State private var provider = ""
    @State private var referenceNumber = ""
    @State private var hasExpiry = true
    @State private var expiryDate = Date().addingTimeInterval(365 * 86_400)

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $kind) {
                        ForEach(DocumentKind.allCases, id: \.self) { candidate in
                            Text(candidate.displayName).tag(candidate)
                        }
                    }
                    TextField("Title", text: $title)
                    TextField("Provider (optional)", text: $provider)
                    TextField("Reference number (optional)", text: $referenceNumber)
                }
                if kind.expires {
                    Section {
                        Toggle("Has an expiry date", isOn: $hasExpiry)
                        if hasExpiry {
                            DatePicker("Expires", selection: $expiryDate, displayedComponents: [.date])
                        }
                    }
                }
                Section {
                    Text("Scanning a document with the camera will fill these in automatically in a later version. Until then DriveLayer asks rather than guesses.")
                        .font(DL.Font.caption)
                        .foregroundStyle(DLColor.secondaryText)
                }
            }
            .navigationTitle("Add document")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(DocumentRecord(vehicleID: environment.selectedVehicle?.id,
                                              kind: kind,
                                              title: title.isEmpty ? kind.displayName : title,
                                              provider: provider.isEmpty ? nil : provider,
                                              referenceNumber: referenceNumber.isEmpty ? nil : referenceNumber,
                                              expiryDate: (kind.expires && hasExpiry) ? expiryDate : nil))
                        dismiss()
                    }
                }
            }
        }
    }
}
