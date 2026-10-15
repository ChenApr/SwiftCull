import AVFoundation
import AppKit
import SwiftUI

struct LivePhotoTrimTimeline: View {
    @Binding var clip: LivePhotoClip
    let sourceURL: URL
    let videoDuration: Double
    let windowStart: Double
    let isDisabled: Bool
    let onSeek: (Double) -> Void
    let onRecenter: (Double) -> Void

    @State private var thumbnails: [NSImage?] = []

    private let frameCount = 12
    private let trackHeight: CGFloat = 72
    private var windowDuration: Double { min(10, max(videoDuration, 0.5)) }

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            let startX = position(for: clip.start, width: width)
            let endX = position(for: clip.end, width: width)
            let coverX = position(for: clip.cover, width: width)

            ZStack(alignment: .topLeading) {
                HStack(spacing: 1) {
                    ForEach(0..<frameCount, id: \.self) { index in
                        Group {
                            if thumbnails.indices.contains(index), let image = thumbnails[index] {
                                Image(nsImage: image)
                                    .resizable()
                                    .scaledToFill()
                            } else {
                                Rectangle().fill(.gray.opacity(0.25))
                            }
                        }
                        .frame(width: (width - CGFloat(frameCount - 1)) / CGFloat(frameCount),
                               height: trackHeight)
                        .clipped()
                    }
                }
                .frame(width: width, height: trackHeight)
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture(coordinateSpace: .named("live-photo-timeline"))
                    .onEnded { value in
                        let time = time(at: value.location.x, width: width)
                        if (clip.start...clip.end).contains(time) {
                            setCover(time)
                        } else {
                            onRecenter(time)
                        }
                    })

                Rectangle()
                    .fill(.black.opacity(0.6))
                    .frame(width: startX, height: trackHeight)
                    .allowsHitTesting(false)
                Rectangle()
                    .fill(.black.opacity(0.6))
                    .frame(width: max(0, width - endX), height: trackHeight)
                    .offset(x: endX)
                    .allowsHitTesting(false)

                Rectangle()
                    .stroke(Color.yellow, lineWidth: 3)
                    .frame(width: max(0, endX - startX), height: trackHeight)
                    .offset(x: startX)
                    .allowsHitTesting(false)

                trimHandle("起点", x: startX, width: width) { time in
                    clip.start = min(max(time, windowStart, clip.end - 3), clip.end - 0.5)
                    clip.cover = min(max(clip.cover, clip.start), clip.end - 0.1)
                    onSeek(clip.start)
                }

                trimHandle("终点", x: endX, width: width) { time in
                    clip.end = max(min(time, windowStart + windowDuration,
                                       videoDuration, clip.start + 3), clip.start + 0.5)
                    clip.cover = min(max(clip.cover, clip.start), clip.end - 0.1)
                    onSeek(clip.end - 0.1)
                }

                Rectangle()
                    .fill(.white)
                    .frame(width: 3, height: trackHeight)
                    .overlay(alignment: .top) {
                        Circle()
                            .fill(.white)
                            .frame(width: 11, height: 11)
                            .offset(y: -5)
                    }
                    .frame(width: 22, height: trackHeight)
                    .contentShape(Rectangle())
                    .offset(x: coverX - 11)
                    .shadow(color: .black.opacity(0.8), radius: 2)
                    .gesture(DragGesture(minimumDistance: 0,
                                         coordinateSpace: .named("live-photo-timeline"))
                        .onChanged { value in
                            setCover(time(at: value.location.x, width: width))
                        })
                    .accessibilityLabel("封面画面")
                    .accessibilityValue(timeLabel(clip.cover))
                    .accessibilityAdjustableAction { direction in
                        setCover(clip.cover + (direction == .increment ? 0.1 : -0.1))
                    }
                    .help("拖动选择封面画面")
            }
            .frame(width: width, height: trackHeight)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .coordinateSpace(name: "live-photo-timeline")
            .opacity(isDisabled ? 0.5 : 1)
            .allowsHitTesting(!isDisabled)
        }
        .frame(height: trackHeight)
        .task(id: WindowID(start: windowStart, duration: videoDuration)) {
            await loadThumbnails()
        }
    }

    private func trimHandle(_ name: String, x: CGFloat, width: CGFloat,
                            onChange: @escaping (Double) -> Void) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(.yellow)
            .frame(width: 14, height: trackHeight)
            .overlay {
                Capsule()
                    .fill(.black.opacity(0.55))
                    .frame(width: 2, height: 19)
            }
            .contentShape(Rectangle())
            .offset(x: x - 7)
            .gesture(DragGesture(minimumDistance: 0,
                                 coordinateSpace: .named("live-photo-timeline"))
                .onChanged { value in
                    onChange(time(at: value.location.x, width: width))
                })
            .accessibilityLabel("片段\(name)")
            .accessibilityValue(timeLabel(name == "起点" ? clip.start : clip.end))
            .accessibilityAdjustableAction { direction in
                let current = name == "起点" ? clip.start : clip.end
                onChange(current + (direction == .increment ? 0.1 : -0.1))
            }
            .help("拖动调整片段\(name)")
    }

    private func setCover(_ time: Double) {
        clip.cover = min(max(time, clip.start), clip.end - 0.1)
        onSeek(clip.cover)
    }

    private func position(for time: Double, width: CGFloat) -> CGFloat {
        CGFloat(min(max((time - windowStart) / windowDuration, 0), 1)) * width
    }

    private func time(at x: CGFloat, width: CGFloat) -> Double {
        windowStart + Double(min(max(x / width, 0), 1)) * windowDuration
    }

    private func timeLabel(_ seconds: Double) -> String {
        String(format: "%02d:%04.1f", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60))
    }

    @MainActor
    private func loadThumbnails() async {
        guard videoDuration > 0 else { return }
        thumbnails = Array(repeating: nil, count: frameCount)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: sourceURL))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 160, height: 100)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.2, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.2, preferredTimescale: 600)

        for index in 0..<frameCount {
            guard !Task.isCancelled else { return }
            let time = windowStart + (Double(index) + 0.5) / Double(frameCount) * windowDuration
            if let (image, _) = try? await generator.image(
                at: CMTime(seconds: time, preferredTimescale: 600)) {
                guard !Task.isCancelled else { return }
                thumbnails[index] = NSImage(cgImage: image, size: .zero)
            }
        }
    }

    private struct WindowID: Hashable {
        let start: Double
        let duration: Double
    }
}
