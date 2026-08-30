import SwiftUI
import UIKit

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
                        NavigationLink(destination: DocumentDetailView(document: document)) {
                            DocumentRow(document: document, formatter: formatter)
                        }
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
                    NavigationLink(destination: DocumentDetailView(document: document)) {
                        DocumentRow(document: document, formatter: formatter)
                    }
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

    /// Generated up front so the scanned image can be filed under it before save.
    @State private var documentID = UUID()
    @State private var kind: DocumentKind = .insurance
    @State private var title = ""
    @State private var provider = ""
    @State private var referenceNumber = ""
    @State private var hasExpiry = true
    @State private var expiryDate = Date().addingTimeInterval(365 * 86_400)
    @State private var issueDate: Date?

    @State private var isScanning = false
    @State private var storedFileName: String?
    @State private var wasExtractedAutomatically = false
    @State private var scanSummary: String?

    var body: some View {
        NavigationStack {
            Form {
                scanSection
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
                    Text("Scans and their text are processed entirely on this device and stored with full file protection. Nothing is uploaded.")
                        .font(DL.Font.caption)
                        .foregroundStyle(DLColor.secondaryText)
                }
            }
            .navigationTitle("Add document")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { cancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
            .fullScreenCover(isPresented: $isScanning) {
                DocumentScannerView(onComplete: apply, onCancel: { isScanning = false })
                    .ignoresSafeArea()
            }
        }
    }

    @ViewBuilder
    private var scanSection: some View {
        Section {
            if DocumentScannerView.isSupported {
                Button {
                    isScanning = true
                } label: {
                    Label(storedFileName == nil ? "Scan document" : "Rescan document",
                          systemImage: "doc.viewfinder")
                }
            } else {
                Text("This device can't scan documents. You can still type the details in.")
                    .font(DL.Font.callout)
                    .foregroundStyle(DLColor.secondaryText)
            }
            if let scanSummary {
                Text(scanSummary)
                    .font(DL.Font.caption)
                    .foregroundStyle(wasExtractedAutomatically ? DLColor.watch : DLColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Scan")
        } footer: {
            Text("Scanning fills these fields in from the page. Check them before saving — text recognition is a suggestion, not a reading.")
        }
    }

    /// Applies what the scanner read, without overwriting anything already typed.
    private func apply(_ result: DocumentScannerView.ScanResult) {
        isScanning = false
        let extraction = result.extraction

        if let imageData = result.imageData {
            storedFileName = DocumentFileStore.shared.store(data: imageData,
                                                            documentID: documentID,
                                                            fileExtension: "jpg")
        }

        if let suggested = extraction.suggestedKind { kind = suggested }
        if referenceNumber.isEmpty, let reference = extraction.referenceNumber {
            referenceNumber = reference
        }
        if let expiry = extraction.expiryDate {
            expiryDate = expiry
            hasExpiry = true
        }
        issueDate = extraction.issueDate
        wasExtractedAutomatically = extraction.confidence > 0

        if result.extraction.recognisedLineCount == 0 {
            scanSummary = "The page was saved, but no text could be read from it. Fill the details in yourself."
        } else if extraction.confidence <= 0 {
            scanSummary = "Read \(result.extraction.recognisedLineCount) lines but couldn't identify any fields. Fill them in yourself."
        } else {
            scanSummary = "Filled in from the scan — please check the dates and reference number before saving."
        }
    }

    private func save() {
        let resolvedTitle = title.trimmingCharacters(in: .whitespaces)
        onSave(DocumentRecord(id: documentID,
                              vehicleID: environment.selectedVehicle?.id,
                              kind: kind,
                              title: resolvedTitle.isEmpty ? kind.displayName : resolvedTitle,
                              provider: provider.isEmpty ? nil : provider,
                              referenceNumber: referenceNumber.isEmpty ? nil : referenceNumber,
                              issueDate: issueDate,
                              expiryDate: (kind.expires && hasExpiry) ? expiryDate : nil,
                              fileName: storedFileName,
                              wasExtractedAutomatically: wasExtractedAutomatically))
        dismiss()
    }

    /// A scan that is abandoned must not leave its image behind.
    private func cancel() {
        if storedFileName != nil {
            DocumentFileStore.shared.delete(documentID: documentID)
        }
        dismiss()
    }
}

/// One document: its details, its status, and the scan if there is one.
struct DocumentDetailView: View {

    let document: DocumentRecord

    @Environment(AppEnvironment.self) private var environment
    @State private var image: UIImage?
    @State private var isRevealingReference = false

    private var formatter: DisplayFormatter { environment.formatter }

    var body: some View {
        List {
            Section {
                HStack(spacing: DL.Spacing.small) {
                    Image(systemName: document.kind.symbolName)
                        .foregroundStyle(DLColor.secondaryText)
                    Text(document.kind.displayName)
                        .font(DL.Font.body.weight(.medium))
                    Spacer()
                    if document.kind.expires {
                        StatusIndicator(status: document.status(now: Date()))
                    }
                }
                .padding(.vertical, DL.Spacing.tight)

                if document.wasExtractedAutomatically {
                    Text("These details were read from a scan. Worth checking against the document itself.")
                        .font(DL.Font.caption)
                        .foregroundStyle(DLColor.watch)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Details") {
                ValueOrReasonRow(label: "Provider", value: document.provider, reason: "Not recorded")
                ValueOrReasonRow(label: "Issued", value: formatter.mediumDate(document.issueDate), reason: "Not recorded")
                ValueOrReasonRow(label: "Expires",
                                 value: formatter.mediumDate(document.expiryDate),
                                 reason: document.kind.expires ? "Not recorded" : "Doesn't expire")
                if let days = document.daysUntilExpiry(now: Date()) {
                    ValueOrReasonRow(label: days < 0 ? "Expired" : "Days remaining",
                                     value: "\(abs(days))")
                }
                referenceRow
            }

            Section("Scan") {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: DL.Radius.small, style: .continuous))
                        .accessibilityLabel("Scanned \(document.kind.displayName.lowercased())")
                } else if document.fileName == nil {
                    Text("No scan was saved with this document.")
                        .font(DL.Font.callout)
                        .foregroundStyle(DLColor.secondaryText)
                } else {
                    Text("The scan couldn't be opened. It is stored with full file protection, so it is unreadable while the device is locked.")
                        .font(DL.Font.callout)
                        .foregroundStyle(DLColor.secondaryText)
                }
            }
        }
        .navigationTitle(document.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadImage() }
    }

    /// Hidden by default: a reference number is the sort of thing that gets read over
    /// a shoulder, and the driver rarely needs it on screen.
    @ViewBuilder
    private var referenceRow: some View {
        if let reference = document.referenceNumber {
            Button {
                isRevealingReference.toggle()
            } label: {
                HStack {
                    Text("Reference")
                        .foregroundStyle(DLColor.primaryText)
                    Spacer()
                    Text(isRevealingReference ? reference : PrivacyLog.redactedDocumentNumber(reference))
                        .font(DL.Font.body.monospaced())
                        .foregroundStyle(DLColor.secondaryText)
                    Image(systemName: isRevealingReference ? "eye.slash" : "eye")
                        .font(.caption)
                        .foregroundStyle(DLColor.unknown)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isRevealingReference ? "Hide reference number" : "Show reference number")
        } else {
            ValueOrReasonRow(label: "Reference", value: nil, reason: "Not recorded")
        }
    }

    private func loadImage() {
        guard let fileName = document.fileName,
              let data = DocumentFileStore.shared.read(fileName: fileName) else { return }
        image = UIImage(data: data)
    }
}
