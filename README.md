# SwiftReactor

Native Swift client for the [Reactor](https://reactor.inc) real-time
video-generation platform. Mirrors the surface of the official
[`@reactor-team/js-sdk`](https://docs.reactor.inc/api-reference/reactor-class)
and [`reactor-sdk`](https://docs.reactor.inc/sdk-reference/python/reactor)
Python packages, plus typed wrappers for every Reactor model.

```swift
.package(url: "https://github.com/ioloro/SwiftReactor", from: "0.2.0"),
```

Minimum: macOS 14 / iOS 17, Swift 6.0, Xcode 16.

## Two layers

| Layer | Type | Use it for |
| --- | --- | --- |
| **Generic** | `Reactor`, `Reactor.sendCommand(_:payload:)` | Any model — custom commands, raw payloads, base SDK features. |
| **Model-typed** | `LongLiveV2Session`, `HeliosSession`, `LingBotSession`, `SanaStreamingSession` | Typed methods + state-machine guards for each Reactor model. |

The generic layer makes no assumptions about wire schema. The typed
layer encodes every model's documented schema so renaming a parameter
key is a compile error and double-`start` is a local exception, not a
silent wire fault.

## Supported models

| Model | Specialty | Typed wrapper |
| --- | --- | --- |
| [LongLive-2.0](https://docs.reactor.inc/model-api-reference/longlive-v2/overview) | Real-time multi-shot video; seamless shot changes + hard cuts, 48-chunk per-scene budget | `LongLiveV2Session` |
| [Helios](https://docs.reactor.inc/model-api-reference/helios/overview) | Interactive real-time streaming with image-conditioned prompts, schedulable prompt changes, optional 2x/4x SR | `HeliosSession` |
| [LingBot](https://docs.reactor.inc/model-api-reference/lingbot/overview) | Action-controlled world generation; persistent movement + look inputs (joystick-style) | `LingBotSession` |
| [SANA-Streaming](https://docs.reactor.inc/model-api-reference/sana-streaming/overview) | Real-time video-to-video editing with anchor re-grounding | `SanaStreamingSession` |

## Quickstart

```swift
import SwiftReactor

let reactor = Reactor(modelName: "longlive-v2")
try await reactor.connect(jwt: .staticToken(jwt))
try await reactor.sendCommand("set_shot", payload: ["prompt": "a coastal cliff"])
reactor.onMessage { payload in /* inner envelope {type, data:{…}} */ }
```

`Reactor` is `@MainActor @Observable` — `status`, `lastError`, and
`capabilities` track in SwiftUI views with no extra plumbing.

### Wire schema is the consumer's problem at the generic layer

`reactor.sendCommand("...", payload: ...)` ships whatever you hand it as
the `data` field. **The schema for every command is documented by the
model**, not the SDK. Sending a misnamed key (e.g. `session_chunk`
instead of `at_session_chunk` for LongLive's `schedule_shot`) makes the
server silently default the missing field — your beat never fires. **The
typed layer exists for exactly this** — use it whenever there's one for
your model.

## Auth (`JWTSource`)

Reactor accepts a JWT minted by your backend. `JWTSource` is the hook
the SDK uses to resolve one — every coordinator HTTP call goes through
it, so the same `JWTSource` instance covers session creation, polling,
and `uploadFile`.

```swift
// String literal — quickest for local development.
try await reactor.connect(jwt: "eyJhbGciOi…")

// Pre-minted token (e.g. fetched from your backend at app launch).
try await reactor.connect(jwt: .staticToken(jwt))

// Backend-mint flow — the closure runs on every coordinator call.
try await reactor.connect(jwt: JWTSource { try await fetchJWT() })
```

The recommended pattern: your app talks to your backend, your backend
holds the Reactor API key and mints short-lived JWTs. Don't ship the
raw `rk_…` key with a client binary.

## Typed wrappers

Each wrapper bakes in the documented schema + state machine for one
model.

### LongLive-v2

```swift
let session = LongLiveV2Session()
try await session.connect(jwt: .staticToken(jwt))
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
   out via `LongLiveV2Session(autoResetOnComplete: false)`).
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
let session = HeliosSession()
try await session.connect(jwt: .staticToken(jwt))
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
let session = LingBotSession()
try await session.connect(jwt: .staticToken(jwt))
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
let session = SanaStreamingSession()
try await session.connect(jwt: .staticToken(jwt))
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

Live mode (camera input) is stubbed in v0.2 — `setMode(.live)` throws
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

## Testing your integration

`MockTransport` lets you wire `Reactor` to a recording transport with
no real backend:

```swift
@_spi(Testing) import SwiftReactor

let mock = MockTransport()
let reactor = Reactor(
    configuration: .init(modelName: "longlive-v2"),
    transportFactory: { _, _, _ in mock }
)
let session = LongLiveV2Session(reactor: reactor)
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

## v0.2 stubs

- **`publishTrack`** (sendonly tracks like a live camera). Required for
  SANA-Streaming live mode. Tracked for v0.3.
- **Pause/resume via SDP renegotiation** at the transport level
  (distinct from the model-level `pause`/`resume` commands, which
  work).

## License

MIT — see [LICENSE](LICENSE).
