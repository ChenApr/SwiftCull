import AVKit
import SwiftUI

struct VideoPlaybackView: View {
    @ObservedObject var controller: VideoPlaybackController
    let displayName: String
    let onExit: () -> Void

    var body: some View {
        ZStack {
            Color.black
            if let player = controller.player {
                NativeVideoPlayer(player: player)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
        .overlay(alignment: .topLeading) {
            HStack(spacing: 8) {
                Image(systemName: "play.rectangle.fill")
                Text(displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Space 播放/暂停 · ← → 跳转 · ⇧← ⇧→ 逐帧")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(10)
            .background(.bar, in: RoundedRectangle(cornerRadius: 8))
            .padding(14)
        }
        .overlay(alignment: .topTrailing) {
            Button(action: onExit) {
                Label("退出播放模式", systemImage: "xmark")
            }
            .help("退出播放模式 (V / Esc)")
            .padding(14)
        }
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
