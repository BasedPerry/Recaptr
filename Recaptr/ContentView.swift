//
//  ContentView.swift
//  Recaptr
//
//  Phase 2: preview + camera picker + Start/Stop.
//  Phase 3: Record + Stop Recording + Show in Finder.
//  Phase 4 (2026-05-09): audio source picker (None or any AudioSource).
//

import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var vm: MainViewModel

    var body: some View {
        VStack(spacing: 12) {

            SampleBufferPreviewRepresentable(vm: vm)
                .background(Color.black)
                .frame(minWidth: 640, minHeight: 360)
                .cornerRadius(8)
                .padding(.horizontal)
                .padding(.top)

            VStack(spacing: 10) {
                HStack {
                    Text("Camera:").font(.callout)
                    Picker("Camera", selection: $vm.selectedMainSource) {
                        Text("— Select —").tag(VideoSource?.none)
                        ForEach(vm.availableMainSources) { src in
                            Text(src.name).tag(VideoSource?.some(src))
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()

                    Text("Audio:").font(.callout).padding(.leading, 12)
                    Picker("Audio", selection: $vm.selectedAudioSource) {
                        Text("None").tag(AudioSource?.none)
                        ForEach(vm.availableAudioSources) { src in
                            Text(src.name).tag(AudioSource?.some(src))
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()

                    Button("Refresh") {
                        Task { await vm.refreshCatalog() }
                    }
                    .buttonStyle(.bordered)
                }

                HStack(spacing: 12) {
                    if vm.isPreviewing {
                        Button(role: .destructive) {
                            vm.stopPreview()
                        } label: {
                            Label("Stop Preview", systemImage: "stop.fill")
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Button {
                            Task { await vm.startPreview() }
                        } label: {
                            Label("Start Preview", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(vm.selectedMainSource == nil)
                    }

                    if vm.isPreviewing {
                        if vm.isRecording {
                            Button {
                                Task { await vm.stopRecording() }
                            } label: {
                                Label("Stop Recording", systemImage: "stop.circle.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                        } else {
                            Button {
                                Task { await vm.startRecording() }
                            } label: {
                                Label("Record", systemImage: "record.circle")
                            }
                            .buttonStyle(.bordered)
                            .tint(.red)
                        }
                    }

                    if let url = vm.lastRecordedFile, !vm.isRecording {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        } label: {
                            Label("Show in Finder", systemImage: "folder")
                        }
                        .buttonStyle(.bordered)
                    }

                    Spacer()

                    Text(vm.status)
                        .font(.callout.monospaced())
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(12)
            .padding(.horizontal)
        }
        .padding(.bottom)
        .frame(minWidth: 900, minHeight: 540)
    }
}

#Preview {
    ContentView()
        .environmentObject(MainViewModel())
}
