import SwiftUI

/// Four tabs, not seven.
///
/// The brief lists seven areas; most of them are not things a driver opens daily.
/// Today, Drive and Trips are, and the vehicle's own detail is where the rest
/// belongs: Insights are surfaced on Today and expand from there, Garage and the
/// settings live behind the Vehicle tab, and the Debug Center is reached from
/// settings rather than occupying a tab of its own.
struct RootView: View {

    @Environment(AppEnvironment.self) private var environment
    @State private var selection: Tab = .today

    /// Navigation paths live here rather than inside each tab, because a deep link
    /// arriving from a widget has to be able to set them from outside.
    @State private var todayPath: [DeepLink] = []
    @State private var tripsPath: [DeepLink] = []
    @State private var vehiclePath: [DeepLink] = []

    enum Tab: Hashable {
        case today, drive, trips, vehicle
    }

    var body: some View {
        if !environment.settings.hasCompletedOnboarding {
            OnboardingView()
        } else {
            TabView(selection: $selection) {
                TodayView(path: $todayPath)
                    .tabItem { Label("Today", systemImage: "sun.horizon") }
                    .tag(Tab.today)

                DriveView()
                    .tabItem { Label("Drive", systemImage: "steeringwheel") }
                    .tag(Tab.drive)

                TripsListView(path: $tripsPath)
                    .tabItem { Label("Trips", systemImage: "map") }
                    .tag(Tab.trips)

                VehicleView(path: $vehiclePath)
                    .tabItem { Label("Vehicle", systemImage: "car") }
                    .tag(Tab.vehicle)
            }
            .onChange(of: selection) { _, newValue in
                // Location fidelity follows what the driver is actually looking at.
                environment.drive.setDriveScreenVisible(newValue == .drive)
            }
            .onOpenURL { url in
                guard let link = DeepLink(url: url) else { return }
                open(link)
            }
        }
    }

    /// Opens a link from a widget, a shortcut, or CarPlay.
    ///
    /// It replaces the destination tab's path rather than appending to it, so
    /// following the same widget twice lands in the same place instead of stacking.
    private func open(_ link: DeepLink) {
        let route = link.route
        selection = route.tab
        switch route.tab {
        case .today: todayPath = route.path
        case .vehicle: vehiclePath = route.path
        case .drive, .trips: break // Neither tab has a screen a link can push.
        }
    }
}
