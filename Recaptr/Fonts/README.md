# Recaptr Fonts

Drop the .ttf files for the three brand families into this folder.

**Three families, minimal set:**

| File | Source | Notes |
|---|---|---|
| `SpaceGrotesk-Regular.ttf` | Google Fonts | Body fallback + heading regular |
| `SpaceGrotesk-Medium.ttf` | Google Fonts | Heading default — used most |
| `SpaceGrotesk-Bold.ttf` | Google Fonts | Display / hero titles |
| `Inter-Regular.ttf` | Google Fonts | Body text default |
| `Inter-Medium.ttf` | Google Fonts | Body emphasis / segment labels |
| `IBMPlexMono-Regular.ttf` | Google Fonts | Telemetry / status / hex codes |
| `IBMPlexMono-Medium.ttf` | Google Fonts | Mono emphasis |

**Where to grab them:** [fonts.google.com](https://fonts.google.com). Search each family, click "Get font," download the .zip. Each .zip contains a `static/` subfolder with the individual weight files — use those (not the variable `[wght]` file at the .zip root).

Alternative one-line Terminal command if you prefer curl (run from this directory):

```bash
cd "/Users/gully/Documents/Claude Cowork/Dev/Recaptr/Recaptr/Fonts" && \
for url in \
  "https://raw.githubusercontent.com/google/fonts/main/ofl/spacegrotesk/static/SpaceGrotesk-Regular.ttf" \
  "https://raw.githubusercontent.com/google/fonts/main/ofl/spacegrotesk/static/SpaceGrotesk-Medium.ttf" \
  "https://raw.githubusercontent.com/google/fonts/main/ofl/spacegrotesk/static/SpaceGrotesk-Bold.ttf" \
  "https://raw.githubusercontent.com/google/fonts/main/ofl/inter/static/Inter-Regular.ttf" \
  "https://raw.githubusercontent.com/google/fonts/main/ofl/inter/static/Inter-Medium.ttf" \
  "https://raw.githubusercontent.com/google/fonts/main/ofl/ibmplexmono/IBMPlexMono-Regular.ttf" \
  "https://raw.githubusercontent.com/google/fonts/main/ofl/ibmplexmono/IBMPlexMono-Medium.ttf"; do
  curl -L -O "$url"
done && ls -la *.ttf
```

(Note: if a `static/` path 404s, the family may only ship as a variable font in google/fonts. In that case grab the variable `Family[wght].ttf` instead and Brand.swift's `Font.custom(...).weight(...)` will still hit the right axis at runtime.)

## Verifying after rebuild

1. ⌘B the project.
2. In `Brand.swift`'s `BrandFont.swiftUI` property, set a breakpoint or `print()` to confirm the font name resolves cleanly.
3. Open `SourceSwitcherPill.swift` Preview. The "Window / Screen / Camera" labels should render in **Inter Medium** (rounder, more geometric than SF Pro).
4. Open `Brand.swift` and add a temporary `Text` view in a preview to confirm Space Grotesk Bold renders for headings.

## How the bundling works

This folder is auto-included as bundle resources by Xcode 16's `PBXFileSystemSynchronizedRootGroup`. The build setting `INFOPLIST_KEY_ATSApplicationFontsPath = "Fonts"` tells macOS to look in `Recaptr.app/Contents/Resources/Fonts/` for embeddable fonts and register them at launch.

## PostScript names

`Font.custom(_:size:)` requires the **PostScript name** of the font, not the filename. For these specific .ttf files the PostScript names match the filenames sans `.ttf`:

- `SpaceGrotesk-Regular` / `SpaceGrotesk-Medium` / `SpaceGrotesk-Bold`
- `Inter-Regular` / `Inter-Medium`
- `IBMPlexMono-Regular` / `IBMPlexMono-Medium`

If you swap in different fonts later (different family, different weight), match the PostScript name in `Brand.swift`'s font-name resolvers. Use Font Book on macOS to inspect any font's PostScript name.

## What if a font doesn't load?

`Font.custom("...")` silently falls back to the system font (SF Pro / SF Mono) if the PostScript name isn't found in the bundle. The app won't crash; it'll just render with system fonts. So mistakes here are visual, not fatal.
