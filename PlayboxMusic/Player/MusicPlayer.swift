import AVFoundation
import Combine
import MediaPlayer
import VLCKit

/// Plays local audio with VLCKit (FLAC, Opus, Ogg, APE and more) and
/// integrates with the lock screen and Control Center.
@MainActor
final class MusicPlayer: ObservableObject {
    @Published private(set) var current: Track?
    @Published private(set) var isPlaying = false
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var queue: [Track] = []
    @Published private(set) var index = 0

    private var player = VLCMediaPlayer()
    private var pollTask: Task<Void, Never>?
    private var startedPlaying = false
    private var userPaused = false

    var progress: Double { duration > 0 ? min(max(elapsed / duration, 0), 1) : 0 }
    var hasNext: Bool { index + 1 < queue.count }

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        configureRemoteCommands()
    }

    func play(_ tracks: [Track], startAt start: Int) {
        guard tracks.indices.contains(start) else { return }
        queue = tracks
        index = start
        startCurrent()
    }

    func togglePlayback() {
        guard current != nil else { return }
        if player.isPlaying {
            userPaused = true
            player.pause()
        } else {
            userPaused = false
            if player.state == .stopped { startCurrent() } else { player.play() }
        }
        refresh()
    }

    func next() {
        guard hasNext else { return }
        index += 1
        startCurrent()
    }

    func previous() {
        if elapsed > 3 || index == 0 {
            seek(to: 0)
        } else {
            index -= 1
            startCurrent()
        }
    }

    func seek(to fraction: Double) {
        guard duration > 0 else { return }
        player.position = min(max(fraction, 0), 0.999)
        elapsed = fraction * duration
        updateNowPlaying()
    }

    private func startCurrent() {
        guard queue.indices.contains(index) else { return }
        let track = queue[index]
        pollTask?.cancel()
        player.stop()
        // A fresh player avoids late callbacks from the previous input.
        player = VLCMediaPlayer()
        guard let media = VLCMedia(url: track.url) else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        player.media = media
        current = track
        elapsed = 0
        duration = 0
        startedPlaying = false
        userPaused = false
        player.play()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            }
        }
        updateNowPlaying()
    }

    private func refresh() {
        elapsed = Double(max(0, player.time.intValue)) / 1000
        duration = Double(max(0, player.media?.length.intValue ?? 0)) / 1000
        isPlaying = player.isPlaying
        if isPlaying { startedPlaying = true }

        // VLC reports a stopped input when a track reaches its end.
        if startedPlaying, !userPaused, player.state == .stopped {
            startedPlaying = false
            if hasNext {
                next()
                return
            }
            isPlaying = false
            elapsed = 0
        }
        updateNowPlaying()
    }

    private func updateNowPlaying() {
        guard let current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: current.title,
            MPMediaItemPropertyAlbumTitle: current.folder,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in if self?.isPlaying == false { self?.togglePlayback() } }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in if self?.isPlaying == true { self?.togglePlayback() } }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayback() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in
                guard let self, self.duration > 0 else { return }
                self.seek(to: event.positionTime / self.duration)
            }
            return .success
        }
    }
}
