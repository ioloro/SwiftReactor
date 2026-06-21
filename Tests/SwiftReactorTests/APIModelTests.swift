import Foundation
import Testing
@testable import SwiftReactor

@Suite("API model round-trips match JS SDK wire format")
struct APIModelTests {

    @Test func sessionResponseDecodesNestedCapabilities() throws {
        let json = """
        {
          "session_id": "abc-123",
          "state": "ACTIVE",
          "cluster": "us-west-1",
          "model": { "name": "helios", "version": "0.4.2" },
          "server_info": { "server_version": "2025.11.07" },
          "selected_transport": { "protocol": "webrtc", "version": "1.0" },
          "capabilities": {
            "protocol_version": "1.0",
            "tracks": [
              { "name": "main_video", "kind": "video", "direction": "recvonly" }
            ],
            "commands": [
              { "name": "set_prompt", "description": "Update the live prompt." }
            ],
            "emission_fps": 24.0
          }
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder.reactor.decode(SessionResponse.self, from: json)
        #expect(decoded.sessionId == "abc-123")
        #expect(decoded.selectedTransport?.protocol == "webrtc")
        #expect(decoded.capabilities?.tracks.first?.name == "main_video")
        #expect(decoded.capabilities?.emissionFPS == 24.0)
    }

    @Test func iceServersResponseDecodesCredentials() throws {
        let json = """
        {
          "ice_servers": [
            { "uris": ["stun:stun.l.google.com:19302"] },
            {
              "uris": ["turn:turn.reactor.inc:3478?transport=udp"],
              "credentials": { "username": "user", "password": "pw" }
            }
          ]
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder.reactor.decode(IceServersResponse.self, from: json)
        #expect(decoded.iceServers.count == 2)
        #expect(decoded.iceServers[1].credentials?.username == "user")
    }

    @Test func envelopeRoundTripsApplicationScope() throws {
        let payload = AnyCodable(["prompt": "a sunset"])
        let data = try EnvelopeEncoder.encodeCommand(
            "set_prompt",
            data: payload,
            scope: .application,
            uploads: nil
        )
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["scope"] as? String == "application")
        let inner = object?["data"] as? [String: Any]
        #expect(inner?["type"] as? String == "set_prompt")
        let innerData = inner?["data"] as? [String: Any]
        #expect(innerData?["prompt"] as? String == "a sunset")
    }

    @Test func iceCandidateDropsNilFields() throws {
        let candidate = IceCandidate(
            candidate: "candidate:1 1 udp 1 192.0.2.1 5000 typ host",
            sdpMid: "0",
            sdpMLineIndex: 0
        )
        let data = try JSONEncoder.reactor.encode(candidate)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["candidate"] as? String == candidate.candidate)
        #expect(object?["sdp_mid"] as? String == "0")
        #expect(object?["sdp_mline_index"] as? Int == 0)
    }
}
