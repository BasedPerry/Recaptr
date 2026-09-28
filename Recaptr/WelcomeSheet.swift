//
//  WelcomeSheet.swift
//  Recaptr
//
//  First-launch setup. Everything here is also in Settings.
//

import SwiftUI

struct WelcomeSheet: View {
    static let seenKey = "RecaptrWelcomeSeen"

    @EnvironmentObject var vm: MainViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
                Text("Welcome to Recaptr")
                    .font(.title2.bold())
                Text("A few choices to start. You can change any of them in Settings.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 24)
            .padding(.horizontal, 24)

            Form {
                Section("Save recordings to") {
                    FolderRow(storage: vm.recordingStorage)
                }

                Section("Start with") {
                    Picker("Start with", selection: $vm.startSource) {
                        ForEach(MainViewModel.StartSource.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    .onChange(of: vm.startSource) { _, source in
                        // Ask for Screen Recording now, while it's clearly why.
                        if source == .screen { vm.screenModeSelected() }
                    }
                }

                Section {
                    Toggle("Name markers and episodes with Apple Intelligence", isOn: $vm.aiNamingEnabled)
                        .disabled(!MarkerNamer.isAvailable)
                } footer: {
                    Text(MarkerNamer.unavailableReason ?? "Runs on your Mac. Nothing is uploaded.")
                }

                Section("Shortcuts") {
                    LabeledContent("Record or stop", value: "⌘R")
                    LabeledContent("Add a marker", value: "⌘B")
                    LabeledContent("Add a marker from any app", value: "⌃⌥⌘B")
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)

            HStack {
                Spacer()
                Button("Get Started") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("welcomeDone")
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct FolderRow: View {
    @ObservedObject var storage: RecordingStorage

    var body: some View {
        LabeledContent {
            Button(storage.hasUserLocation ? "Change…" : "Choose…") { storage.pickFolder() }
        } label: {
            Text(storage.hasUserLocation ? storage.displayLabel : "Not chosen yet")
                .foregroundStyle(storage.hasUserLocation ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(storage.displayPath)
        }
    }
}

#if DEBUG
#Preview {
    WelcomeSheet()
        .environmentObject(MainViewModel())
}
#endif
