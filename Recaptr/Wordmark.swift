//
//  Wordmark.swift
//  Recaptr
//
//  The lowercase re:captr wordmark, matching the site: Unbounded Bold
//  outlines with the colon's top dot as the red REC light. The letters
//  follow the foreground style; the dot is always red. Running text and
//  the app name stay "Recaptr".
//

import SwiftUI

struct Wordmark: View {
    var height: CGFloat = 28

    /// Width ÷ height of the artwork, and the red dot's frame within it.
    private static let aspect: CGFloat = 5.9103
    private static let dot = CGRect(x: 0.2605, y: 0.0371, width: 0.0374, height: 0.2213)
    static let recRed = Color(red: 1, green: 0x5F / 255, blue: 0x57 / 255)

    var body: some View {
        let width = height * Self.aspect
        Image("WordmarkLetters")
            .resizable()
            .frame(width: width, height: height)
            .overlay(alignment: .topLeading) {
                Circle()
                    .fill(Self.recRed)
                    .frame(width: Self.dot.width * width, height: Self.dot.height * height)
                    .offset(x: Self.dot.minX * width, y: Self.dot.minY * height)
            }
            .accessibilityElement()
            .accessibilityLabel("Recaptr")
    }
}

#Preview {
    VStack(spacing: 24) {
        Wordmark(height: 40)
        Wordmark(height: 20).foregroundStyle(.secondary)
    }
    .padding(40)
}
