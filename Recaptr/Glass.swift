import SwiftUI
import AppKit

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
//
// True Liquid Glass background for the three floating pills.
// macOS 26 path uses the system .glassEffect() — same material as
// the Tahoe menu bar, Control Center, and the QuickTime HUD.
// Older systems fall back to NSVisualEffectView (.hudWindow) which
// is the closest pre-Tahoe approximation.
//
// We do NOT stack a solid Color.recaptrSurface overlay on top — that
// is what made the v1 pills read as graphite panels rather than glass.
// Instead, an optional `topTint` adds a very faint hero-glow ramp
// from the top, keeping the surface obviously translucent.

struct BrandGlassCapsule: ViewModifier {
    let topTint: Color?

    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    // Layer 1 — true glass (transparent + blur)
                    Group {
                        if #available(macOS 26.0, *) {
                            Color.clear.glassEffect()
                        } else {
                            VisualEffectView(material: .hudWindow,
                                             blending: .withinWindow)
                        }
                    }
                    .clipShape(Capsule())

                    // Layer 2 — optional faint hero-glow tint at top.
                    // Kept low alpha (0.14) so the underlying preview
                    // still shows through; this is brand tint, not a fill.
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
            // Soft hairline edge — half-alpha brand border so the pill
            // has a contour without becoming a hard-edged panel.
            .overlay(
                Capsule()
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
            )
            .clipShape(Capsule())
    }
}

extension View {
    /// Recaptr's true Liquid Glass capsule background. Pass an
    /// optional `topTint` (e.g. `.violet`) for a brand-flavored
    /// hero-glow hint at the top edge of the pill.
    func brandGlassCapsule(topTint: Color? = nil) -> some View {
        modifier(BrandGlassCapsule(topTint: topTint))
    }
}