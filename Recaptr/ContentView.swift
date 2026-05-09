//
//  ContentView.swift
//  Recaptr
//
//  Phase 2 (2026-05-09): minimal layout per v2 spec.
//  - SampleBufferPreviewRepresentable taking most of the window
//  - Camera picker (filters to .camera sources for Phase 2)
//  - Start Preview / Stop Preview toggle
//  - Status text
//
//  Brand kit (cool palette: graphite/signal-green/violet/restore-blue)
//  is deferred to Phase 7. Phase 2 is plain SwiftUI for the smoke test.
//

import SwiftUI

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

            // ── Controls
            VStack(spacing: 10) {
                HStack {
                    Text("Camera:")
                        .font(.callout)
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

                HStack(spacing: 12) {
                    if vm.isPreviewing {
                        Button(role: .destructive) {
                            vm.stopPreview()
                        } label: {
                            Label("Stop Preview", systemImage: "stop.fill")
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button {
                            Task { await vm.startPreview() }
                        } label: {
                            Label("Start Preview", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(vm.selectedMainSource == nil)
                    }

                    Spacer()

                    Text(vm.status)
                        .font(.callout.monospaced())
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(12)
            .padding(.horizontal)
        }
        .padding(.bottom)
        .frame(minWidth: 720, minHeight: 480)
    }
}

#Preview {
    ContentView()
        .environmentObject(MainViewModel())
}
