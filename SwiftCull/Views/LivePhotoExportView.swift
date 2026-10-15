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
    @State private var clip = LivePhotoClip(start: 0, end: 0, cover: 0)
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

            HStack(alignment: .top, spacing: 0) {
                VideoPlayer(player: player)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.black)

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text(photo.displayName)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)

                        Group {
                            Text("片段")
                                .font(.subheadline.weight(.semibold))
                            Button("以当前画面为中心选取 3 秒") {
                                clip = .centered(on: previewTime, videoDuration: duration)
                                seek(to: clip.cover)
                            }
                            .disabled(duration < 0.5)

                            Stepper(value: startBinding, in: 0...max(0, duration), step: 0.1) {
                                HStack {
                                    Text("起点")
                                    Spacer()
                                    Text(timeLabel(clip.start)).monospacedDigit()
                                }
                            }
                            Stepper(value: endBinding, in: 0...max(0, duration), step: 0.1) {
                                HStack {
                                    Text("终点")
                                    Spacer()
                                    Text(timeLabel(clip.end)).monospacedDigit()
                                }
                            }
                            Text("片段时长 \(timeLabel(clip.duration))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .disabled(duration < 0.5 || isExporting)

                        Divider()

                        Group {
                            Text("封面")
                                .font(.subheadline.weight(.semibold))
                            Slider(value: $clip.cover, in: clip.start...max(clip.start, clip.end - 0.1))
                                .onChange(of: clip.cover) { _, value in seek(to: value) }
                            HStack {
                                Text(timeLabel(clip.cover)).monospacedDigit()
                                Spacer()
                                Button("使用当前画面") {
                                    clip.cover = min(max(previewTime, clip.start), clip.end - 0.1)
                                }
                            }
                            .font(.caption)
                        }
                        .disabled(duration < 0.5 || isExporting)

                        Divider()

                        Picker("保存到", selection: $destination) {
                            ForEach(Destination.allCases, id: \.self) { option in
                                Text(option.rawValue).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                        .disabled(isExporting)

                        if isExporting {
                            ProgressView("正在生成实况照片…")
                        } else {
                            Button {
                                export()
                            } label: {
                                Label(destination == .folder ? "选择目录并导出…" : "添加到照片",
                                      systemImage: destination == .folder ? "square.and.arrow.up" : "photo.on.rectangle")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(duration < 0.5)
                        }

                        if let errorMessage {
                            Text(errorMessage)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                        if let resultMessage {
                            Text(resultMessage)
                                .font(.caption)
                            if let exportedPair {
                                Button("在 Finder 中显示") {
                                    NSWorkspace.shared.activateFileViewerSelecting(
                                        [exportedPair.imageURL, exportedPair.videoURL])
                                }
                                .font(.caption)
                            }
                        }
                    }
                    .padding(20)
                }
                .frame(width: 310)
            }
        }
        .frame(minWidth: 800, minHeight: 540)
        .task { await prepare() }
        .onDisappear {
            exportTask?.cancel()
            if let timeObserver { player.removeTimeObserver(timeObserver) }
            player.pause()
        }
    }

    private var startBinding: Binding<Double> {
        Binding(get: { clip.start }, set: { value in
            clip.start = min(max(value, 0), clip.end - 0.5)
            clip.end = min(clip.end, clip.start + 3)
            clip.cover = min(max(clip.cover, clip.start), clip.end - 0.1)
        })
    }

    private var endBinding: Binding<Double> {
        Binding(get: { clip.end }, set: { value in
            clip.end = max(min(value, duration, clip.start + 3), clip.start + 0.5)
            clip.cover = min(max(clip.cover, clip.start), clip.end - 0.1)
        })
    }

    private func timeLabel(_ seconds: Double) -> String {
        String(format: "%.1f 秒", max(0, seconds))
    }

    private func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    @MainActor
    private func prepare() async {
        guard let path = photo.movPath else { return }
        do {
            duration = try await LivePhotoService.videoDuration(at: URL(fileURLWithPath: path))
            clip = .centered(on: initialTime, videoDuration: duration)
            player.replaceCurrentItem(with: AVPlayerItem(url: URL(fileURLWithPath: path)))
            seek(to: clip.cover)
            timeObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main
            ) { time in
                Task { @MainActor in
                    previewTime = time.seconds.isFinite ? time.seconds : 0
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func export() {
        guard let path = photo.movPath else { return }
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
