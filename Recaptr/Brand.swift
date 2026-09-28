//
//  Brand.swift
//  Recaptr
//
//  Design tokens. Brand colors are for meaning (modes, meters, markers,
//  warnings). Text and icons on glass use system hierarchical styles, and
//  selection uses the system accent.
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
    /// Amber: off or warning (mute, no signal).
    nonisolated static let warningAmber = Color.adaptive(
        light: 0xB5650F, dark: 0xE89A3F, lightHC: 0x8F4E05, darkHC: 0xFFB860)

    /// Letterbox behind the preview. Dark in both appearances because it frames video.
    nonisolated static let recaptrBackground = Color(
        red: 0x1B / 255, green: 0x1F / 255, blue: 0x23 / 255)

    /// Resolves per appearance, including Increase Contrast, and updates live.
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
// No font files ship with the app, so Font.custom falls back to the system font.

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

    // PostScript names, as shown in Font Book.

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

// MARK: - Spacing

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
