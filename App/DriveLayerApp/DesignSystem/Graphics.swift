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
