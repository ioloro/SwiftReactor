import SwiftUI
import OSLog
@preconcurrency import WebRTC

private let viewLog = Logger(subsystem: "com.ioloro.SwiftReactor", category: "view")

/// SwiftUI view that renders the model's `main_video` track. Listens for
/// `trackReceived(name: "main_video", …)` and attaches the `RTCVideoTrack`
/// to an `RTCMTLVideoView` host.
public struct ReactorView: View {
    public let reactor: Reactor
    public var trackPreference: String

    @State private var videoTrack: RTCVideoTrack?
    @State private var receivedSize: CGSize = .zero

    public init(reactor: Reactor, trackPreference: String = "main_video") {
        self.reactor = reactor
        self.trackPreference = trackPreference
    }

    public var body: some View {
        ZStack {
            Color.black
            if let videoTrack {
                VideoRendererRepresentable(track: videoTrack) { size in
                    viewLog.info("video-size changed: \(size.width, format: .fixed(precision: 0))×\(size.height, format: .fixed(precision: 0))")
                    Task { @MainActor in receivedSize = size }
                }
                if receivedSize == .zero {
                    Text("Track attached, awaiting first frame…")
                        .foregroundStyle(.white.opacity(0.7))
                }
            } else {
                Text("Waiting for \(trackPreference)…")
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .task(id: ObjectIdentifier(reactor)) {
            for await event in reactor.events {
                if case let .trackReceived(name, track) = event,
                   name == trackPreference,
                   let handle = track as? WebRTCVideoTrackHandle {
                    if videoTrack !== handle.track {
                        viewLog.info("attaching new video track \(name, privacy: .public)")
                        videoTrack = handle.track
                    } else {
                        viewLog.info("ignoring duplicate trackReceived for \(name, privacy: .public)")
                    }
                }
            }
        }
    }
}

#if os(iOS) || os(tvOS) || os(visionOS)
import UIKit

struct VideoRendererRepresentable: UIViewRepresentable {
    let track: RTCVideoTrack
    let onSizeChange: (CGSize) -> Void

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView()
        view.videoContentMode = .scaleAspectFill
        view.delegate = context.coordinator
        track.add(view)
        viewLog.info("UIView: track.add succeeded")
        return view
    }
    func updateUIView(_ view: RTCMTLVideoView, context: Context) {}
    static func dismantleUIView(_ view: RTCMTLVideoView, coordinator: Coordinator) {
        coordinator.detach(from: view)
    }
    func makeCoordinator() -> Coordinator { Coordinator(track: track, onSizeChange: onSizeChange) }

    final class Coordinator: NSObject, RTCVideoViewDelegate {
        let track: RTCVideoTrack
        let onSizeChange: (CGSize) -> Void
        init(track: RTCVideoTrack, onSizeChange: @escaping (CGSize) -> Void) {
            self.track = track
            self.onSizeChange = onSizeChange
        }
        func videoView(_ videoView: any RTCVideoRenderer, didChangeVideoSize size: CGSize) {
            onSizeChange(size)
        }
        func detach(from view: RTCMTLVideoView) {
            track.remove(view)
        }
    }
}
#elseif os(macOS)
import AppKit

struct VideoRendererRepresentable: NSViewRepresentable {
    let track: RTCVideoTrack
    let onSizeChange: (CGSize) -> Void

    func makeNSView(context: Context) -> RTCMTLNSVideoView {
        let view = RTCMTLNSVideoView()
        view.delegate = context.coordinator
        track.add(view)
        viewLog.info("NSView: track.add succeeded for track=\(track.trackId, privacy: .public)")
        return view
    }
    func updateNSView(_ view: RTCMTLNSVideoView, context: Context) {}
    static func dismantleNSView(_ view: RTCMTLNSVideoView, coordinator: Coordinator) {
        coordinator.detach(from: view)
    }
    func makeCoordinator() -> Coordinator { Coordinator(track: track, onSizeChange: onSizeChange) }

    final class Coordinator: NSObject, RTCVideoViewDelegate {
        let track: RTCVideoTrack
        let onSizeChange: (CGSize) -> Void
        init(track: RTCVideoTrack, onSizeChange: @escaping (CGSize) -> Void) {
            self.track = track
            self.onSizeChange = onSizeChange
        }
        func videoView(_ videoView: any RTCVideoRenderer, didChangeVideoSize size: CGSize) {
            viewLog.info("RTCVideoViewDelegate didChangeVideoSize: \(size.width, format: .fixed(precision: 0))×\(size.height, format: .fixed(precision: 0))")
            onSizeChange(size)
        }
        func detach(from view: RTCMTLNSVideoView) {
            track.remove(view)
        }
    }
}
#endif

