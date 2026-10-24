//
//  WelcomeSheet.swift
//  Recaptr
//
//  First-launch onboarding in four steps: source, permissions (explained
//  before macOS asks), save folder, and markers. Skippable; Help →
//  Welcome to Recaptr shows it again. Everything here is also in
//  Settings or the sidebar.
//

import SwiftUI
import AVFoundation

struct WelcomeSheet: View {
    static let seenKey = "RecaptrWelcomeSeen"

    @EnvironmentObject var vm: MainViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Step: Int, CaseIterable { case source, permissions, folder, markers }
    @State private var step: Step = .source

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, 24)
                .padding(.horizontal, 28)

            Group {
                switch step {
                case .source:      SourceStep()
                case .permissions: PermissionsStep()
                case .folder:      FolderStep(storage: vm.recordingStorage)
                case .markers:     MarkersStep()
                }
            }
            .environmentObject(vm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
            .id(step)
            .transition(reduceMotion ? .opacity : .push(from: .trailing))

            footer
                .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .animation(Motion.pick(Motion.snappy, reduceMotion: reduceMotion), value: step)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("welcomeSheet")
    }

    // MARK: Header and footer

    private var header: some View {
        VStack(spacing: 10) {
            if step == .source {
                Wordmark(height: 30)
                    .foregroundStyle(.primary)
                    .padding(.bottom, 4)
            }
            Text(title)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.self) { s in
                    Capsule()
                        .fill(s.rawValue <= step.rawValue ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: s == step ? 18 : 6, height: 6)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count)")
        }
    }

    private var title: String {
        switch step {
        case .source:      return "What will you record?"
        case .permissions: return "Allow access"
        case .folder:      return "Where should takes go?"
        case .markers:     return "Markers"
        }
    }

    private var footer: some View {
        HStack {
            if step == .source {
                Button("Skip") { finish() }
                    .help("Use the defaults. Everything is in Settings and the sidebar.")
                    .accessibilityIdentifier("welcomeSkip")
            } else {
                Button("Back") { step = Step(rawValue: step.rawValue - 1) ?? .source }
                    .accessibilityIdentifier("welcomeBack")
            }
            Spacer()
            if step == .markers {
                Button("Done") { finish() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(vm.markerNaming == nil)
                    .help(vm.markerNaming == nil ? "Pick how markers are named first" : "")
                    .accessibilityIdentifier("welcomeDone")
            } else {
                Button("Continue") { step = Step(rawValue: step.rawValue + 1) ?? .markers }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("welcomeContinue")
            }
        }
    }

    private func finish() {
        // Test copies share the user's settings; they never mark these seen.
        if !TestHooks.isOn {
            // A new user has nothing to catch up on.
            UserDefaults.standard.set(WhatsNewSheet.version, forKey: WhatsNewSheet.seenKey)
            UserDefaults.standard.set(true, forKey: Self.seenKey)
        }
        vm.finishOnboarding()
        dismiss()
    }
}

// MARK: - Step 1: source

private struct SourceStep: View {
    @EnvironmentObject var vm: MainViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            choice(.camera, title: "A capture card or camera",
                   detail: "A console or another PC through a USB capture card, or a USB camera.",
                   symbol: "gamecontroller")
            choice(.screen, title: "This Mac's screen or a window",
                   detail: "A game or app running on this Mac. You can switch any time with ⌘1–3.",
                   symbol: "display")
        }
    }

    private func choice(_ source: MainViewModel.StartSource, title: String, detail: String, symbol: String) -> some View {
        let picked = vm.startSource == source
        return Button {
            vm.startSource = source
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 20))
                    .frame(width: 28)
                    .foregroundStyle(picked ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(picked ? Color.accentColor : .secondary)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(picked ? 0.08 : 0.03)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(picked ? [.isSelected] : [])
        .accessibilityIdentifier("welcomeSource-\(source.rawValue)")
    }
}

// MARK: - Step 2: permissions

private struct PermissionsStep: View {
    @EnvironmentObject var vm: MainViewModel
    @State private var camera = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var mic = AVCaptureDevice.authorizationStatus(for: .audio)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("macOS asks once for each. Here's why Recaptr needs them.")
                .foregroundStyle(.secondary)
            if vm.startSource == .camera {
                row("Camera", detail: "Capture cards show up to macOS as cameras, so the picture needs this.",
                    status: camera, id: "camera") {
                    camera = await Self.request(.video)
                }
                row("Microphone", detail: "For the capture card's game audio, and your mic if you use one.",
                    status: mic, id: "microphone") {
                    mic = await Self.request(.audio)
                }
            } else {
                screenRow
                row("Microphone (optional)", detail: "Only if you want your voice on its own track.",
                    status: mic, id: "microphone") {
                    mic = await Self.request(.audio)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            camera = AVCaptureDevice.authorizationStatus(for: .video)
            mic = AVCaptureDevice.authorizationStatus(for: .audio)
        }
    }

