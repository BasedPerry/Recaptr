# Recaptr

macOS capture app (capture cards, cameras, displays, single windows) that records .mov with separate audio tracks and writes Final Cut markers to a matching .fcpxml. macOS 27, Apple silicon, Swift / SwiftUI / AVFoundation / ScreenCaptureKit.

- Design notes: `README.md` (read the section you're touching before changing it).
- Project state: Cerebro `4-💻 Dev/⌨️ Recaptr/⌨️ Recaptr.md` (`## Now`).
- App Store kit: Cerebro `4-💻 Dev/⌨️ Recaptr/2026-09-27_Recaptr_App_Store_Submission.md`.

## Build and test

Xcode lives on the external drive (`xcode-select -p` shows `/Volumes/UGREEN 4TB/Applications/Xcode.app/...`). If the drive isn't mounted, stop and say so.

```bash
# Build (Debug / Release)
xcodebuild -project Recaptr.xcodeproj -scheme Recaptr -destination platform=macOS -derivedDataPath <scratch>/dd build
xcodebuild -project Recaptr.xcodeproj -scheme Recaptr -configuration Release -destination platform=macOS -derivedDataPath <scratch>/ddrel build
# Tests (Swift Testing + XCUITest); add -only-testing:RecaptrUITests/<Class>/<test> for one
xcodebuild -project Recaptr.xcodeproj -scheme Recaptr -destination platform=macOS -derivedDataPath <scratch>/dd test
```

Use one derived-data folder per session in the scratchpad. Ask before deleting old ones.

## Branches and remotes

- `main` is the release line. 1.0 (1) shipped to App Store Connect from `main@56efb0d`, tagged `v1.0`.
- Remote `personal` = github.com/BasedPerry/Recaptr (public, the real one). Remote `origin` = OvertonForge/Recaptr, which GitHub reports as not found. Don't push to `origin`.
- Work on a branch; ask before merging or pushing.

## Never

- **Never run two Recaptr copies.** They fight over the capture card. Gate every launch in the same command: `pgrep -f "Recaptr.app/Contents/MacOS/Recaptr" && echo "RUNNING, not launching" || open -n <path>/Recaptr.app --args ...`. Brandon often has his own copy running from Xcode. If his copy is recording (a .mov growing in the save folder), never touch it.
- **Never exec the binary.** Launch builds with `open -n`. A directly executed app gets TCC-attributed to the shell: black preview, audio still works.
- Never use real settings in tests (see below).

## Gotchas

- **UI tests and test launches need `-RecaptrUITesting YES`.** Test copies share the real app's UserDefaults (same bundle ID); the flag keeps test names out of Brandon's settings. All other `-RecaptrUITest*` arguments require it (full list in README, Testing).
- **Continuity Camera and the iPhone mic are excluded on purpose.** Selecting the iPhone camera on macOS 27 crashes the app (not our bug: clean under ASan and zombies). The iPhone reports as `.external`, so filtering uses `isContinuityCamera`. Don't re-add it without a crash-free test.
- **Store screenshots:** Debug menu (Debug builds only), "Size Window for Store Screenshots" then "Capture Store Screenshot" (⌃⌥⌘P). Saves a 2880x1800 PNG to `<save folder>/Store Screenshots`. `-RecaptrUITestHoldMarkerFlash YES` holds the marker glow.
- Screenshot UI tests fail when the test runner lacks Screen Recording permission; that's the Mac, not the code.
- The screen UI test records at 1440p on purpose (4K60 from the 5K display drops frames under the test harness). `testWindowRecording` can dip to ~50 fps right after a build; rerun before chasing it.
- Build Release before calling anything done. Previews and debug helpers must stay `#if DEBUG`.
- Deprecation warnings listed in README "Known deprecations" are kept on purpose. Don't "fix" them.
- Code comments: short and plain, no dates, names, or history. History goes in commits and the Agent Log.
- Always log which source (camera, screen, window) a profiling or test run actually captured.
