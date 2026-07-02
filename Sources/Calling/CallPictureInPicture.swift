import AVKit
import Combine
import LiveKit
import UIKit

/// System picture-in-picture for video calls: while a remote video track is live, an
/// AVPictureInPictureController is armed with an AVPictureInPictureVideoCallViewController
/// whose AVSampleBufferDisplayLayer is fed by a custom LiveKit VideoRenderer. With
/// `canStartPictureInPictureAutomaticallyFromInline`, backgrounding the app mid-video-call
/// pops the remote feed into the system PiP window (audio keeps running via CallKit/VoIP).
///
/// Known iOS limit: without the multitasking-camera-access entitlement the LOCAL camera
/// pauses while backgrounded — remote video + audio continue. Voice-only calls (no remote
/// video) never arm PiP.
@MainActor
final class CallPictureInPicture: NSObject {
    static let shared = CallPictureInPicture()

    private var pipController: AVPictureInPictureController?
    private var contentViewController: AVPictureInPictureVideoCallViewController?
    private var renderView: PiPSampleBufferView?
    private var sourceView: UIView?
    private let frameRenderer = PiPFrameRenderer()
    private var track: VideoTrack?
    private var trackSubscription: AnyCancellable?

    /// Start following the call's remote video track. Called once at app launch; PiP is
    /// armed whenever remote video is on screen and torn down when it goes away.
    func start() {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        guard trackSubscription == nil else { return }
        trackSubscription = CallService.shared.$remoteVideoTrack
            .receive(on: DispatchQueue.main)
            .sink { [weak self] track in self?.setTrack(track) }
    }

    private func setTrack(_ newTrack: VideoTrack?) {
        guard track !== newTrack else { return }
        if let track {
            track.remove(videoRenderer: frameRenderer)
        }
        track = newTrack
        if let newTrack {
            armIfNeeded()
            newTrack.add(videoRenderer: frameRenderer)
        } else {
            disarm()
        }
    }

    /// Build the PiP plumbing once per video session. The content view controller hosts
    /// the sample-buffer layer; the (invisible) source view only anchors the system's
    /// morph animation and must live in the window hierarchy.
    private func armIfNeeded() {
        guard pipController == nil else { return }
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow })
            .first else { return }

        let source = UIView(frame: CGRect(x: window.bounds.midX, y: window.bounds.midY, width: 1, height: 1))
        source.isUserInteractionEnabled = false
        source.backgroundColor = .clear
        window.addSubview(source)
        sourceView = source

        let controller = AVPictureInPictureVideoCallViewController()
        controller.preferredContentSize = CGSize(width: 9, height: 16)
        let view = PiPSampleBufferView(frame: controller.view.bounds)
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controller.view.addSubview(view)
        renderView = view
        contentViewController = controller
        frameRenderer.onFrame = { [weak self] sampleBuffer, dimensions, rotation in
            Task { @MainActor in self?.display(sampleBuffer, dimensions: dimensions, rotation: rotation) }
        }

        let contentSource = AVPictureInPictureController.ContentSource(
            activeVideoCallSourceView: source,
            contentViewController: controller
        )
        let pip = AVPictureInPictureController(contentSource: contentSource)
        pip.canStartPictureInPictureAutomaticallyFromInline = true
        pip.delegate = self
        pipController = pip
        APIClient.mobileDiagnostic(event: "pip.armed")
    }

    private func disarm() {
        guard pipController != nil else { return }
        frameRenderer.onFrame = nil
        pipController?.stopPictureInPicture()
        pipController = nil
        contentViewController = nil
        renderView = nil
        sourceView?.removeFromSuperview()
        sourceView = nil
        APIClient.mobileDiagnostic(event: "pip.disarmed")
    }

    private func display(_ sampleBuffer: CMSampleBuffer, dimensions: Dimensions, rotation: VideoRotation) {
        guard let renderView else { return }
        renderView.apply(rotation: rotation)
        if renderView.displayLayer.status == .failed {
            renderView.displayLayer.flush()
        }
        renderView.displayLayer.enqueue(sampleBuffer)
        // Keep the PiP window's aspect ratio in step with the (possibly rotated) frame.
        let rotated = rotation == ._90 || rotation == ._270
        let size = rotated
            ? CGSize(width: Int(dimensions.height), height: Int(dimensions.width))
            : CGSize(width: Int(dimensions.width), height: Int(dimensions.height))
        if size.width > 0, size.height > 0, contentViewController?.preferredContentSize != size {
            contentViewController?.preferredContentSize = size
        }
    }
}

extension CallPictureInPicture: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        // Coming back from PiP: surface the full call screen again.
        Task { @MainActor in
            CallKitManager.shared.callMinimized = false
            completionHandler(true)
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        APIClient.mobileDiagnostic(event: "pip.start.failed", detail: String(describing: error))
    }
}

/// UIView whose backing layer is the AVSampleBufferDisplayLayer PiP renders into.
private final class PiPSampleBufferView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }

    private var appliedRotation: VideoRotation = ._0

    override init(frame: CGRect) {
        super.init(frame: frame)
        displayLayer.videoGravity = .resizeAspect
        backgroundColor = .black
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(rotation: VideoRotation) {
        guard rotation != appliedRotation else { return }
        appliedRotation = rotation
        let angle: CGFloat
        switch rotation {
        case ._0: angle = 0
        case ._90: angle = .pi / 2
        case ._180: angle = .pi
        case ._270: angle = -.pi / 2
        }
        displayLayer.setAffineTransform(CGAffineTransform(rotationAngle: angle))
    }
}

/// Custom LiveKit VideoRenderer: converts each remote VideoFrame to a CMSampleBuffer
/// (marked display-immediately) and hands it to the PiP layer. Runs off-main — the
/// callback hop to the main actor happens in CallPictureInPicture.
private final class PiPFrameRenderer: NSObject, VideoRenderer, @unchecked Sendable {
    private let lock = NSLock()
    private var _onFrame: ((CMSampleBuffer, Dimensions, VideoRotation) -> Void)?

    var onFrame: ((CMSampleBuffer, Dimensions, VideoRotation) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onFrame }
        set { lock.lock(); _onFrame = newValue; lock.unlock() }
    }

    // Report as a visible renderer with a healthy target size so AdaptiveStream keeps
    // delivering frames (at a reasonable resolution) while the app is backgrounded and
    // the on-screen VideoViews are gone.
    @MainActor var isAdaptiveStreamEnabled: Bool { true }
    @MainActor var adaptiveStreamSize: CGSize { CGSize(width: 1280, height: 720) }

    nonisolated func render(frame: VideoFrame) {
        guard let onFrame else { return }
        guard let sampleBuffer = frame.toCMSampleBuffer() else { return }
        // The buffers carry no timing info — tell the layer to show each one on arrival.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        onFrame(sampleBuffer, frame.dimensions, frame.rotation)
    }
}
