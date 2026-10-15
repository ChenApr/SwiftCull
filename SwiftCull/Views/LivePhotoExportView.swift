import AVKit
import SwiftUI

struct LivePhotoExportView: View {
    let photo: PhotoEntry
    let initialTime: Double

    @Environment(\.dismiss) private var dismiss
    @State private var player = AVPlayer()
    @State private var timeObserver: Any?
    @State private var duration: Double = 0
    @State private var previewTime: Double = 0
    @State private var isClipPreviewing = false
    @State private var previewStarted = false
    @State private var previewReturnTime: Double?
    @State private var previewEndTime: Double = 0
    @State private var previewToken = UUID()
    @State private var boundaryObserver: Any?
    @State private var clip = LivePhotoClip(start: 0, end: 0, cover: 0)
    @State private var timelineWindowStart: Double = 0
    @State private var destination: Destination = .folder
    @State private var exportTask: Task<Void, Never>?
    @State private var isExporting = false
    @State private var errorMessage: String?
    @State private var resultMessage: String?
    @State private var exportedPair: LivePhotoPair?

    private enum Destination: String, CaseIterable {
        case folder = "导出文件"
        case photos = "添加到照片"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("制作实况照片", systemImage: "livephoto")
                    .font(.headline)
                Spacer()
                Button("完成") { dismiss() }
                    .disabled(isExporting)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            VideoPlayer(player: player)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(photo.displayName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        recenter(on: previewTime)
                    } label: {
                        Label("在此选取片段", systemImage: "scope")
                    }
                    .disabled(duration < 0.5 || isExporting)

                    Button {
                        if isClipPreviewing {
                            stopClipPreview(restorePosition: true)
                        } else {
                            startClipPreview()
                        }
                    } label: {
                        Label(isClipPreviewing ? "停止预览" : "预览实况片段",
                              systemImage: isClipPreviewing ? "stop.fill" : "play.fill")
                    }
                    .keyboardShortcut("p", modifiers: [])
                    .help("预览当前选取的实况片段 (P)")
                    .disabled(duration < 0.5 || isExporting)
                }

                if let path = photo.movPath {
                    LivePhotoTrimTimeline(
                        clip: $clip,
                        sourceURL: URL(fileURLWithPath: path),
                        videoDuration: duration,
                        windowStart: timelineWindowStart,
                        isDisabled: duration < 0.5 || isExporting,
                        onSeek: seek,
                        onRecenter: recenter)
                }

                HStack(spacing: 12) {
                    Text(timeLabel(clip.start))
                    Spacer()
                    Text(String(format: "片段 %.1f 秒", max(0, clip.duration)))
                    Label("封面 \(timeLabel(clip.cover))", systemImage: "circle.fill")
                        .labelStyle(.titleAndIcon)
                    Spacer()
                    Text(timeLabel(clip.end))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

                Divider()

                HStack(spacing: 16) {
                    Picker("保存到", selection: $destination) {
                        ForEach(Destination.allCases, id: \.self) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 250)
                    .disabled(isExporting)

                    Spacer()

                    if isExporting {
                        ProgressView("正在生成实况照片…")
                    } else {
                        Button {
                            export()
                        } label: {
                            Label(destination == .folder ? "选择目录并导出…" : "添加到照片",
                                  systemImage: destination == .folder ? "square.and.arrow.up" : "photo.on.rectangle")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(duration < 0.5)
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if let resultMessage {
                    HStack {
                        Text(resultMessage)
                        if let exportedPair {
                            Button("在 Finder 中显示") {
                                NSWorkspace.shared.activateFileViewerSelecting(
                                    [exportedPair.imageURL, exportedPair.videoURL])
                            }
                        }
                    }
                    .font(.caption)
                }
            }
            .padding(20)
        }
        .frame(minWidth: 800, idealWidth: 920, minHeight: 640, idealHeight: 720)
        .task { await prepare() }
        .onDisappear {
            exportTask?.cancel()
            stopClipPreview(restorePosition: false)
            if let timeObserver { player.removeTimeObserver(timeObserver) }
            player.pause()
        }
    }

    private func timeLabel(_ seconds: Double) -> String {
        String(format: "%02d:%04.1f", Int(max(0, seconds)) / 60,
               max(0, seconds).truncatingRemainder(dividingBy: 60))
    }

    private func recenter(on time: Double) {
        guard duration >= 0.5 else { return }
        clip = .centered(on: time, videoDuration: duration)
        let width = min(duration, 10)
        timelineWindowStart = min(max((clip.start + clip.end - width) / 2, 0),
                                  max(0, duration - width))
        seek(to: clip.cover)
    }

    private func seek(to seconds: Double) {
        stopClipPreview(restorePosition: false)
        player.pause()
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func startClipPreview() {
        guard duration >= 0.5, clip.duration >= 0.5 else { return }
        player.pause()
        let currentTime = player.currentTime().seconds
        previewReturnTime = currentTime.isFinite ? currentTime : clip.cover
        previewEndTime = clip.end
        previewStarted = false
        isClipPreviewing = true
        previewToken = UUID()
        let token = previewToken

        boundaryObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: CMTime(seconds: clip.end, preferredTimescale: 600))],
            queue: .main
        ) {
            Task { @MainActor in
                guard previewToken == token else { return }
                stopClipPreview(restorePosition: true)
            }
        }
        player.seek(to: CMTime(seconds: clip.start, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { finished in
            Task { @MainActor in
                guard finished, isClipPreviewing, previewToken == token else { return }
                previewStarted = true
                player.play()
            }
        }
    }

    private func stopClipPreview(restorePosition: Bool) {
        guard isClipPreviewing else { return }
        previewToken = UUID()
        isClipPreviewing = false
        previewStarted = false
        player.pause()
        if let boundaryObserver {
            player.removeTimeObserver(boundaryObserver)
            self.boundaryObserver = nil
        }
        if restorePosition, let previewReturnTime {
            player.seek(to: CMTime(seconds: previewReturnTime, preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero)
        }
        previewReturnTime = nil
    }

    @MainActor
    private func prepare() async {
        guard let path = photo.movPath else { return }
        do {
            duration = try await LivePhotoService.videoDuration(at: URL(fileURLWithPath: path))
            player.replaceCurrentItem(with: AVPlayerItem(url: URL(fileURLWithPath: path)))
            recenter(on: initialTime)
            timeObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main
            ) { time in
                Task { @MainActor in
                    previewTime = time.seconds.isFinite ? time.seconds : 0
                    if isClipPreviewing, previewStarted, previewTime >= previewEndTime - 0.02 {
                        stopClipPreview(restorePosition: true)
                    }
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func export() {
        guard let path = photo.movPath else { return }
        stopClipPreview(restorePosition: true)
        let output: LivePhotoDestination
        if destination == .folder {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.prompt = "导出到此处"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            output = .folder(url)
        } else {
            output = .photos
        }

        errorMessage = nil
        resultMessage = nil
        exportedPair = nil
        isExporting = true
        let selectedClip = clip
        exportTask = Task {
            do {
                let pair = try await LivePhotoService.generate(
                    from: URL(fileURLWithPath: path), clip: selectedClip, destination: output)
                guard !Task.isCancelled else { return }
                exportedPair = pair
                if let pair {
                    resultMessage = "已导出 \(pair.imageURL.lastPathComponent) 和 \(pair.videoURL.lastPathComponent)"
                } else {
                    resultMessage = "已添加到“照片”"
                }
            } catch is CancellationError {
                // Closing the sheet cancels work in progress.
            } catch {
                errorMessage = error.localizedDescription
            }
            isExporting = false
        }
    }
}
