import SwiftUI
import MapKit

/// A drive drawn on a real map, coloured by the altitude it was recorded at.
///
/// This is deliberately *not* the default view of a route. `RouteGlyph` is, because a
/// glyph shows the shape of a drive without showing where anyone lives, and someone
/// glancing at a phone on a table should not learn an address. The map is the opt-in:
/// more useful, and more revealing, which is a choice worth leaving to the driver
/// rather than making for them.
///
/// Colour carries altitude rather than speed because altitude is *recorded*.
/// `Trip.RoutePoint` stores latitude, longitude, altitude and a timestamp - no speed -
/// so a speed gradient would have to be derived from consecutive fixes and would be an
/// inference wearing the costume of a measurement. Elevation is the honest gradient to
/// draw here.
struct TripMapView: View {

    let points: [Trip.RoutePoint]

    /// Enough segments to read as a gradient, few enough not to hand MapKit hundreds
    /// of overlays for a long drive.
    private static let maximumSegments = 60

    var body: some View {
        Map(initialPosition: .region(region)) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                MapPolyline(coordinates: segment.coordinates)
                    .stroke(segment.colour, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }
            if let first = coordinates.first {
                Marker("Start", systemImage: "flag", coordinate: first)
                    .tint(DLColor.unknown)
            }
            if let last = coordinates.last, coordinates.count > 1 {
                Marker("End", systemImage: "flag.checkered", coordinate: last)
                    .tint(DLColor.accent)
            }
        }
        .mapStyle(.standard(elevation: .flat))
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityLabel(Text(accessibilityLabel))
    }

    private var coordinates: [CLLocationCoordinate2D] {
        points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    }

    private struct Segment {
        var coordinates: [CLLocationCoordinate2D]
        var colour: Color
    }

    /// Splits the route into runs of consecutive points, each tinted by the altitude
    /// at that part of the drive. Points without an altitude fall back to the plain
    /// accent rather than being coloured as though they were at sea level.
    private var segments: [Segment] {
        guard points.count >= 2 else { return [] }
        let altitudes = points.compactMap(\.altitudeMetres)
        let lowest = altitudes.min()
        let highest = altitudes.max()
        let stride = max(1, points.count / Self.maximumSegments)

        var result: [Segment] = []
        var index = 0
        while index < points.count - 1 {
            let end = min(index + stride, points.count - 1)
            let slice = Array(points[index...end])
            result.append(Segment(coordinates: slice.map {
                CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
            }, colour: colour(for: slice, lowest: lowest, highest: highest)))
            index = end
        }
        return result
    }

    /// A flat range - a drive with no meaningful climb - gets one colour rather than a
    /// gradient amplifying noise into a story about terrain that isn't there. Twenty
    /// metres is roughly where a climb stops being barometer drift.
    ///
    /// The blend is done in `RGB`, the palette's own type, rather than with SwiftUI's
    /// `Color.mix`: the same two endpoints the rest of the app tints with, mixed the
    /// same way CarPlay already mixes them.
    private func colour(for slice: [Trip.RoutePoint], lowest: Double?, highest: Double?) -> Color {
        let sliceAltitudes = slice.compactMap(\.altitudeMetres)
        guard let lowest, let highest, highest - lowest >= 20,
              !sliceAltitudes.isEmpty else { return DLColor.accent }
        let average = sliceAltitudes.reduce(0, +) / Double(sliceAltitudes.count)
        let fraction = min(max((average - lowest) / (highest - lowest), 0), 1)
        let low = Palette.accent(.dark)
        let high = Palette.status(.watch, .dark)
        return Color(red: low.red + (high.red - low.red) * fraction,
                     green: low.green + (high.green - low.green) * fraction,
                     blue: low.blue + (high.blue - low.blue) * fraction)
    }

    private var region: MKCoordinateRegion {
        let latitudes = points.map(\.latitude)
        let longitudes = points.map(\.longitude)
        guard let minLatitude = latitudes.min(), let maxLatitude = latitudes.max(),
              let minLongitude = longitudes.min(), let maxLongitude = longitudes.max() else {
            return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                                      span: MKCoordinateSpan(latitudeDelta: 1, longitudeDelta: 1))
        }
        let centre = CLLocationCoordinate2D(latitude: (minLatitude + maxLatitude) / 2,
                                            longitude: (minLongitude + maxLongitude) / 2)
        // A floor on the span, so a drive around one block does not open zoomed to the
        // point of showing a doorway.
        let span = MKCoordinateSpan(latitudeDelta: max((maxLatitude - minLatitude) * 1.4, 0.005),
                                    longitudeDelta: max((maxLongitude - minLongitude) * 1.4, 0.005))
        return MKCoordinateRegion(center: centre, span: span)
    }

    private var accessibilityLabel: String {
        let climb = points.compactMap(\.altitudeMetres)
        guard let lowest = climb.min(), let highest = climb.max(), highest - lowest >= 20 else {
            return "A map of this drive."
        }
        return "A map of this drive, climbing about \(Int(highest - lowest)) metres between its lowest and highest points."
    }
}
