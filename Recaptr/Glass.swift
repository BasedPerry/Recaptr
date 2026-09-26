//
//  Glass.swift
//  Recaptr
//
//  The one Liquid Glass primitive for Recaptr's floating chrome.
//
//  Everything is system glass with nothing drawn on top: no tint
//  gradient, no hairline stroke, no manual shadow. That keeps every
//  surface under the control of the user's system settings (the
//  Liquid Glass look slider in System Settings > Appearance, Light /
//  Dark, Reduce Transparency, Increase Contrast), and changes to those
//  settings apply live without a relaunch.
//
//  Rules for callers:
//    - One glass layer per surface. Controls inside a glass pill are
//      plain (borderless) so glass never stacks on glass.
//    - `interactive: true` only when the glass itself is the control
//      (for example a standalone icon button), not for a container
//      that merely holds controls.
//    - Do not add tints or overlays. Color belongs to content (record
//      red, meters), not to the glass.
//

import SwiftUI

extension View {
    /// Apply Recaptr's standard Liquid Glass background in `shape`.
    func recaptrGlass(
        in shape: some Shape = Capsule(),
        interactive: Bool = false
    ) -> some View {
        glassEffect(.regular.interactive(interactive), in: shape)
    }

    /// Temporary shim while call sites migrate to `recaptrGlass`.
    /// `topTint` is ignored on purpose. Removed at the end of the
    /// component migration.
    @available(*, deprecated, renamed: "recaptrGlass(in:interactive:)")
    func brandGlassCapsule(topTint: Color? = nil) -> some View {
        recaptrGlass()
    }
}
