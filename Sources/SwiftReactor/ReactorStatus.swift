import Foundation

/// High-level lifecycle of a ``Reactor`` instance. Drives every
/// SDK-level precondition (`sendCommand` requires `.ready`, etc.) and
/// is the primary thing SwiftUI views observe via `@Observable`.
///
/// ```
///   .disconnected ──connect──▶ .connecting ──session created──▶ .waiting
///                                                                  │
///                                       transport.connected ◀──────┘
///                                                  │
///                                                  ▼
///                                              .ready ──disconnect──▶ .disconnected
/// ```
public enum ReactorStatus: String, Sendable, Equatable {
    /// No active session — the initial state and the state every
    /// `disconnect` returns to. `connect` is only valid from here.
    case disconnected
    /// `connect` is running: a session is being created with the
    /// coordinator. No commands accepted yet.
    case connecting
    /// Session created and waiting for capabilities + selected
    /// transport. The coordinator is polling for GPU readiness; the
    /// transport hasn't started its ICE handshake yet.
    case waiting
    /// WebRTC transport is connected, capabilities are known, recvonly
    /// tracks have been resumed. `sendCommand`, `uploadFile`, and the
    /// typed model wrappers are now valid.
    case ready
}

/// Lifecycle of the underlying ``ReactorTransport`` (WebRTC in prod,
/// `MockTransport` in tests). Surfaced for callers that want fine-
/// grained transport observation; most consumers should watch
/// ``ReactorStatus`` instead, which already folds this in.
public enum TransportStatus: String, Sendable, Equatable {
    /// No transport session — either never started or torn down.
    case disconnected
    /// ICE / SDP handshake in flight.
    case connecting
    /// Peer connection established, data channels open.
    case connected
    /// Transport hit an unrecoverable error and gave up. `Reactor`
    /// downgrades to ``ReactorStatus/disconnected`` and surfaces a
    /// ``ReactorError`` via ``Reactor/lastError``.
    case error
}
