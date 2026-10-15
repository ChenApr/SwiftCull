import AVFoundation
import Combine
import Foundation

@MainActor
final class VideoPlaybackController: ObservableObject {
    @Published private(set) var player: AVPlayer?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0

    private var loadedURL: URL?
    private var timeObserver: Any?

    func load(_ url: URL) {
        guard loadedURL != url else { return }
        stop()

        let player = AVPlayer(url: url)
        self.player = player
        loadedURL = url
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main
        ) { [weak self, weak player] time in
            MainActor.assumeIsolated {
                guard let self, self.player === player else { return }
                self.currentTime = time.seconds.isFinite ? time.seconds : 0
                self.isPlaying = player?.timeControlStatus == .playing
                if let seconds = player?.currentItem?.duration.seconds, seconds.isFinite {
                    self.duration = seconds
                }
            }
        }
        player.play()
        isPlaying = true
    }

    func stop() {
        player?.pause()
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        player = nil
        loadedURL = nil
        isPlaying = false
        currentTime = 0
        duration = 0
    }

    func togglePlayPause() {
        guard let player else { return }
        if player.timeControlStatus == .playing {
            player.pause()
            isPlaying = false
        } else {
            if duration > 0, currentTime >= duration - 0.1 {
                player.seek(to: .zero)
            }
            player.play()
            isPlaying = true
        }
    }

    func seek(by seconds: Double) {
        guard let player else { return }
        let limit = duration > 0 ? duration : Double.greatestFiniteMagnitude
        let target = min(max(currentTime + seconds, 0), limit)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func stepFrame(by count: Int) {
        guard let player, let item = player.currentItem else { return }
        player.pause()
        isPlaying = false
        item.step(byCount: count)
    }
}
