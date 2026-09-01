import SwiftUI

/// A status as a ring rather than a small symbol.
///
/// The app's headline judgements - "your vehicle is Normal", "Hyperion is Watch" - were
/// carried by a 20pt SF Symbol beside a word. Correct, and invisible. A ring gives the
/// one status a screen is about the weight it deserves: it fills to the status on
/// appear, glows faintly in the status colour, and keeps the symbol in the middle so
/// the shape-carries-meaning rule survives without colour.
///
/// The fill fraction is a visual rank, not a measurement: normal fills the ring,
/// critical fills it too but in red, unknown leaves it mostly open. It is there to make
/// the ring feel alive on arrival, not to be read as a percentage.
struct StatusRing: View {

    let status: SemanticStatus
    var size: CGFloat = 72
    var lineWidth: CGFloat = 6

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress: Double = 0

    var body: some View {
        ZStack {
            Circle()
                .stroke(DLColor.status(status).opacity(0.14), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(DLColor.status(status),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: DLColor.status(status).opacity(0.45), radius: lineWidth * 1.4)
            Image(systemName: status.symbolName)
                .font(.system(size: size * 0.34, weight: .semibold))
                .foregroundStyle(DLColor.status(status))
                .contentTransition(.symbolEffect(.replace))
        }
        .frame(width: size, height: size)
        .onAppear { fill() }
        .onChange(of: status) { _, _ in fill() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(status.label))
    }

    private func fill() {
        if reduceMotion {
            progress = fraction
        } else {
            progress = 0
            withAnimation(DL.Motion.fill) { progress = fraction }
        }
    }

    private var fraction: Double {
        switch status {
        case .normal: return 1
        case .watch: return 0.72
        case .attention: return 0.86
        case .critical: return 1
        case .unknown: return 0.28
        }
    }
}

/// A live indicator: a dot that breathes while something is happening.
///
/// "Recording a drive" was a line of grey text. This is the same statement made with
/// motion - a soft pulse that says *now*, continuously, in the driver's peripheral
/// vision. Static when Reduce Motion is on.
struct LiveDot: View {

    var isLive: Bool
    var tint: Color = DLColor.accent

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    var body: some View {
        ZStack {
            if isLive && !reduceMotion {
                Circle()
                    .fill(tint.opacity(0.35))
                    .scaleEffect(breathing ? 2.4 : 1)
                    .opacity(breathing ? 0 : 0.8)
            }
            Circle().fill(tint)
        }
        .frame(width: 8, height: 8)
        .onAppear {
            guard isLive, !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) {
                breathing = true
            }
        }
        .accessibilityHidden(true)
    }
}

/// A large numeric value that counts rather than snaps.
///
/// A speed rising from 40 to 60 rolls its digits instead of replacing them, so a value
/// that changes reads as motion rather than as a different number appearing.
struct RollingNumber: View {

    let value: String?
    var font: DL.ScaledFont = .display
    var weight: SwiftUI.Font.Weight = .semibold
    var tint: Color = DLColor.primaryText

    var body: some View {
        Text(value ?? "—")
            .dlFont(font, weight: weight, usesMonospacedDigits: true)
            .foregroundStyle(value == nil ? DLColor.unknown : tint)
            .contentTransition(.numericText(countsDown: false))
            .animation(DL.Motion.value, value: value)
    }
}

/// A horizontal bar for a fraction of something - fuel, a baseline's maturity, a
/// section's share. Fills on appear with the same spring as the rings, so the whole
/// app's gauges move with one rhythm.
struct FillBar: View {

    /// 0...1. `nil` renders the empty track only, which is the honest picture of
    /// "not reported" - never a full bar, never an empty one pretending to be zero.
    let fraction: Double?
    var tint: Color = DLColor.accent
    var height: CGFloat = 6

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: Double = 0

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(DLColor.primaryText.opacity(DL.Opacity.fill))
                if fraction != nil {
                    Capsule()
                        .fill(LinearGradient(colors: [tint.opacity(0.75), tint],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(height, proxy.size.width * shown))
                }
            }
        }
        .frame(height: height)
        .onAppear { animate() }
        .onChange(of: fraction) { _, _ in animate() }
        .accessibilityHidden(true)
    }

    private func animate() {
        let target = min(max(fraction ?? 0, 0), 1)
        if reduceMotion {
            shown = target
        } else {
            withAnimation(DL.Motion.fill) { shown = target }
        }
    }
}

