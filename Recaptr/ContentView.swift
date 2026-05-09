//
//  ContentView.swift
//  Recaptr
//
//  Phase 2 (2026-05-09): minimal preview + camera picker + Start/Stop.
//  Phase 3 (2026-05-09): added Record / Stop Recording controls and
//    a "Show in Finder" affordance for the last recorded file.
//

import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var vm: MainViewModel

    var body: some View {
        VStack(spacing: 12) {

            // ── Live preview surface
            SampleBufferPreviewRepresentable(vm: vm)
                .background(Color.black)
                .frame(minWidth: 640, minHeight: 360)
                .cornerRadius(8)
                .padding(.horizontal)
                .padding(.top)

            // ── Source row
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

                    Button("Refresh") {
                        Task { await vm.refreshCatalog() }
                    }
                    .buttonStyle(.bordered)
                }

                // ── Preview controls
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

                    // ── Record controls (only meaningful while previewing)
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

                    // ── Show last recording in Finder
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
        .frame(minWidth: 800, minHeight: 520)
    }
}

#Preview {
    ContentView()
        .environmentObject(MainViewModel())
}
