//
//  MarkerTitleField.swift
//  Recaptr
//
//  "I'll name them": a small field above the bar for the marker just
//  dropped with ⌘B. Return keeps the title, Esc skips it. Recording
//  carries on; only shown while Recaptr is the active app, so a key
//  pressed from inside a game never pulls focus.
//

import SwiftUI

struct MarkerTitleField: View {
    let number: Int
    @Binding var title: String
    var onDone: () -> Void
    var onSkip: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "bookmark.fill")
                .font(.system(size: 11))
                .foregroundStyle(Color.signal)
            TextField("Marker \(number)", text: $title)
                .textFieldStyle(.plain)
                .font(BrandFont.body(weight: .medium, size: 13).swiftUI)
                .frame(width: 240)
                .focused($focused)
                .onSubmit(onDone)
                .onKeyPress(.escape) { onSkip(); return .handled }
                .accessibilityLabel("Title for marker \(number)")
                .accessibilityIdentifier("markerTitleField")
            Text("↩ Save · Esc Skip")
                .font(BrandFont.body(weight: .regular, size: 11).swiftUI)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .recaptrGlass()
        .onAppear { focused = true }
    }
}
