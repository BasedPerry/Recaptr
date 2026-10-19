//
//  Glass.swift
//  Recaptr
//
//  Liquid Glass for the floating chrome. Plain system glass with nothing
//  drawn on top, so it follows the user's appearance settings live.
//  One glass layer per surface; controls inside it stay plain.
//

import SwiftUI

extension View {
    /// Standard glass background. Use `interactive` only when the glass
    /// itself is the control, and `tint` only to signal state.
    func recaptrGlass(
        in shape: some Shape = Capsule(),
        interactive: Bool = false,
        tint: Color? = nil
    ) -> some View {
        #if DEBUG
        modifier(DebugGlass(shape: shape, interactive: interactive, tint: tint))
        #else
        glassEffect(.regular.tint(tint).interactive(interactive), in: shape)
        #endif
    }
}

extension View {
    /// Glass shapes with the same id inside one GlassEffectContainer
    /// morph into each other when one replaces the other.
    @ViewBuilder
    func recaptrGlassID(_ id: String, in namespace: Namespace.ID?) -> some View {
        if let namespace { glassEffectID(id, in: namespace) } else { self }
    }
}

#if DEBUG
/// Debug → Glass Test: compare glass setups live while dragging the
/// system's Liquid Glass slider.
enum GlassTest: String, CaseIterable, Identifiable {
    case standard, noContainer, noFade, clearVariant, noVideo
    var id: String { rawValue }
    static let key = "RecaptrDebugGlassTest"
    /// Debug → Keep Controls Visible: no auto fade.
    static let keepChromeKey = "RecaptrDebugKeepChrome"

    var title: String {
        switch self {
        case .standard:     return "Standard"
        case .noContainer:  return "No Glass Container"
        case .noFade:       return "No Fade"
        case .clearVariant: return "Clear Glass Variant"
        case .noVideo:      return "Gradient Instead of Video"
        }
    }
}

private struct DebugGlass<S: Shape>: ViewModifier {
    let shape: S
    let interactive: Bool
    let tint: Color?
    @AppStorage(GlassTest.key) private var test = GlassTest.standard

    func body(content: Content) -> some View {
        if test == .clearVariant {
            content.glassEffect(.clear.tint(tint).interactive(interactive), in: shape)
        } else {
            content.glassEffect(.regular.tint(tint).interactive(interactive), in: shape)
        }
    }
}
#endif

// MARK: - Preview stage

#if DEBUG
/// Shows chrome over bright, dark, and busy backdrops. Previews can't
/// simulate the Liquid Glass look setting, so also check the running app.
struct ChromePreviewStage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 0) {
            stage(Color.white)
            stage(Color.recaptrBackground)
            stage(busy)
        }
    }

    private func stage(_ backdrop: some View) -> some View {
        ZStack {
            backdrop
            content.padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Stand-in for a busy camera feed.
    private var busy: some View {
        ZStack {
            AngularGradient(colors: [.orange, .pink, .blue, .green, .yellow, .orange],
                            center: .center)
            VStack(spacing: 14) {
                ForEach(0..<8, id: \.self) { i in
                    Rectangle()
                        .fill(i.isMultiple(of: 2) ? Color.black : Color.white)
                        .frame(height: 6)
                }
            }
        }
    }
}
#endif
