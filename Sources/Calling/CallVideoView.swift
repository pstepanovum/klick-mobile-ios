import SwiftUI
import LiveKit

/// SwiftUI wrapper around LiveKit's `VideoView` for rendering a single video track.
struct CallVideoView: UIViewRepresentable {
    let track: VideoTrack?
    var fill: Bool = true

    func makeUIView(context: Context) -> VideoView {
        let view = VideoView()
        view.layoutMode = fill ? .fill : .fit
        view.track = track
        return view
    }

    func updateUIView(_ uiView: VideoView, context: Context) {
        if uiView.track !== track { uiView.track = track }
    }
}
