//
//  AfterTakeCard.swift
//  Recaptr
//
//  Rises out of the bottom bar when a take is saved: name, length, size,
//  each marker with a thumbnail of its frame, and Open in Final Cut,
//  Show in Finder and Edit Names. Esc or a new recording closes it.
//

import SwiftUI
import AVFoundation

struct AfterTakeCard: View {
    let take: Take
    var glassNamespace: Namespace.ID? = nil
    var onClose: () -> Void

    @EnvironmentObject var vm: MainViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var duration: Double?
    @State private var fileSize: Int64?
    @State private var thumbnails: [Int: CGImage] = [:]

    @State private var isEditing = false
    @State private var series = ""
    @State private var episode = ""
    @State private var titles: [String] = []
    @State private var error: String?
    @FocusState private var focusedMarker: Int?

    static let glassID = "afterTakeGlass"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if !take.markers.isEmpty {
                markerStrip
            } else if isEditing {
                EmptyView()
            } else {
                Text("No markers in this take.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            actions
        }
        .padding(18)
        .frame(maxWidth: 860, alignment: .leading)
        .recaptrGlass(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .recaptrGlassID(Self.glassID, in: glassNamespace)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recording saved")
        .accessibilityIdentifier("afterTakeCard")
        .task(id: take.url) { await load() }
        .onAppear {
            resetFields()
            // "I'll name them": open ready to type the first marker's name.
            if vm.markerNaming == .manual, !take.markers.isEmpty {
                startEditing(focus: 0)
            }
        }
        .onChange(of: take) { _, _ in resetFields() }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                if isEditing {
                    HStack(spacing: 8) {
                        // A new series moves the take into that series' folder.
                        TextField("Series", text: $series, prompt: Text("No series"))
                            .textFieldStyle(.roundedBorder)
                            .font(.headline)
                            .frame(width: 180)
                            .onSubmit(save)
                            .help("Changing the series moves the take and its Final Cut file into that series' folder")
                            .accessibilityIdentifier("afterTakeSeriesField")
                        TextField(series.isEmpty ? "Name" : "Episode", text: $episode)
                            .textFieldStyle(.roundedBorder)
                            .font(.headline)
                            .frame(maxWidth: 420)
                            .onSubmit(save)
                            .accessibilityIdentifier("afterTakeEpisodeField")
                    }
                } else {
                    Text(take.url.deletingPathExtension().lastPathComponent)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Text(details)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close (Esc)")
            .accessibilityLabel("Close")
            .accessibilityIdentifier("afterTakeClose")
        }
    }

    /// "PS5 stuff · 12:04 · 1.6 GB · 3 markers"
    private var details: String {
        var parts: [String] = []
        if !take.series.isEmpty { parts.append(take.series) }
        if let duration { parts.append(Self.timecode(duration)) }
        if let fileSize { parts.append(ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)) }
        let n = take.markers.count
        parts.append(n == 1 ? "1 marker" : "\(n) markers")
        return parts.joined(separator: " · ")
    }

    // MARK: Markers

    private var markerStrip: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(take.markers.indices, id: \.self) { index in
                    markerTile(index)
                }
            }
            .padding(.bottom, 4)
        }
        .scrollIndicators(.automatic)
    }

    private func markerTile(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.black.opacity(0.35))
                if let image = thumbnails[index] {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .transition(.opacity)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 176, height: 99)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .animation(Motion.pick(Motion.fade, reduceMotion: reduceMotion), value: thumbnails[index] != nil)

            HStack(spacing: 4) {
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.signal)
                Text(Self.timecode(take.markers[index].seconds))
                    .font(BrandFont.mono(weight: .medium, size: 11).swiftUI)
                    .foregroundStyle(.secondary)
            }

            if isEditing, index < titles.count {
                TextField("Marker \(index + 1)", text: $titles[index])
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedMarker, equals: index)
                    .onSubmit {
                        if index + 1 < titles.count { focusedMarker = index + 1 } else { save() }
                    }
                    .accessibilityIdentifier("afterTakeMarker\(index)")
            } else {
                Text(take.markers[index].title)
                    .font(.callout)
                    .lineLimit(2)
            }
        }
        .frame(width: 176, alignment: .leading)
        // Contain, not combine: the title field has to stay reachable.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Marker \(index + 1) at \(Self.timecode(take.markers[index].seconds))")
    }

    // MARK: Actions

    private var actions: some View {
        HStack(spacing: 10) {
            if isEditing {
                Spacer()
                Button("Cancel") {
                    resetFields()
                    isEditing = false
                }
                .accessibilityIdentifier("afterTakeCancel")
                Button("Save Names", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(SessionNaming.sanitize(episode).isEmpty)
                    .accessibilityIdentifier("afterTakeSave")
            } else {
                Button {
                    openInFinalCut()
                } label: {
                    Label("Open in Final Cut", systemImage: "film")
                }
                .disabled(!hasFinalCutFile)
                .help(hasFinalCutFile ? "Import this take with its markers"
                                      : "Final Cut files are made for takes with markers or a series")
                .accessibilityIdentifier("afterTakeOpenFinalCut")

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([take.url])
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
                .accessibilityIdentifier("afterTakeShowInFinder")

                Spacer()

                Button {
                    startEditing(focus: take.markers.isEmpty ? nil : 0)
                } label: {
                    Label("Edit Names", systemImage: "pencil")
                }
                .accessibilityIdentifier("afterTakeEdit")
            }
        }
        .controlSize(.large)
    }

    private var hasFinalCutFile: Bool {
        FileManager.default.fileExists(atPath: take.sidecarURL.path)
    }

    private func openInFinalCut() {
        NSWorkspace.shared.open(take.sidecarURL)
    }

    private func startEditing(focus: Int?) {
        resetFields()
        error = nil
        isEditing = true
        if let focus {
            // After the fields exist.
            DispatchQueue.main.async { focusedMarker = focus }
        }
    }

    private func resetFields() {
        series = take.series
        episode = take.episode
        titles = take.markers.map(\.title)
    }

    private func save() {
        guard isEditing else { return }
        Task {
            do {
                let saved = try await vm.renameTake(take, series: series, episode: episode, markerTitles: titles)
                vm.presentedTake = saved
                isEditing = false
                error = nil
            } catch {
                self.error = "Couldn't rename: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Loading

    private func load() async {
        let asset = AVURLAsset(url: take.url)
        duration = try? await asset.load(.duration).seconds
        fileSize = (try? take.url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.maximumSize = CGSize(width: 352, height: 198)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        for (index, marker) in take.markers.enumerated() {
            guard !Task.isCancelled else { return }
            let time = CMTime(seconds: marker.seconds, preferredTimescale: 600)
            if let image = try? await generator.image(at: time).image {
                thumbnails[index] = image
            }
        }
    }

    static func timecode(_ seconds: Double) -> String {
        let t = Int(seconds)
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t % 3600 / 60, t % 60)
                         : String(format: "%02d:%02d", t / 60, t % 60)
    }
}
