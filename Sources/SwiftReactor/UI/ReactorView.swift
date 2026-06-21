import SwiftUI

/// SwiftUI view that renders the model's `main_video` track once it arrives.
///
/// In the stub/no-WebRTC build, this renders a placeholder. The real
/// implementation (added with the `WebRTC` dependency) will host an
/// `RTCMTLVideoView` and attach the incoming `RTCVideoTrack`.
public struct ReactorView: View {
    @State private var trackName: String?
    public let reactor: Reactor
    public var trackPreference: String

    public init(reactor: Reactor, trackPreference: String = "main_video") {
        self.reactor = reactor
        self.trackPreference = trackPreference
    }

    public var body: some View {
        ZStack {
            Color.black
            if let trackName {
                VStack(spacing: 8) {
                    Text("Receiving \(trackName)")
                        .foregroundStyle(.white)
                    Text("(Real video rendering arrives with the WebRTC dependency.)")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                }
            } else {
                Text("Waiting for \(trackPreference)…")
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .task(id: ObjectIdentifier(reactor)) {
            for await event in reactor.events {
                if case let .trackReceived(name, _) = event, name == trackPreference {
                    trackName = name
                }
            }
        }
    }
}
