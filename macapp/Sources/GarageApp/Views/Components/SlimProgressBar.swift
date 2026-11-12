import SwiftUI

/// A thin, flat progress bar: a 4pt capsule track with a solid fill, no glow or gloss.
///
/// The Sources page puts one at the trailing end of every row's status line, where the system's
/// linear `ProgressView` drew a heavy full-width bar. With `fraction` nil the bar is indeterminate:
/// a short segment slides across the track (still, with Reduce Motion on).
struct SlimProgressBar: View {
    var fraction: Double?
    var tint: Color = .accentColor
    var height: CGFloat = 4

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                if let fraction {
                    Capsule()
                        .fill(tint)
                        .frame(width: max(fraction > 0 ? height : 0, width * min(max(fraction, 0), 1)))
                } else {
                    IndeterminateSegment(width: width, tint: tint, animated: !reduceMotion)
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityLabel("Progress")
        .accessibilityValue(fraction.map { "\(Int(($0 * 100).rounded())) percent" } ?? "In progress")
    }
}

/// The sliding third of the track an indeterminate bar shows.
private struct IndeterminateSegment: View {
    let width: CGFloat
    let tint: Color
    let animated: Bool
    @State private var atEnd = false

    var body: some View {
        let segment = width / 3
        Capsule()
            .fill(tint)
            .frame(width: segment)
            .offset(x: animated ? (atEnd ? width : -segment) : segment)
            .onAppear {
                guard animated else { return }
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                    atEnd = true
                }
            }
    }
}
