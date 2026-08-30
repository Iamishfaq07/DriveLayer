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

    enum Tab: Hashable {
        case today, drive, trips, vehicle
    }

    var body: some View {
        if !environment.settings.hasCompletedOnboarding {
            OnboardingView()
        } else {
            TabView(selection: $selection) {
                TodayView()
                    .tabItem { Label("Today", systemImage: "sun.horizon") }
                    .tag(Tab.today)

                DriveView()
                    .tabItem { Label("Drive", systemImage: "steeringwheel") }
                    .tag(Tab.drive)

                TripsListView()
                    .tabItem { Label("Trips", systemImage: "map") }
                    .tag(Tab.trips)

                VehicleView()
                    .tabItem { Label("Vehicle", systemImage: "car") }
                    .tag(Tab.vehicle)
            }
            .onChange(of: selection) { _, newValue in
                // Location fidelity follows what the driver is actually looking at.
                environment.drive.setDriveScreenVisible(newValue == .drive)
            }
        }
    }
}
