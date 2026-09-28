# Recaptr

A macOS capture app for capture cards, cameras, displays, and single windows. It records to .mov with separate source and mic audio tracks, and writes Final Cut markers to a matching .fcpxml.

Requires macOS 27 and Apple silicon. Open `Recaptr.xcodeproj` and run the `Recaptr` scheme.

## Layout

| Area | Files |
|---|---|
| App and state | `RecaptrApp`, `MainViewModel`, `Models`, `DeviceCatalog`, `RecordingStorage` |
| Video capture | `CameraCaptureService`, `ScreenCaptureService`, `SampleBufferPreviewView` |
| Audio | `AudioMixer`, `MonitorRing`, `PeakLimiter`, `LevelTracker` |
| Writing | `Recorder`, `FinalCutMarkers`, `SessionNaming` |
| Naming | `MarkerNamer`, `BrandVoice` |
| UI | `ContentViewNext`, `SourceSidebar`, `SettingsView`, pills, `Glass`, `Brand`, `LevelMeter`, `CaptureOutline`, `GlobalHotKey` |

## Video

**Sources.** USB cameras and capture cards (`.external`), displays, and windows. Continuity Camera and the iPhone's Continuity microphone are excluded: on macOS 27, selecting the iPhone camera corrupts the main actor's executor and the app crashes on the next main-thread check. It reproduces on older builds and shows no bad writes under Address Sanitizer or zombies.

**Cameras and capture cards.** `activeFormat` is set after `addInput` (the session preset overrides it otherwise), and the device stays locked for configuration until `stop()`, or it drops back to its default rate. Frame durations use the format's own `minFrameDuration`, since the device matches `CMTime` by exact value. Some cards tag HDMI video as SMPTE 240M; frames are retagged Rec. 709.

**Screens and windows.** SCStream only sends frames when something changes. To get a constant frame rate, the recorder takes the newest frame on every tick of a fixed 60 or 30 fps grid, driven by arriving frames and a timer that trails the clock by 50 ms. A still window may send nothing at all, so a screenshot seeds the grid after 300 ms. Capture is 420v Rec. 709. Display captures exclude Recaptr's own windows.

**Preview.** An `AVSampleBufferDisplayLayer` backs the view. Frames are skipped while the window is hidden or covered.

## Audio

Each input device gets its own `AVAudioEngine` with a tap that converts to 48 kHz stereo Float32, applies gain, and updates the meters. The mixer is pull-based: a timer emits every 1024-frame chunk that's due by the host clock, with silence for any starved channel so all tracks stay the same length. Timestamps are host time at start plus the sample count, so audio lines up with video.

Each source gets its own AAC track (no mix track). A linked limiter at -1 dBFS keeps the sum of the tracks from clipping without changing the balance.

**Drift.** Every device has its own clock, which drifts up to about 100 ms an hour against the host. The real rate is measured from tap timestamps (or SCStream frame times) after 20 s, and `DriftPacer` drops or repeats single frames to match. Drift isn't estimated from backlog, because a late timer looks like backlog.

**Screen audio.** With no mic armed, SCStream system audio goes straight to the recorder. With a mic, it goes through the mixer's "System" channel.

**Monitor.** A separate output-only engine. The low-latency path is a sink node writing into a lock-free ring (`MonitorRing`) that the output reads at about 20 ms of fill. Cameras monitor the source; screens monitor the mic only, since system audio already plays.

**Recovery.** A channel that delivers nothing is restarted (0.6 s after start, 1.5 s while running), with back-off, and the UI is told after repeated failures.

## Recording

