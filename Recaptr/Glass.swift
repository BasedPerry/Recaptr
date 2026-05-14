import SwiftUI
import AppKit

/// Generic Liquid Glass background container clipped to any Shape.
///
/// Uses `.glassEffect()` on macOS 26+, falls back to
/// `NSVisualEffectView` with the `.hudWindow` material on earlier
/// systems. Both paths render a translucent surface with a hairline
/// white edge.
struct GlassCard<S: Shape>: View {
    let shape: S
    init(_ shape: S) { self.shape = shape }
    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                Color.clear
                    .glassEffect()
                    .clipShape(shape)
                    .overlay(shape.stroke(.white.opacity(0.06), lineWidth: 1))
            } else {
                VisualEffectView(material: .hudWindow, blending: .withinWindow)
                    .clipShape(shape)
                    .overlay(shape.stroke(.white.opacity(0.06), lineWidth: 1))
            }
        }
    }
}

/// AppKit `NSVisualEffectView` wrapper for SwiftUI. Used as the
/// pre-macOS-26 fallback for Liquid Glass surfaces.
struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blending: NSVisualEffectView.BlendingMode
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material; v.blendingMode = blending
        v.state = .active; v.isEmphasized = true
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - Brand Liquid Glass capsule

/// Capsule-shaped Liquid Glass background used by the floating chrome
/// pills (source switcher, audio module, recording controls, telemetry).
///
/// Renders translucent — no solid color overlay — so the preview
/// behind the pill remains visible. An optional `topTint` paints a
/// faint top-down gradient in the supplied color for brand hinting
/// without compromising translucency.
struct BrandGlassCapsule: ViewModifier {
    let topTint: Color?

    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    // Translucent glass surface.
                    Group {
                        if #available(macOS 26.0, *) {
                            Color.clear.glassEffect()
                        } else {
                            VisualEffectView(material: .hudWindow,
                                             blending: .withinWindow)
                        }
                    }
                    .clipShape(Capsule())

                    // Optional top-down tint gradient. Low alpha so the
                    // preview behind the pill still shows through.
                    if let tint = topTint {
                        Capsule().fill(
                            LinearGradient(
                                stops: [
                                    .init(color: tint.opacity(0.14), location: 0.0),
                                    .init(color: .clear,             location: 1.0),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    }
                }
            )
            // Hairline edge defines the pill's contour at low alpha.
            .overlay(
                Capsule()
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
            )
            .clipShape(Capsule())
    }
}

extension View {
    /// Apply the Liquid Glass capsule background to this view. Pass
    /// an optional `topTint` color (e.g. `.violet`) to add a faint
    /// gradient hint at the top edge.
    func brandGlassCapsule(topTint: Color? = nil) -> some View {
        modifier(BrandGlassCapsule(topTint: topTint))
    }
}