/// A drive's shape, drawn from its route, at thumbnail size.
///
/// Every trip already carried a polyline that was rendered nowhere. Drawn small, it
/// gives each row in the list a shape - the commute is a recognisable squiggle, the
/// motorway run a long line - and that is what lets a driver find a drive by looking
/// rather than by reading dates. Axis-free and unlabelled on purpose: it is a glyph,
/// not a map, and it leaks nothing about where the drive actually was.
///
/// A trip with fewer than two points draws a dot, which is the honest shape of a
/// drive that recorded no movement.
struct RouteGlyph: View {

    let points: [Trip.RoutePoint]
    var tint: Color = DLColor.accent
    var lineWidth: CGFloat = 2

    var body: some View {
        GeometryReader { proxy in
            let scaled = normalised(in: proxy.size)
            if scaled.count >= 2 {
                Path { path in
                    path.move(to: scaled[0])
                    for point in scaled.dropFirst() { path.addLine(to: point) }
                }
                .stroke(LinearGradient(colors: [tint.opacity(0.45), tint],
                                       startPoint: .leading, endPoint: .trailing),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                // The end of the drive gets a dot, so direction is legible.
                Circle()
                    .fill(tint)
                    .frame(width: lineWidth * 2.2, height: lineWidth * 2.2)
                    .position(scaled[scaled.count - 1])
            } else {
                Circle()
                    .fill(tint.opacity(0.6))
                    .frame(width: lineWidth * 2.5, height: lineWidth * 2.5)
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            }
        }
        .accessibilityHidden(true)
    }

    /// Fits the route into the box, preserving aspect ratio, with a little inset so the
    /// round line caps are not clipped. Longitude is scaled by cos(latitude) so a
    /// north-south drive and an east-west drive of the same length look the same length.
    private func normalised(in size: CGSize) -> [CGPoint] {
        // Thin the polyline: a thumbnail does not need every one-second point, and
        // several hundred segments in a 44pt box is wasted work on every list scroll.
        let stride = max(1, points.count / 60)
        let sampled = Swift.stride(from: 0, to: points.count, by: stride).map { points[$0] }
            + (points.count > 1 && (points.count - 1) % stride != 0 ? [points[points.count - 1]] : [])
        guard sampled.count >= 2,
              let minLat = sampled.map(\.latitude).min(), let maxLat = sampled.map(\.latitude).max(),
              let minLon = sampled.map(\.longitude).min(), let maxLon = sampled.map(\.longitude).max()
        else { return [] }

        let midLat = (minLat + maxLat) / 2
        let lonScale = cos(midLat * .pi / 180)
        let spanX = max((maxLon - minLon) * lonScale, 0.000_01)
        let spanY = max(maxLat - minLat, 0.000_01)

        let inset = lineWidth * 1.5
        let boxW = size.width - inset * 2
        let boxH = size.height - inset * 2
        let scale = min(boxW / spanX, boxH / spanY)
        let drawnW = spanX * scale
        let drawnH = spanY * scale
        let offsetX = inset + (boxW - drawnW) / 2
        let offsetY = inset + (boxH - drawnH) / 2

        return sampled.map { point in
            CGPoint(x: offsetX + (point.longitude - minLon) * lonScale * scale,
                    y: offsetY + (maxLat - point.latitude) * scale)   // north up
        }
    }
}

/// The background behind every screen: not a flat colour but a dark field with one
/// soft highlight near the top. This is the "instrument panel at night" the design
/// system describes and never actually drew. The highlight takes the vehicle's status
/// colour when one is supplied, so a screen about a car that needs attention is warmer
/// at the top edge than one that is fine - a cue that lands before any text does.
struct PanelBackground: View {

    var statusTint: Color? = nil

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            DLColor.background
            RadialGradient(colors: [(statusTint ?? DLColor.accent).opacity(colorScheme == .dark ? 0.16 : 0.10),
                                    .clear],
                           center: UnitPoint(x: 0.5, y: -0.1),
                           startRadius: 0,
                           endRadius: 520)
        }
        .ignoresSafeArea()
    }
}