- **Crash-safe files.** `movieFragmentInterval` is 5 s, so an interrupted take opens up to the last fragment.
- **Markers.** Kept in memory and written to the .fcpxml (FCPXML 1.11) at stop, never into the .mov: a metadata track made the writer fail. The fcpxml frame rate is measured from the first 10 s of frame spacing, since dropouts pull the nominal rate down to 59.94.
- **Health.** Won't start under 2 GB free. While recording: a warning under 5 GB, auto-stop under 1 GB, a one-time thermal warning, and idle system and display sleep are blocked (capture cards stall when the display sleeps).
- **After stop.** The file is probed for its tracks, markers and a blank episode are named, the file moves to `<Series>/Series – Ep N – Title.mov`, and the .fcpxml is written beside it. `renameLastTake` can redo this.
- **Save folder.** Stored as a security-scoped bookmark. Recaptr asks for a folder before the first recording.
- **First launch.** A welcome sheet (`WelcomeSheet`) sets the save folder, the start source (capture card or main display), and naming. It shows once; Help → Welcome to Recaptr reopens it. Screen Recording is only requested when Screen is picked.

## Naming

Runs after the take, on-device. Each marker gets the two most detailed of three frames (1.5 s before, at, and after the press; flat or black frames are skipped) plus a transcript of the mic from 20 s before to 3 s after. Near-duplicate names get one retry at a higher temperature, then a number. Colons in titles become U+A789 so they're legal in file names. Without Apple Intelligence, markers keep their numbers.

## Shortcuts

⌘R record · ⌘B marker · ⌃⌥⌘B marker from any app · ⇧⌘R save last 15 s (screen and window) · ⌘K monitor · ⌃⌘S sidebar · ⌘1/2/3 Window, Screen, Camera

The global key is a Carbon hot key: it works in the sandbox and needs no Accessibility permission.

## Testing

Unit tests use Swift Testing; UI tests use XCUITest. The screen test records at 1440p because 4K60 from a 5K display drops frames under the test harness.

Launch arguments (all need `-RecaptrUITesting YES`, which also keeps test names out of the user's settings):

| Argument | Effect |
|---|---|
| `-RecaptrKeepChromeVisible YES` | No idle fade |
| `-RecaptrUITestSource display` / `window:<name>` | Start on a screen or window source |
| `-RecaptrUITestMicInput <name>` | Arm the first mic matching `<name>` |
| `-RecaptrUITestSeries <name>`, `-RecaptrUITestEpisode <name>` | Preset naming fields |
| `-RecaptrUITestResetNaming YES` | Clear saved series first |
| `-RecaptrUITestAutoRecord <s>` | Record once for `<s>` seconds, print a probe, quit |
| `-RecaptrUITestAutoMarkers <n>` | Spread n markers through the auto take |
| `-RecaptrUITestMonitor YES`, `-RecaptrUITestMonitorVolume <n>` | Monitor during the auto take |
| `-RecaptrUITestProbeLatest YES` | Probe the newest .mov and quit (Debug) |
| `-RecaptrUITestMeasureMonitorLag YES` | Log monitor ring stats and lag (Debug) |
| `-RecaptrUITestStopBelowGB <n>`, `-RecaptrUITestDiskCheckSeconds <n>` | Test the low-disk stop |
| `-RecaptrUITestNoDriftCorrection YES` | Measure drift without correcting |
| `-RecaptrUITestMonitorTapPath YES` | Force the fallback monitor path |
| `-RecaptrUITestStallMixer <s>` | Stall the mixer 6 s in |
| `-RecaptrUITestSimulateAudioReset notify\|silent\|down` | Simulate an audio engine reset |
| `-RecaptrUITestNoFragments YES` | Write without fragments (Debug) |
| `-RecaptrUITestIgnoreFramesFor <s>` | Ignore SCStream frames, to test the seed (Debug) |
| `-RecaptrUITestHoldMarkerFlash YES` | Hold the marker glow for screenshots |

`TEST_RUNNER_RECAPTR_EXTRA_ARGS` on the xcodebuild command line passes extra arguments to UI tests.

## Known deprecations

These are kept on purpose:

- `installTap`: the replacement delivers no audio after a channel restart.
- `expectsMediaDataInRealTime`: still needed; without it about 40% of frames come back "not ready".
- `AVAssetReader` calls in `FinalCutMarkers` and `MarkerNamer`, and `sampleBufferRenderer` enqueue/flush in the preview: migration planned for 1.1.
