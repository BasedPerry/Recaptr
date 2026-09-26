//
//  Brand.swift
//  Recaptr
//
//  Design tokens: palette, gradients, typography, spacing, radii.
//
//  Two kinds of color live here:
//
//    Chrome (text and icons sitting on glass) does NOT use brand
//    colors. Use the system hierarchical styles instead:
//    `.foregroundStyle(.primary / .secondary / .tertiary)` and
//    `.fill(.quaternary)`. Those get vibrancy on glass and follow
//    Light / Dark, Increase Contrast, and the Liquid Glass look
//    setting automatically. Selection and focus use the system accent
//    (`Color.accentColor`), which follows the user's accent choice.
//
//    Semantic brand colors carry meaning: mode identity, meters,
//    markers, warnings. Each one is a dynamic color with Light, Dark,
//    and high-contrast variants so it stays legible in every
//    appearance. Record red is the system `.red`.
//

import SwiftUI
import AppKit

// MARK: - Semantic brand palette

extension Color {
    /// Signal green: healthy level, monitor on, markers.
    nonisolated static let signal = Color.adaptive(
        light: 0x1A9E5C, dark: 0x8DFCB7, lightHC: 0x0B7A42, darkHC: 0xB5FFD1)
    /// Violet: Screen mode identity, mid-level meter band.
    nonisolated static let violet = Color.adaptive(
        light: 0x7645D8, dark: 0xA179F2, lightHC: 0x5A2DB8, darkHC: 0xC3A6FF)
    /// Restore blue: Window mode identity, low end of the volume fill.
    nonisolated static let restore = Color.adaptive(
        light: 0x1F7FA8, dark: 0x5EB2D6, lightHC: 0x0F6187, darkHC: 0x8FD0EC)
    /// Warm amber for "off / warning" semantics (mute, no signal).
    nonisolated static let warningAmber = Color.adaptive(
        light: 0xB5650F, dark: 0xE89A3F, lightHC: 0x8F4E05, darkHC: 0xFFB860)

    /// Graphite letterbox behind the video preview. Stays dark in
    /// both appearances because it frames video, not chrome.
    nonisolated static let recaptrBackground = Color(
        red: 0x1B / 255, green: 0x1F / 255, blue: 0x23 / 255)

    /// Dynamic color that resolves per appearance, including the
    /// Increase Contrast variants. Resolves live when the user
    /// changes appearance, so no relaunch is needed.
    nonisolated static func adaptive(
        light: UInt32, dark: UInt32, lightHC: UInt32, darkHC: UInt32
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [
                .aqua, .darkAqua,
                .accessibilityHighContrastAqua,
                .accessibilityHighContrastDarkAqua,
            ])
            switch match {
            case .darkAqua:                          return NSColor(hex: dark)
            case .accessibilityHighContrastAqua:     return NSColor(hex: lightHC)
            case .accessibilityHighContrastDarkAqua: return NSColor(hex: darkHC)
            default:                                 return NSColor(hex: light)
            }
        })
    }
}

private extension NSColor {
    nonisolated convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1)
    }
}

// MARK: - Typography
//
// Space Grotesk (heading) + Inter (body) + IBM Plex Mono (telemetry).
// The .ttf files go in Recaptr/Fonts/ and auto-register via the
// INFOPLIST_KEY_ATSApplicationFontsPath build setting. As of
// 2026-09-26 the folder holds only its README, so every BrandFont
// currently falls back to the system font (Font.custom does this
// silently).

enum BrandFont {
    case heading(weight: Font.Weight, size: CGFloat)
    case body(weight: Font.Weight, size: CGFloat)
    case mono(weight: Font.Weight, size: CGFloat)

    var swiftUI: Font {
        switch self {
        case .heading(let w, let s):
            return Font.custom(BrandFont.spaceGroteskName(for: w), size: s)
                .weight(w)
        case .body(let w, let s):
            return Font.custom(BrandFont.interName(for: w), size: s)
                .weight(w)
        case .mono(let w, let s):
            return Font.custom(BrandFont.ibmPlexMonoName(for: w), size: s)
                .weight(w)
        }
    }

    // PostScript-name resolvers per weight. Match the names in
    // Font Book's "PostScript name" field if swapping in different
    // .ttf files.

    private static func spaceGroteskName(for w: Font.Weight) -> String {
        switch w {
        case .ultraLight, .thin, .light: return "SpaceGrotesk-Light"
        case .medium:                    return "SpaceGrotesk-Medium"
        case .semibold:                  return "SpaceGrotesk-SemiBold"
        case .bold, .heavy, .black:      return "SpaceGrotesk-Bold"
        default:                         return "SpaceGrotesk-Regular"
        }
    }

    private static func interName(for w: Font.Weight) -> String {
        switch w {
        case .medium:                    return "Inter-Medium"
        case .semibold:                  return "Inter-SemiBold"
        case .bold, .heavy, .black:      return "Inter-Bold"
        default:                         return "Inter-Regular"
        }
    }

    private static func ibmPlexMonoName(for w: Font.Weight) -> String {
        switch w {
        case .medium, .semibold:         return "IBMPlexMono-Medium"
        case .bold, .heavy, .black:      return "IBMPlexMono-Bold"
        default:                         return "IBMPlexMono-Regular"
        }
    }
}

// MARK: - Spacing rhythm
//
// Strict 4 / 8 / 12 / 16 / 24 / 32 pt grid.

enum Spacing {
    static let xxs:  CGFloat = 4
    static let xs:   CGFloat = 8
    static let sm:   CGFloat = 12
    static let md:   CGFloat = 16
    static let lg:   CGFloat = 24
    static let xl:   CGFloat = 32
}

// MARK: - Corner radii

enum Radius {
    static let pill:    CGFloat = 999
    static let card:    CGFloat = 16
    static let button:  CGFloat = 12
    static let inset:   CGFloat = 8
}
