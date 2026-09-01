import Foundation

/// A place in the app that something outside the app can name.
///
/// Widgets, App Intents and CarPlay all need to say "open the maintenance screen"
/// without holding a reference to a view. They say it as a URL, and this type is the
/// single place that decides what those URLs mean — parsing and formatting in one
/// file, so a widget can never build a link the app does not understand.
///
/// The set is deliberately small. A deep link is a promise that a screen exists and
/// can be reached; every case here is one that does.
enum DeepLink: String, CaseIterable, Hashable, Sendable {

    /// Tab roots.
    case today
    case drive
    case trips
    case vehicle

    /// Screens reached by pushing onto a tab.
    ///
    /// `lastTrip` deliberately carries no identifier. The widget that uses it says
    /// "open my last drive", and the app resolves which drive that is at the moment
    /// it opens — so a drive finished since the widget last refreshed opens the new
    /// one rather than a stale one, and no UUID has to survive a round trip through
    /// a URL.
    case lastTrip = "last-drive"
    case insights
    /// The engine intelligence screen. Added when the screen was: `HyperionAssessment`
    /// existed and was read by one CarPlay row, with nothing on the phone to open.
    case hyperion
    case fuel
    case maintenance
    case documents
    case garage
    case settings

    /// Registered in the app's Info.plist. Nothing else claims it.
    static let scheme = "drivelayer"

    var url: URL {
        // Built by hand rather than with URLComponents: the host is a fixed
        // lowercase keyword, so there is nothing to percent-encode and nothing that
        // can fail. Force-unwrapping a string this file controls is honest.
        URL(string: "\(DeepLink.scheme)://\(rawValue)")!
    }

    /// Parses a link the app was opened with.
    ///
    /// Returns `nil` rather than a default for anything unrecognised: opening a
    /// screen the caller did not ask for is worse than ignoring the link.
    init?(url: URL) {
        guard url.scheme?.lowercased() == DeepLink.scheme else { return nil }

        // Accept both `drivelayer://maintenance` and `drivelayer:///maintenance`,
        // because the two are easy to confuse and mean the same thing to a driver.
        let candidate = url.host?.lowercased()
            ?? url.pathComponents.first(where: { $0 != "/" })?.lowercased()

        guard let candidate, let link = DeepLink(rawValue: candidate) else { return nil }
        self = link
    }
}
