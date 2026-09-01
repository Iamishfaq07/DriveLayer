import SwiftUI

/// The DriveLayer mark: a road receding to a horizon under a dark sky.
///
/// The same image as the app icon (which is generated as a bitmap because Apple wants
/// one), here drawn live so it can appear at any size, in either appearance, and
/// animate. The dashed centre line advances slowly while `isAnimated` is on - the
/// smallest possible statement that the app is about movement - and stands still
/// under Reduce Motion.
struct RoadMark: View {

    var isAnimated: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let horizon = size.height * 0.46

            ZStack {
                // Sky: deep panel blue, lit faintly above the horizon.
                RoundedRectangle(cornerRadius: size.width * 0.22, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.04, green: 0.06, blue: 0.10),
                                                  Color(red: 0.11, green: 0.16, blue: 0.29)],
                                         startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.46)))
                RoundedRectangle(cornerRadius: size.width * 0.22, style: .continuous)
                    .fill(RadialGradient(colors: [Color(red: 0.27, green: 0.41, blue: 0.65).opacity(0.55), .clear],
                                         center: UnitPoint(x: 0.5, y: 0.46),
                                         startRadius: 0, endRadius: size.width * 0.5))

                // Road: a trapezoid from a vanishing point at the horizon to the bottom.
                Path { path in
                    path.move(to: CGPoint(x: size.width * 0.455, y: horizon))
                    path.addLine(to: CGPoint(x: size.width * 0.545, y: horizon))
                    path.addLine(to: CGPoint(x: size.width * 1.12, y: size.height))
                    path.addLine(to: CGPoint(x: -size.width * 0.12, y: size.height))
                    path.closeSubpath()
                }
                .fill(LinearGradient(colors: [Color(red: 0.20, green: 0.24, blue: 0.31),
                                              Color(red: 0.09, green: 0.11, blue: 0.14)],
                                     startPoint: UnitPoint(x: 0.5, y: 0.46), endPoint: .bottom))

                // Centre line: dashes that lengthen towards the viewer, moving slowly.
                Path { path in
                    path.move(to: CGPoint(x: size.width * 0.5, y: horizon + 2))
                    path.addLine(to: CGPoint(x: size.width * 0.5, y: size.height))
                }
                .stroke(Color(red: 0.94, green: 0.70, blue: 0.24),
                        style: StrokeStyle(lineWidth: size.width * 0.028,
                                           lineCap: .round,
                                           dash: [size.height * 0.09, size.height * 0.08],
                                           dashPhase: phase))
                .mask(
                    // Fade the line in from the horizon so it does not start abruptly.
                    LinearGradient(colors: [.clear, .white], startPoint: UnitPoint(x: 0.5, y: 0.46),
                                   endPoint: UnitPoint(x: 0.5, y: 0.7))
                )
            }
            .clipShape(RoundedRectangle(cornerRadius: size.width * 0.22, style: .continuous))
            .onAppear {
                guard isAnimated, !reduceMotion else { return }
                withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) {
                    // One full dash period, so the loop is seamless.
                    phase = -(size.height * 0.17)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}
