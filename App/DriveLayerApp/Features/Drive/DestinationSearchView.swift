import SwiftUI

/// Picks where the driver is going, so DriveLayer can forecast the road there.
///
/// The sheet is explicit about what setting a destination costs: it is the one thing
/// in the app that sends a location to a server, and it happens only while this
/// search is open and while a route is being looked up. Nothing is remembered — no
/// search history, no recent destinations, no address.
struct DestinationSearchView: View {

    let onChoose: (RouteDestination) -> Void

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var search = DestinationSearch()
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(search.results) { result in
                        Button {
                            onChoose(result)
                            dismiss()
                        } label: {
                            HStack(spacing: DL.Spacing.small) {
                                Image(systemName: "mappin.circle")
                                    .foregroundStyle(DLColor.secondaryText)
                                    .accessibilityHidden(true)
                                Text(result.name)
                                    .foregroundStyle(DLColor.primaryText)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    if search.isSearching {
                        Text("Searching")
                    } else if !search.results.isEmpty {
                        Text("Results")
                    }
                } footer: {
                    Text(footer)
                }
            }
            .navigationTitle("Where to?")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Place or address")
            .onChange(of: query) { _, newValue in
                search.search(newValue, near: environment.location.latest)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        search.clear()
                        dismiss()
                    }
                }
            }
        }
    }

    private var footer: String {
        if search.failed {
            return "That search didn't come back. Check your connection and try again."
        }
        if query.trimmingCharacters(in: .whitespacesAndNewlines).count < 3 && search.results.isEmpty {
            return "DriveLayer uses your destination only to look up the weather along the way. The place you pick is kept on this device until you clear it, and nothing about the search is saved."
        }
        if !search.isSearching && search.results.isEmpty {
            return "Nothing found for that. Try a different name."
        }
        return "Weather is checked at points along the road to the place you pick."
    }
}
