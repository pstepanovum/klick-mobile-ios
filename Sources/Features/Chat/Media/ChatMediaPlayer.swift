import SwiftUI
import AVFoundation
import AVKit

@MainActor
final class MediaPlayerBox: ObservableObject {
    let player = AVPlayer()
    var onProgress: ((Double, Double) -> Void)?

    @Published private(set) var isPlaying = false

    private var timeObserver: Any?
    private var currentURL: URL?
    private weak var pipController: AVPictureInPictureController?
    private var activeRate: Float = 1

    deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
    }

    func load(url: URL, rate: Float) {
        activeRate = rate
        guard currentURL != url else {
            setRate(rate)
            return
        }
        currentURL = url
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        addTimeObserverIfNeeded()
        player.playImmediately(atRate: rate)
        isPlaying = true
    }

    func toggle() {
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.playImmediately(atRate: activeRate)
            isPlaying = true
        }
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentURL = nil
        isPlaying = false
    }

    func setRate(_ rate: Float) {
        activeRate = rate
        if isPlaying {
            player.rate = rate
        }
    }

    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
    }

    func bindPiP(_ controller: AVPictureInPictureController?) {
        pipController = controller
    }

    func startPictureInPicture() {
        pipController?.startPictureInPicture()
    }

    private func addTimeObserverIfNeeded() {
        guard timeObserver == nil else { return }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                let current = CMTimeGetSeconds(time)
                let total = CMTimeGetSeconds(self.player.currentItem?.duration ?? .zero)
                self.isPlaying = self.player.rate != 0
                self.onProgress?(current.isFinite ? current : 0, total.isFinite ? total : 0)
            }
        }
    }
}

struct VideoCanvasView: UIViewRepresentable {
    let player: AVPlayer
    let onPiPReady: (AVPictureInPictureController?) -> Void

    func makeUIView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.configure(player: player)
        context.coordinator.bindPiPIfPossible(for: view.playerLayer)
        return view
    }

    func updateUIView(_ uiView: PlayerContainerView, context: Context) {
        uiView.configure(player: player)
        context.coordinator.bindPiPIfPossible(for: uiView.playerLayer)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onPiPReady: onPiPReady)
    }

    final class Coordinator {
        private let onPiPReady: (AVPictureInPictureController?) -> Void
        private var pipController: AVPictureInPictureController?

        init(onPiPReady: @escaping (AVPictureInPictureController?) -> Void) {
            self.onPiPReady = onPiPReady
        }

        func bindPiPIfPossible(for layer: AVPlayerLayer) {
            guard AVPictureInPictureController.isPictureInPictureSupported() else {
                onPiPReady(nil)
                return
            }
            if pipController == nil {
                pipController = AVPictureInPictureController(playerLayer: layer)
            }
            onPiPReady(pipController)
        }
    }
}

final class PlayerContainerView: UIView {
    let playerLayer = AVPlayerLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.addSublayer(playerLayer)
        playerLayer.videoGravity = .resizeAspect
        backgroundColor = .black
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.frame = bounds
    }

    func configure(player: AVPlayer) {
        if playerLayer.player !== player {
            playerLayer.player = player
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
