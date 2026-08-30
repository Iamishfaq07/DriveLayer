import SwiftUI

/// Where each deep link opens, in terms of the app's own structure.
///
/// `DeepLink` lives in the core and knows only about URLs, which is what makes it
/// testable without a UI. This extension is the other half: it says which tab a link
/// belongs to and what, if anything, gets pushed onto that tab.
extension DeepLink {

    struct Route {
        var tab: RootView.Tab
        /// Pushed onto that tab's stack. Empty when the link names the tab itself.
        var path: [DeepLink]
    }

    var route: Route {
        switch self {
        case .today: return Route(tab: .today, path: [])
        case .drive: return Route(tab: .drive, path: [])
        case .trips: return Route(tab: .trips, path: [])
        case .lastTrip: return Route(tab: .trips, path: [.lastTrip])
        case .vehicle: return Route(tab: .vehicle, path: [])
        case .insights: return Route(tab: .today, path: [.insights])
        case .fuel: return Route(tab: .vehicle, path: [.fuel])
        case .maintenance: return Route(tab: .vehicle, path: [.maintenance])
        case .documents: return Route(tab: .vehicle, path: [.documents])
        case .garage: return Route(tab: .vehicle, path: [.garage])
        case .settings: return Route(tab: .vehicle, path: [.settings])
        }
    }
}

/// The screen a link names.
///
/// One switch, used by every navigation stack in the app, so "the glovebox" means the
/// same view whether it was reached by tapping a row, following a widget, or asking
/// Siri.
struct DeepLinkDestination: View {

    let link: DeepLink

    var body: some View {
        switch link {
        case .lastTrip: LatestTripView()
        case .insights: InsightsView()
        case .fuel: FuelView()
        case .maintenance: MaintenanceView()
        case .documents: DocumentsView()
        case .garage: GarageView()
        case .settings: SettingsView()
        case .vehicle: VehicleContentView()
        case .today, .drive, .trips:
            // Tab roots are reached by switching tab, never by pushing, so nothing
            // routes them here. Rendering something honest beats a blank screen if
            // a future caller gets it wrong.
            DLEmptyState(symbol: "arrow.uturn.backward",
                         title: "Nothing to show here",
                         message: "This screen is one of the main tabs. Pick it from the tab bar instead.")
        }
    }
}

extension View {
    /// Teaches a navigation stack to resolve `NavigationLink(value: DeepLink…)` and
    /// the paths that deep links set. Every stack that can host one applies it.
    func deepLinkDestinations() -> some View {
        navigationDestination(for: DeepLink.self) { DeepLinkDestination(link: $0) }
    }
}
