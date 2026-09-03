import SwiftUI
import MapKit

/// Where the car was left.
///
/// Every modern car app has this and it needs no hardware at all: the last completed
/// drive ended somewhere, and that somewhere is where the car is. DriveLayer already
/// stores the end of each route, so this is a read of data the app has had all along
/// rather than anything new being collected.
///
/// It shows a place name and a time, not a map. The map would be a second copy of the
/// decision already made on the trip screen — the shape of a drive is safe to leave on
/// a table, a pin on your street is not — so getting to the map is a deliberate tap
/// that hands off to Maps, where the driver expects to see exactly that.
///
/// Nothing here appears while a drive is in progress: the car is not parked, and
/// yesterday's spot would be a lie.
struct ParkedCard: View {

    let trip: Trip
    let formatter: DisplayFormatter

    private var endPoint: Trip.RoutePoint? { trip.routePolyline.last }

    var body: some View {
        if let endPoint {
            VStack(alignment: .leading, spacing: DL.Spacing.small) {
                SectionLabel(text: "Parked")

                VStack(alignment: .leading, spacing: DL.Spacing.hairline) {
                    Text(trip.endPlaceName ?? "Where your last drive ended")
                        .font(DL.Font.body.weight(.medium))
                        .foregroundStyle(DLColor.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    if let when = arrivalDescription {
                        Text(when)
                            .font(DL.Font.caption)
                            .foregroundStyle(DLColor.secondaryText)
                    }
                }

                Button {
                    openInMaps(endPoint)
                } label: {
                    Label("Open in Maps", systemImage: "arrow.triangle.turn.up.right.circle")
                        .font(DL.Font.caption.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(DLColor.accent)
                .accessibilityHint("Opens the parking spot in Maps")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .dlCard()
        }
    }

    /// "Arrived 18:42" while it is still today, and the date once it is not — a bare
    /// time on a three-day-old drive reads as though the car moved this morning.
    private var arrivalDescription: String? {
        guard let ended = trip.endedAt else { return nil }
        if Calendar.current.isDateInToday(ended) {
            return formatter.shortTime(ended).map { "Arrived \($0)" }
        }
        return formatter.mediumDate(ended).map { "Last drive ended \($0)" }
    }

    private func openInMaps(_ point: Trip.RoutePoint) {
        let coordinate = CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
        let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        item.name = trip.endPlaceName ?? "Parked"
        item.openInMaps()
    }
}
