//
//  RecordingPill.swift
//  Recaptr
//
//  The mid-take indicator once the controls hide: a small pill at the
//  bottom center, or a tab tucked against the left or right edge.
//  Click the pill for the controls; drag it to an edge to tuck it away.
//  Click the tab, or pull it out, to bring the pill back.
//

import SwiftUI

/// Where the mid-take indicator sits. Remembered between takes.
enum PillTuck: String {
    case center, left, right

    static let key = "RecaptrPillTuck"
    /// The tab's height on its edge, 0 (top) to 1 (bottom).
    static let yKey = "RecaptrPillTuckY"

    /// How close to an edge a dropped pill has to land to tuck.
    static let edgeZone: CGFloat = 140
    /// How far the tab has to be pulled out to come back as the pill.
    static let pullOut: CGFloat = 60
    /// Room kept clear for the top row and the bottom bar.
    static let topInset: CGFloat = 80
    static let bottomInset: CGFloat = 100

    /// Where a pill dropped with its center at `x` ends up, in a window `width` wide.
    static func landing(x: CGFloat, width: CGFloat) -> PillTuck {
        if x < edgeZone { return .left }
        if x > width - edgeZone { return .right }
        return .center
    }

    /// The tab's center for a stored fraction, kept clear of the chrome.
    static func tabY(fraction: Double, height: CGFloat) -> CGFloat {
        let low = topInset, high = max(topInset, height - bottomInset)
        return min(max(CGFloat(fraction) * height, low), high)
    }

    /// The fraction to store for a tab dropped at `y`.
    static func fraction(y: CGFloat, height: CGFloat) -> Double {
        guard height > 0 else { return 0.5 }
        return Double(tabY(fraction: Double(y / height), height: height) / height)
    }
}

/// Red dot, elapsed time, file size, marker count. Observes only the
/// clock so its once-a-second tick doesn't redraw the window.
struct RecordingPill: View {
    @ObservedObject var clock: RecordingClock
    let markerCount: Int
    var glassNamespace: Namespace.ID? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)
                .opacity(clock.anchored ? 1.0 : 0.45)
            Text(clock.formattedElapsed)
                .font(BrandFont.mono(weight: .medium, size: 13).swiftUI)
                .foregroundStyle(.primary)
                .monospacedDigit()
                .contentTransition(.numericText(countsDown: false))
                .animation(reduceMotion ? nil : Motion.snappy, value: clock.formattedElapsed)
            if clock.bytes > 0 {
                Text(ByteCountFormatter.string(fromByteCount: clock.bytes, countStyle: .file))
                    .font(BrandFont.mono(weight: .regular, size: 11).swiftUI)
                    .foregroundStyle(.secondary)
            }
            if markerCount > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.signal)
                    Text("\(markerCount)")
                        .font(BrandFont.mono(weight: .medium, size: 11).swiftUI)
                        .foregroundStyle(.primary)
                }
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale))
            }
        }
        .animation(Motion.pick(Motion.pop, reduceMotion: reduceMotion), value: markerCount)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Capsule())
        .recaptrGlass()
        .recaptrGlassID(BottomBar.glassID, in: glassNamespace)
        .help("Click for the controls. Drag to an edge to tuck it away.")
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("telemetryPill")
    }
}

/// The pill tucked against an edge: red dot, time, and an arrow that
/// points back into the window.
struct TuckedTab: View {
    @ObservedObject var clock: RecordingClock
    /// `.left` or `.right`.
    let edge: PillTuck
    var glassNamespace: Namespace.ID? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            if edge == .right { arrow("chevron.compact.left") }
            Circle()
                .fill(.red)
                .frame(width: 7, height: 7)
                .opacity(clock.anchored ? 1.0 : 0.45)
            Text(clock.formattedElapsed)
                .font(BrandFont.mono(weight: .medium, size: 12).swiftUI)
                .monospacedDigit()
                .contentTransition(.numericText(countsDown: false))
                .animation(reduceMotion ? nil : Motion.snappy, value: clock.formattedElapsed)
            if edge == .left { arrow("chevron.compact.right") }
        }
        .padding(.vertical, 9)
        .padding(.leading, edge == .right ? 8 : 10)
        .padding(.trailing, edge == .right ? 10 : 8)
        .contentShape(shape)
        .recaptrGlass(in: shape)
        .recaptrGlassID(BottomBar.glassID, in: glassNamespace)
        .help("Click or pull out to bring the recording pill back. Drag up or down to move it.")
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("tuckedTab")
    }

    /// Square on the window edge, round on the inside.
    private var shape: UnevenRoundedRectangle {
        let r: CGFloat = 16
        return edge == .right
            ? UnevenRoundedRectangle(topLeadingRadius: r, bottomLeadingRadius: r, style: .continuous)
            : UnevenRoundedRectangle(bottomTrailingRadius: r, topTrailingRadius: r, style: .continuous)
    }

    private func arrow(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
    }
}
