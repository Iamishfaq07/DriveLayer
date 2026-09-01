import SwiftUI

/// The card material.
///
/// Before this, a card was a flat fill in a rounded rectangle. That is a template, and
/// it is why the app read as cheap: every surface was the same undifferentiated slab
/// with nothing to say where its edge was or that it sat above anything. This gives a
/// card three things a real object has - a light source, an edge, and a shadow - and
/// applies them identically everywhere, so the whole app is made of one material
/// rather than a collection of rectangles.
struct DLCardSurface: ViewModifier {

    let padding: CGFloat
    let tint: Color?

    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(surface)
            .overlay(edge)
            .clipShape(shape)
            // Two shadows, not one. The tight one defines the edge; the soft one lifts
            // the card. In dark mode the surface colour already separates from the
            // background, so the shadows drop to almost nothing rather than muddying
            // an already-dark screen.
            .shadow(color: .black.opacity(shadowOpacity(DL.Elevation.cardTight.opacity)),
                    radius: DL.Elevation.cardTight.radius,
                    y: DL.Elevation.cardTight.y)
            .shadow(color: .black.opacity(shadowOpacity(DL.Elevation.cardSoft.opacity)),
                    radius: DL.Elevation.cardSoft.radius,
                    y: DL.Elevation.cardSoft.y)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DL.Radius.card, style: .continuous)
    }

    /// Lit from above: a few percent brighter at the top edge than the bottom. Barely
    /// perceptible as a gradient, clearly perceptible as "not flat".
    @ViewBuilder
    private var surface: some View {
        let lift: Double = colorScheme == .dark ? 0.045 : 0.03
        ZStack {
            shape.fill(DLColor.surface)
            shape.fill(
                LinearGradient(colors: [.white.opacity(lift), .clear, .black.opacity(lift * 0.6)],
                               startPoint: .top, endPoint: .bottom)
            )
            if let tint {
                // A status card carries its status in the surface too, faintly. The
                // opacity is low enough that the text on top keeps its contrast - the
                // palette tests check foregrounds against the untinted surface, and a
                // 7% wash does not move a 4.5:1 ratio below the line.
                shape.fill(
                    LinearGradient(colors: [tint.opacity(0.14), tint.opacity(0.04)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
            }
        }
    }

    /// A hairline at the edge. In dark mode this is what stops two adjacent dark
    /// surfaces merging into one; in light mode it keeps a white card from vanishing
    /// against a near-white background.
    private var edge: some View {
        shape.strokeBorder(
            LinearGradient(colors: [.white.opacity(colorScheme == .dark ? 0.10 : 0.9),
                                    .white.opacity(colorScheme == .dark ? 0.03 : 0.4)],
                           startPoint: .top, endPoint: .bottom),
            lineWidth: colorScheme == .dark ? 0.75 : 1
        )
        .blendMode(colorScheme == .dark ? .plusLighter : .normal)
    }

    private func shadowOpacity(_ base: Double) -> Double {
        colorScheme == .dark ? base * 0.35 : base
    }
}

/// A card that answers the touch.
///
/// Tappable cards used to be indistinguishable from static ones until you found the
/// chevron. Now the whole surface dips and dims under the finger, which is both the
/// affordance and the feedback. Reduce Motion drops the scale and keeps the dim, so the
/// press is still visible without anything moving.
struct DLPressableCardStyle: ButtonStyle {

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.975 : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(DL.Motion.quick, value: configuration.isPressed)
            .contentShape(RoundedRectangle(cornerRadius: DL.Radius.card, style: .continuous))
            // The lightest tick the system offers. A card is not a button; it should
            // feel like paper settling, not a switch clicking.
            .sensoryFeedback(.selection, trigger: configuration.isPressed) { _, pressed in pressed }
    }
}

/// The primary action: a full-width, tall, filled button with a real target.
///
/// Stock `.borderedProminent` is 34pt tall and fine for a form. In a car mount it is a
/// target the size of a fingertip, and Start drive and End drive are the two things a
/// driver taps most. This is 56pt, fills the width, dips under the finger, and gives a
/// firm haptic on release so the action is felt without being looked at.
///
/// - Parameter role: `.destructive` renders in the status red rather than the accent,
///   because ending a drive is a decision and should look like one.
struct DLPrimaryButtonStyle: ButtonStyle {

    var role: ButtonRole? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var fill: Color { role == .destructive ? DLColor.critical : DLColor.accent }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DL.Font.body.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 56)
            .background(
                RoundedRectangle(cornerRadius: DL.Radius.card, style: .continuous)
                    .fill(LinearGradient(colors: [fill.opacity(0.92), fill],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay(
                        RoundedRectangle(cornerRadius: DL.Radius.card, style: .continuous)
                            .strokeBorder(.white.opacity(0.18), lineWidth: 1)
                    )
                    .shadow(color: fill.opacity(configuration.isPressed ? 0.15 : 0.35),
                            radius: configuration.isPressed ? 6 : 14, y: configuration.isPressed ? 2 : 8)
            )
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(DL.Motion.quick, value: configuration.isPressed)
            .sensoryFeedback(.impact(weight: .medium), trigger: configuration.isPressed) { was, now in
                was && !now   // on release, not on touch-down
            }
    }
}

extension View {
    /// The one primary action on a screen.
    func dlPrimaryButton(role: ButtonRole? = nil) -> some View {
        buttonStyle(DLPrimaryButtonStyle(role: role))
    }
}

/// Arrival: fade and rise on first appearance, staggered by index.
///
/// The screens used to pop into existence fully formed. A cascade - each card a few
/// hundredths of a second after the one above - is what makes a screen feel assembled
/// rather than loaded. It runs once, on appear, and never again on state changes, so a
/// live value updating does not make its card jump.
struct DLArrival: ViewModifier {

    let index: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasArrived = false

    func body(content: Content) -> some View {
        content
            .opacity(hasArrived ? 1 : 0)
            .offset(y: hasArrived || reduceMotion ? 0 : 14)
            .onAppear {
                guard !hasArrived else { return }
                if reduceMotion {
                    hasArrived = true
                    return
                }
                withAnimation(DL.Motion.arrive.delay(Double(index) * DL.Motion.stagger)) {
                    hasArrived = true
                }
            }
    }
}
