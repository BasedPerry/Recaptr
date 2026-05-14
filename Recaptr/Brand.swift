//
//  Brand.swift
//  Recaptr
//
//  Design system tokens: palette, semantic color aliases, gradients,
//  typography, spacing rhythm, corner radii. Every component
//  references the semantic aliases (recaptrAccent, recaptrSurface,
//  etc.), so a single change here cascades through the UI.
//

import SwiftUI

// MARK: - Brand palette

extension Color {
    static let graphite     = Color(red: 0x1B/255, green: 0x1F/255, blue: 0x23/255)
    static let graphite2    = Color(red: 0x24/255, green: 0x2A/255, blue: 0x30/255)
    static let graphite3    = Color(red: 0x2C/255, green: 0x33/255, blue: 0x3B/255)
    static let signal       = Color(red: 0x8D/255, green: 0xFC/255, blue: 0xB7/255)
    static let violet       = Color(red: 0xA1/255, green: 0x79/255, blue: 0xF2/255)
    static let restore      = Color(red: 0x5E/255, green: 0xB2/255, blue: 0xD6/255)
    static let beige        = Color(red: 0xCF/255, green: 0xCA/255, blue: 0xC2/255)
    static let beigeBright  = Color(red: 0xF4/255, green: 0xF0/255, blue: 0xE8/255)

    /// Warm amber used for "off / warning" semantics (mute, no-signal,
    /// error states). Not part of the cool palette proper but kept
    /// alongside it for discoverability.
    static let warningAmber = Color(red: 0xE8/255, green: 0x9A/255, blue: 0x3F/255)
}

// MARK: - Semantic aliases

extension Color {
    static let recaptrBackground    = Color.graphite
    static let recaptrSurface       = Color.graphite2
    static let recaptrSurfaceHi     = Color.graphite3
    static let recaptrTextPrimary   = Color.beigeBright
    static let recaptrTextSecondary = Color.beige
    static let recaptrTextMuted     = Color.beige.opacity(0.62)
    static let recaptrTextDim       = Color.beige.opacity(0.38)
    static let recaptrBorder        = Color.beige.opacity(0.10)
    static let recaptrBorderStrong  = Color.beige.opacity(0.20)
    static let recaptrAccent        = Color.restore
    static let recaptrAccentMuted   = Color.restore.opacity(0.18)
    static let recaptrStatus        = Color.signal
    static let recaptrWarning       = Color.warningAmber
}

// MARK: - Gradients

extension LinearGradient {
    /// 135° restore → violet → signal. Reserved for hero accents and
    /// brand-signature moments; not for routine segment fills.
    static let recaptrSignal = LinearGradient(
        stops: [
            .init(color: .restore, location: 0.0),
            .init(color: .violet,  location: 0.52),
            .init(color: .signal,  location: 1.0),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

extension RadialGradient {
    /// Soft radial spotlight from top center. Used behind hero
    /// sections and the preview surface on first open.
    static let recaptrHeroGlow = RadialGradient(
        stops: [
            .init(color: Color.restore.opacity(0.18), location: 0.0),
            .init(color: Color.violet.opacity(0.10),  location: 0.5),
            .init(color: .clear,                       location: 1.0),
        ],
        center: .top,
        startRadius: 0,
        endRadius: 600
    )
}

// MARK: - Typography
//
// Space Grotesk (heading) + Inter (body) + IBM Plex Mono (telemetry).
// All three families ship in Recaptr/Fonts/ and auto-register via the
// INFOPLIST_KEY_ATSApplicationFontsPath build setting. If a .ttf is
// missing, Font.custom silently falls back to the system font.

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
