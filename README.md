# SwiftReactor

Native Swift client for the [Reactor](https://reactor.inc) real-time
video-generation platform. Mirrors the surface of the official
[`@reactor-team/js-sdk`](https://docs.reactor.inc/api-reference/reactor-class)
and [`reactor-sdk`](https://docs.reactor.inc/sdk-reference/python/reactor)
Python packages, plus typed wrappers for every Reactor model.

```swift
.package(url: "https://github.com/ioloro/SwiftReactor", from: "0.3.0"),
```

Minimum: macOS 14 / iOS 17, Swift 6.0, Xcode 16.

## Two layers

| Layer | Type | Use it for |
| --- | --- | --- |
| **Generic** | `Reactor`, `Reactor.sendCommand(_:payload:)` | Custom models, raw payloads, base SDK features. |
| **Model-typed** | `ReactorSession<Model>` where `Model` is `LongLiveV2`, `Helios`, `LingBot`, or `SanaStreaming` | Typed methods + state-machine guards. Wrong-model commands are a **compile** error. |

The generic layer makes no assumptions about wire schema. The typed
layer encodes every model's documented schema so renaming a parameter
key is a compile error, double-`start` is a local exception (not a
silent wire fault), and calling LingBot's `setMovement` on a LongLive
session won't even autocomplete.

## Supported models

| Model | Specialty | Typed session |
| --- | --- | --- |
| [LongLive-2.0](https://docs.reactor.inc/model-api-reference/longlive-v2/overview) | Real-time multi-shot video; seamless shot changes + hard cuts, 48-chunk per-scene budget | `ReactorSession<LongLiveV2>` |
| [Helios](https://docs.reactor.inc/model-api-reference/helios/overview) | Interactive real-time streaming with image-conditioned prompts, schedulable prompt changes, optional 2x/4x SR | `ReactorSession<Helios>` |
| [LingBot](https://docs.reactor.inc/model-api-reference/lingbot/overview) | Action-controlled world generation; persistent movement + look inputs (joystick-style) | `ReactorSession<LingBot>` |
| [SANA-Streaming](https://docs.reactor.inc/model-api-reference/sana-streaming/overview) | Real-time video-to-video editing with anchor re-grounding | `ReactorSession<SanaStreaming>` |

## Quickstart

```swift
import SwiftReactor

// At app launch — once.
Reactor.configure(jwt: .provider {
    try await myBackend.mintReactorJWT()
})

// Anywhere — one line from zero to a connected, typed session.
let session = try await ReactorSession<LongLiveV2>.connect()
try await session.setShot(prompt: "wide third-person golf shot")
try await session.start()
```

That's the whole flow. Everything below this point is reference
material — different auth modes, the four model wrappers, the
generic layer for unsupported models, and the demo app.

Both `Reactor` and every typed session are `@MainActor @Observable`,
so `status`, `snapshot`, and `lastCommandError` track in SwiftUI views
with no extra plumbing.

## Auth (`JWTSource`)

The SDK calls into a `JWTSource` on every coordinator HTTP request.
Three patterns, in order of how safe they are to ship in client
binaries:

```swift
// 1. Backend mint — recommended. Your backend holds the API key.
Reactor.configure(jwt: .provider {
    try await myBackend.mintReactorJWT()
})

// 2. Pre-minted token (string literal is shorthand for .staticToken).
let session = try await ReactorSession<LongLiveV2>.connect(jwt: "eyJhbGci…")

// 3. Per-call override — useful for tests / scoped credentials.
let session = try await ReactorSession<LongLiveV2>.connect(jwt: .provider { … })
```

> 🚨 **Don't ship the `rk_…` API key with a client binary.** Anyone who
> can download the binary can extract the key and burn your quota.
>
> For local development (sample apps, CLIs, internal tools) where you
> control deployment, `SwiftReactorDemoSupport` ships a
> `DevJWTMinter.fetchJWT(apiKey:)` helper. It's in a separate target
> on purpose — using it requires adding the dependency, which makes
> the unsafe path loud in `Package.swift` diffs and in code review.
> See the [demo app](Examples/SwiftReactorDemo/) for the pattern.

## Picking a model

```swift
let reactor = Reactor(model: .longLiveV2)      // longlive-v2
let reactor = Reactor(model: .helios)          // helios
let reactor = Reactor(model: .lingbot)         // lingbot
let reactor = Reactor(model: .sanaStreaming)   // sana-streaming
let reactor = Reactor(model: .custom("future-model-v9"))
```

Each typed session does this internally — you only need `Reactor` +
`ReactorModel` directly for custom models without a typed wrapper.

## Typed sessions: one class, four models

There's a single typed session class — `ReactorSession<Model>` —
parameterised by one of the four model namespaces (`LongLiveV2`,
`Helios`, `LingBot`, `SanaStreaming`). The per-model commands live
in constrained extensions, so:

```swift
let session = try await ReactorSession<LongLiveV2>.connect()
try await session.setShot(prompt: "…")     // ✅ LongLive command, exists
try await session.setMovement(.forward)    // ❌ COMPILE error — wrong model
```

That's the safety net: you can't call LingBot's `setMovement` on a
LongLive session even if you forget which session you have, because
the method literally doesn't exist on that type.

### LongLive-v2

```swift
let session = try await ReactorSession<LongLiveV2>.connect()
try await session.setShot(prompt: "wide third-person golf shot")
try await session.start()
try await session.scheduleShot(prompt: "ball mid-flight", atSessionChunk: 8)
try await session.sceneCut(prompt: "next hole, aerial flyover")
```

What the wrapper enforces:

1. **Wire keys.** `ScheduleShotParams.at_session_chunk`, never
   `session_chunk`. Renaming is a compile error.
2. **`start()` is once per run.** A second call while `hasStartedRun`
   throws `LongLiveV2.LocalError.alreadyStarted`.
3. **Auto-reset on completion.** `generation_complete` locks the
   session server-side until `reset`. The wrapper auto-fires it (opt
   out via `ReactorSession<LongLiveV2>(autoResetOnComplete: false)`).
4. **`command_error` never silent.** Typed `onCommandError` callback +
   mirrored `lastCommandError`.
5. **Snapshot cleared on disconnect.** `snapshot` returns to `nil` so
   reconnects can't see stale `sessionChunk`.

Mental model — shots vs. cuts:

|                  | `setShot` (soft)    | `sceneCut` (hard)        |
| ---------------- | ------------------- | ------------------------ |
| World            | same                | new                      |
| Memory           | preserved           | wiped                    |
| Per-scene budget | spends              | resets to fresh 48       |
| Length           | doesn't extend      | **extends** the video    |

A scene auto-completes at 48 chunks (~58s). To go longer, `sceneCut` to
a new scene — that resets the per-scene budget. `pause` halts chunk
emission, so aggressive pausing keeps you under the budget.

### Helios

```swift
let session = try await ReactorSession<Helios>.connect()
let ref = try await session.uploadImage(data: imageData, name: "scene.jpg")
try await session.setConditioning(prompt: "a coastal cliff", image: ref)
try await session.start()
try await session.schedulePrompt("storm rolling in", atChunk: 12)
```

Helios is chunked autoregressive (33 frames per chunk at 24fps). It
needs **both a prompt and a reference image at chunk 0** before
`start`; `setConditioning(prompt:image:)` updates both atomically so
mid-stream re-anchors don't render a frame against mismatched inputs.

`setImageStrength(_:)` (0.0–1.0) controls how tightly the model anchors
to the reference; the new strength doesn't apply until the next
`setImage` / `setConditioning` (or after `reset`). `setSRScale(.x4)`
opts into 4x super-resolution upscaling.

### LingBot

```swift
let session = try await ReactorSession<LingBot>.connect()
let world = try await session.uploadImage(data: imageData, name: "world.png")
try await session.setImage(world)
try await session.setPrompt("medieval village at dusk")
try await session.start()

// Inputs are sticky — set once, model honors every chunk until changed.
try await session.setMovement(.forward)
try await session.setLookHorizontal(.left)
// later …
try await session.setMovement(.idle)
```

LingBot's specialty: **persistent action inputs**. `movement`,
`lookHorizontal`, `lookVertical` are sticky state, not events — treat
them like a virtual joystick. The model fires `chunk_complete` with the
composite `activeAction` (e.g. `"forward+left"`) so you can confirm what
the server actually applied.

A prompt **and** a seed image are required before `start`; the server
emits `command_error` on `start` if either is missing.

### SANA-Streaming

```swift
let session = try await ReactorSession<SanaStreaming>.connect()
try await session.setMode(.file)
let clip = try await session.uploadVideo(data: clipData, name: "input.mp4")
try await session.setVideo(clip)
try await session.setPrompt("turn it into watercolor")
try await session.start()
try await session.setAnchorInterval(chunks: 8)  // re-ground more often
```

SANA-Streaming edits a source video chunk-by-chunk. **Re-grounding** is
the specialty: every `anchorInterval` chunks (default 20) the model
re-references the source so the edited output doesn't drift. Lower for
fidelity, higher for creative freedom, `0` to disable.

Live mode (camera input) is still stubbed — `setMode(.live)` throws
`SanaStreaming.LocalError.liveModeNotYetSupported`. It needs sendonly
`publishTrack` support, scheduled for v0.3.

## File uploads

`Reactor.uploadFile(data:name:mimeType:)` runs the two-step coordinator
flow (presigned URL → PUT the bytes) and returns a `FileRef` to embed
in `set_image` / `set_video` payloads. Requires `status == .ready`;
presigned URLs expire after ~15 minutes.

The typed wrappers expose convenience methods that pick sensible MIME
defaults:

- `HeliosSession.uploadImage(data:name:mimeType:)` → `image/jpeg`
- `LingBotSession.uploadImage(data:name:mimeType:)` → `image/jpeg`
- `SanaStreamingSession.uploadVideo(data:name:mimeType:)` → `video/mp4`

## Custom models (generic layer)

For models that don't have a typed wrapper yet (private previews,
future Reactor launches, custom internal models), drop down to the
generic `Reactor` class and send raw commands:

```swift
let reactor = Reactor(model: .custom("future-model-v9"))
try await reactor.connect(jwt: .provider { try await fetchJWT() })
try await reactor.sendCommand("set_prompt", payload: ["prompt": "a coastal cliff"])
reactor.onMessage { payload in
    // inner envelope {type, data:{…}}
}
```

`reactor.sendCommand("...", payload: ...)` ships whatever you hand it
as the `data` field — **the schema for every command is documented by
the model**, not the SDK. Sending a misnamed key (e.g. `session_chunk`
instead of `at_session_chunk` for LongLive's `schedule_shot`) makes
the server silently default the missing field — your beat never
fires. **Use the typed layer whenever there's one for your model.**

## Logging

The SDK uses `OSLog` under the subsystem `com.ioloro.SwiftReactor`. To
crank verbosity for local debugging, mirror RevenueCat's pattern:

```swift
Reactor.logLevel = .debug
```

The `LogLevel` enum is `.debug < .info < .warning < .error`. Even with
the SDK flag at `.info`, you can override per-subsystem in
`Console.app` if you want raw OSLog access.

## Testing your integration

`MockTransport` lets you wire `Reactor` to a recording transport with
no real backend:

```swift
@_spi(Testing) import SwiftReactor

let mock = MockTransport()
let reactor = Reactor(
    configuration: .init(modelName: ReactorModel.longLiveV2.wireName),
    transportFactory: { _, _, _ in mock }
)
let session = ReactorSession<LongLiveV2>(reactor: reactor)
reactor.connectForTesting(transport: mock)
await mock.simulateReady()

try await session.setShot(prompt: "opener")
try await session.start()

let commands = await mock.sentCommands
#expect(commands.map(\.command) == ["set_shot", "start"])
```

You can inject typed messages to drive the wrapper's state machine:

```swift
await mock.simulateLongLiveMessage(type: "command_error", data: [
    "reason": "prompt was empty",
    "command": "set_shot",
])
```

See `Tests/SwiftReactorTests/` for the regression-test patterns used to
cover all four wrappers.

## Examples

`Examples/SwiftReactorDemo/` is a SwiftUI macOS + iOS app with one tab
per model. Each tab goes deep on that model's specialty: scene
budgeting for LongLive, image conditioning + SR for Helios, persistent
controls for LingBot, anchor re-grounding for SANA-Streaming. Set
`REACTOR_API_KEY` in the scheme to run.

## macOS sandbox: WebRTC entitlements

Sandboxed macOS apps that use SwiftReactor need both incoming and
outgoing network entitlements:

```xml
<key>com.apple.security.network.client</key><true/>
<key>com.apple.security.network.server</key><true/>
```

Without `network.server`, only TCP ICE candidates gather and the ICE
checking phase never completes against UDP-only TURN servers. Symptom:
silent stall at `iceConnectionState=1`, no `connectionState` events.

## Building & testing

- Build: `swift build` works.
- Tests: `xcodebuild test -scheme SwiftReactor-Package -destination 'platform=macOS,arch=arm64'`.
  (`swift test` can't dlopen `WebRTC.framework` from a SwiftPM test
  bundle — run tests through Xcode / xcodebuild.)
- CI: `.github/workflows/test.yml` runs `swift build` plus
  `xcodebuild test` on every push.

## WebRTC pin

The `stasel/WebRTC` dependency is pinned to `140.0.0..<141.0.0`. 141+
ships a broken macOS slice (missing public headers). Re-evaluate when
the upstream issue is fixed.

## Known stubs

- **`publishTrack`** (sendonly tracks like a live camera). Required for
  SANA-Streaming live mode. Tracked for a future release.
- **Pause/resume via SDP renegotiation** at the transport level
  (distinct from the model-level `pause`/`resume` commands, which
  work).

## License

Apache 2.0 — see [LICENSE](LICENSE).
