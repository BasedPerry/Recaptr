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
        glassEffect(.regular.tint(tint).interactive(interactive), in: shape)
    }
}

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
