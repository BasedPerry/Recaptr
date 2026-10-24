//
//  AboutWindow.swift
//  Recaptr
//
//  Recaptr → About Recaptr: the wordmark, version, and where to get help.
//

import SwiftUI

struct AboutView: View {
    static let windowID = "about"

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        return "Version \(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            Wordmark(height: 30)
            Text(version)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text("Records capture cards, cameras, screens and windows, with markers for Final Cut Pro. Everything stays on your Mac.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 16) {
                Link("Website", destination: URL(string: "https://overtonforge.app/recaptr/")!)
                Link("Support", destination: URL(string: "https://overtonforge.app/recaptr/support.html")!)
                Link("Privacy", destination: URL(string: "https://overtonforge.app/recaptr/privacy.html")!)
            }
            .font(.callout)
            Text("© Overton Forge. Free and open source (MIT).")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(28)
        .frame(width: 360)
    }
}

/// Replaces the standard About item so it opens `AboutView`.
struct AboutCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("About Recaptr") { openWindow(id: AboutView.windowID) }
    }
}