    private var screenRow: some View {
        PermissionLine(title: "Screen & System Audio Recording",
                       detail: "To capture the screen, a window, and the sound the Mac plays. After allowing it, macOS may ask you to reopen Recaptr.",
                       granted: vm.screenCapturePermissionGranted,
                       denied: false,
                       id: "screen",
                       allow: { vm.screenModeSelected() },
                       open: { vm.openScreenCapturePrivacyPane() })
    }

    private func row(_ title: String, detail: String, status: AVAuthorizationStatus, id: String,
                     allow: @escaping () async -> Void) -> some View {
        PermissionLine(title: title, detail: detail,
                       granted: status == .authorized,
                       denied: status == .denied || status == .restricted,
                       id: id,
                       allow: { Task { await allow() } },
                       open: { Self.openPane(id == "camera" ? "Privacy_Camera" : "Privacy_Microphone") })
    }

    private static func request(_ type: AVMediaType) async -> AVAuthorizationStatus {
        _ = await AVCaptureDevice.requestAccess(for: type)
        return AVCaptureDevice.authorizationStatus(for: type)
    }

    private static func openPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct PermissionLine: View {
    let title: String
    let detail: String
    let granted: Bool
    let denied: Bool
    let id: String
    let allow: () -> Void
    let open: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Color.signal)
                    .accessibilityIdentifier("permission-\(id)-allowed")
            } else if denied {
                Button("Open System Settings", action: open)
                    .accessibilityIdentifier("permission-\(id)-open")
            } else {
                Button("Allow", action: allow)
                    .accessibilityIdentifier("permission-\(id)-allow")
            }
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Step 3: save folder

private struct FolderStep: View {
    @ObservedObject var storage: RecordingStorage
    @EnvironmentObject var vm: MainViewModel
    @State private var diskTime: DiskTime?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Each take is a .mov with a Final Cut file beside it. Pick a folder with room: an external drive is ideal.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Image(systemName: "folder")
                Text(storage.hasUserLocation ? storage.displayLabel : "Not chosen yet")
                    .foregroundStyle(storage.hasUserLocation ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(storage.displayPath)
                Spacer()
                Button(storage.hasUserLocation ? "Change…" : "Choose…") { storage.pickFolder() }
                    .accessibilityIdentifier("welcomeChooseFolder")
            }
            if let diskTime {
                Text("\(diskTime.label) at \(vm.videoQuality.label)")
                    .font(.callout)
                    .foregroundStyle(diskTime.level.color)
                    .accessibilityIdentifier("welcomeDiskTime")
            }
        }
        .task(id: storage.displayPath) { diskTime = vm.diskTimeLeft() }
    }
}

// MARK: - Step 4: markers

private struct MarkersStep: View {
    @EnvironmentObject var vm: MainViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                if let key = vm.hotKeyLabel(for: .dropMarker) {
                    keyLine(key, "drops a marker from inside your game")
                }
                keyLine("⌘B", "drops one when Recaptr is in front")
                if let key = vm.hotKeyLabel(for: .toggleRecording) {
                    keyLine(key, "starts and stops recording from any app")
                } else {
                    keyLine("⌘R", "starts and stops recording")
                }
            }
            Divider()
            Text("How should markers be named?").font(.headline)
            NamingChoices()
        }
    }

    private func keyLine(_ key: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Text(key)
                .font(.system(.body, design: .rounded).weight(.semibold))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)))
            Text(text).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The three naming modes as cards. Nothing is picked until the user picks.
struct NamingChoices: View {
    @EnvironmentObject var vm: MainViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(MarkerNaming.allCases) { mode in
                let unavailable = mode == .appleIntelligence && !MarkerNamer.isAvailable
                let picked = vm.markerNaming == mode
                Button { vm.markerNaming = mode } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: picked ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(picked ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mode.label).font(.body.weight(.medium))
                            Text(unavailable ? (MarkerNamer.unavailableReason ?? "Not available on this Mac.") : mode.detail)
                                .font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(unavailable)
                .opacity(unavailable ? 0.5 : 1)
                .accessibilityAddTraits(picked ? [.isSelected] : [])
                .accessibilityIdentifier("naming-\(mode.rawValue)")
            }
        }
    }
}

#if DEBUG
#Preview {
    WelcomeSheet()
        .environmentObject(MainViewModel())
}
#endif
