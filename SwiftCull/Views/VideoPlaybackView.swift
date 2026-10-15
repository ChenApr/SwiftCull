import AVKit
import SwiftUI

struct VideoPlaybackView: View {
    @ObservedObject var controller: VideoPlaybackController
    let displayName: String
    let onLivePhoto: () -> Void
    let onExit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            playbackHeader
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.bar)

            Color.black
                .overlay {
                    if let player = controller.player {
                        NativeVideoPlayer(player: player)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 20)
                    } else {
                        ProgressView()
                            .tint(.white)
                    }
            }
        }
    }

    private var playbackHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "play.rectangle.fill")
                Text(displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 8)

                Button(action: onLivePhoto) {
                    Label("制作实况照片…", systemImage: "livephoto")
                }

                Button(action: onExit) {
                    Label("退出播放模式", systemImage: "xmark")
                }
                .help("退出播放模式 (V / Esc)")
            }

            Text("Space 播放/暂停 · ← → 跳转 · ⇧← ⇧→ 逐帧 · ↑ ↓ 音量")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

private struct NativeVideoPlayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}
