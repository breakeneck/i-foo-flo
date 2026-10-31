// Player — AVPlayer wrapper with periodic time observation.

import AVFoundation

@MainActor
final class Player: NSObject {
    let av = AVPlayer()
    var onTime: ((TimeInterval, TimeInterval) -> Void)?
    var onItemEnd: (() -> Void)?
    private var timeObs: Any?
    private var statusObs: NSKeyValueObservation?

    override init() {
        super.init()
        av.actionAtItemEnd = .pause
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.onItemEnd?() }
        }
    }

    func play(_ track: Track) {
        if let obs = timeObs { av.removeTimeObserver(obs) }
        let item = AVPlayerItem(url: track.url)
        statusObs = item.observe(\.status, options: [.new]) { it, _ in
            DispatchQueue.main.async {
                print("item status: \(it.status.rawValue) error: \(String(describing: it.error))")
            }
        }
        av.replaceCurrentItem(with: item)
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObs = av.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] t in
            Task { @MainActor in
                guard let self else { return }
                let cur = CMTimeGetSeconds(t)
                let dur = CMTimeGetSeconds(self.av.currentItem?.duration ?? .zero)
                self.onTime?(cur.isFinite ? cur : 0, dur.isFinite ? dur : 0)
            }
        }
        av.play()
    }

    func toggle() {
        if av.timeControlStatus == .playing { av.pause() } else { av.play() }
    }

    var isPlaying: Bool { av.timeControlStatus == .playing }

    func seek(_ sec: TimeInterval) {
        av.seek(to: CMTime(seconds: sec, preferredTimescale: 600))
    }

    var volume: Float {
        get { av.volume }
        set { av.volume = max(0, min(1, newValue)) }
    }
}