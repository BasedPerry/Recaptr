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