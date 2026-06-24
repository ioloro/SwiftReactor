# SwiftReactor for LLM coding agents

This file is a self-contained briefing for an AI coding agent working
with SwiftReactor. It assumes you have repo read access and shell
execution; it does not assume you've seen the README. Read it
top-to-bottom before generating code.

## TL;DR

- **What it is.** Native Swift client for Reactor.inc's real-time
  video-generation API. Mirrors the official JS / Python SDKs.
- **What it gives you.** A generic `Reactor` class plus a single
  generic typed session `ReactorSession<Model>` parameterised by one
  of the four supported model namespaces (`LongLiveV2`, `Helios`,
  `LingBot`, `SanaStreaming`). Per-model commands live in
  constrained extensions, so e.g. `setMovement(.forward)` on a
  `ReactorSession<LongLiveV2>` is a **compile error** — wrong-model
  commands can't be called by accident.
- **How you call it.** `connect(jwt:)` → wait for `.ready` → typed
  command methods → `disconnect()`. Display the model's `main_video`
  with `ReactorView(reactor:)`.
- **Where it runs.** macOS 14+, iOS 17+, Swift 6.0, Xcode 16. Build
  with `swift build`; tests via `xcodebuild test` (SwiftPM's `swift
  test` can't dlopen `WebRTC.framework`).
- **Dependencies.** `stasel/WebRTC` pinned to `140.0.0..<141.0.0`.

## Install

```swift
// In your Package.swift
.package(url: "https://github.com/ioloro/SwiftReactor", from: "0.3.0"),
```

For an Xcode app, add the package via File → Add Packages…, select
SwiftReactor, target the framework.

## Connecting (the easy path)

```swift
import SwiftReactor

// At app launch — once.
Reactor.configure(jwt: .provider {
    try await myBackend.mintReactorJWT()
})

// Anywhere — one line from zero to a connected, typed session.
let session = try await ReactorSession<LongLiveV2>.connect()
```

All four typed sessions have the same `.connect()` static. Without a
prior `Reactor.configure(jwt:)`, the no-arg overload throws
`Reactor.ConfigurationError.notConfigured`. You can also override per-call:

```swift
let session = try await ReactorSession<LongLiveV2>.connect(jwt: .provider { … })
let session = try await ReactorSession<LongLiveV2>.connect(jwt: "eyJhbGci…")
```

### Auth modes

- `JWTSource.provider { … }` — your closure mints a JWT from your
  backend on every coordinator call. **Recommended.**
- `JWTSource.staticToken(_:)` — you handed the SDK an already-minted
  opaque JWT. Safe.
- `DevJWTMinter.fetchJWT(apiKey:)` (in `SwiftReactorDemoSupport`,
  not the core SDK) — mints a JWT directly from an `rk_…` key. For
  **local development, sample apps, CI scripts only**. Anyone with
  the binary can extract the API key.

```swift
// Don't do this in production — but this is what samples / demos do:
import SwiftReactorDemoSupport
let jwt = try await DevJWTMinter.fetchJWT(apiKey: "rk_…")
let session = try await ReactorSession<LongLiveV2>.connect(jwt: .staticToken(jwt))
```

`status` walks `disconnected → connecting → waiting → ready`. Only
issue commands once `status == .ready` (typed wrappers enforce this).

## Picking a model

Use the typed wrapper's `.connect()` factory for any of the four
supported models — no need to spell the wire name yourself. For
custom models, drop down to `Reactor(model: .custom("name"))`.

| ReactorModel case | Wire name | Typed wrapper |
| --- | --- | --- |
| `.longLiveV2` | `longlive-v2` | `ReactorSession<LongLiveV2>` |
| `.helios` | `helios` | `ReactorSession<Helios>` |
| `.lingbot` | `lingbot` | `ReactorSession<LingBot>` |
| `.sanaStreaming` | `sana-streaming` | `ReactorSession<SanaStreaming>` |
| `.custom(String)` | (verbatim) | — use generic `Reactor` + `sendCommand` |

**Always prefer the typed wrapper** when one exists for your model.
The wrappers encode the exact wire schema documented at
`docs.reactor.inc/model-api-reference/<model>/schema`. Sending a
misnamed key via the generic layer fails *silently* server-side (the
server defaults the missing field).

## Mental model

```
                  ┌────────────────┐
                  │  Reactor       │  generic transport + sendCommand + uploadFile
                  └────────────────┘
                          ▲
                          │ wraps
                          │
              ┌─────────────────────────────┐
              │ ReactorSession<Model>       │  shared state machine
              └─────────────────────────────┘
              ┌─────────┬─────────┬─────────┬───────────────┐
              ▼         ▼         ▼         ▼
       LongLiveV2    Helios    LingBot    SanaStreaming        (Model namespaces — params, messages,
                                                                error types, ReactorModelKind conform)

   extension ReactorSession where Model == LongLiveV2  →  setShot, sceneCut, schedule*, …
   extension ReactorSession where Model == Helios      →  setPrompt, setImage, setConditioning, …
   extension ReactorSession where Model == LingBot     →  setMovement, setLookHorizontal, …
   extension ReactorSession where Model == SanaStreaming →  setMode, setVideo, setAnchorInterval, …
```

The same `connect(jwt:)`, `disconnect()`, `onState`,
`onCommandError`, `onChunkComplete` exist regardless of model. The
per-model command sets are constrained extensions, so wrong-model
calls are a **compile error**, not a runtime throw.

## Lifecycle every session follows

```swift
// Preferred form — one expression.
let session = try await ReactorSession<LongLiveV2>.connect()   // uses configured JWT
// Or with explicit jwt:
let session = try await ReactorSession<LongLiveV2>.connect(jwt: .provider { … })

// (Render UI: ReactorView(reactor: session.reactor).)

// Send commands per the model's documented opener.
try await session.setX(...)
try await session.setY(...)
try await session.start()

// Watch state.
session.onState { snapshot in /* update UI */ }
session.onCommandError { e in /* surface e.reason */ }
session.onChunkComplete { c in /* per-chunk telemetry */ }

// Steer mid-run.
try await session.someMidRunCommand(...)

// Stop.
try await session.pause()
try await session.resume()
try await session.reset()       // clears all state, ready for a new run
await session.disconnect()
```

## Per-model gotchas

### LongLive-v2

- `schedule_shot` / `schedule_scene_cut` use the wire key
  `at_session_chunk`. The typed wrapper's `atSessionChunk:` argument
  maps to that field via a `swiftlint`-disabled snake_case property.
  Never use the generic layer with `session_chunk` (silent default to
  `-1`, beat never fires).
- One `start` per run. The typed wrapper throws
  `LongLiveV2.LocalError.alreadyStarted` on the second call instead of
  shipping a wire-rejected `start`.
- `generation_complete` locks the session server-side. The wrapper
  auto-fires `reset` so subsequent commands work; disable with
  `ReactorSession<LongLiveV2>(autoResetOnComplete: false)`.
- Per-scene budget is 48 chunks (~58s). `sceneCut` to extend; the
  per-scene counter resets, the cumulative `session_chunk` keeps
  counting.

### Helios

- **Both a prompt and a reference image are required before `start`.**
  Use `setConditioning(prompt:image:)` to set them atomically — avoids
  a transient frame rendered against mismatched inputs.
- `set_image_strength` doesn't apply until the next `set_image` /
  `set_conditioning` (or after `reset`). Setting strength alone is a
  silent no-op until you re-anchor.
- `schedule_prompt` uses `chunk` (not `at_chunk` or `session_chunk`).
  Past chunks are rejected mid-run.

### LingBot

- Action inputs (`movement`, `look_horizontal`, `look_vertical`) are
  **sticky**. Set once, the model applies them every chunk until you
  send a new value. Set `.idle` to stop.
- `currentAction` in the state snapshot is a `+`-joined composite
  string (e.g. `"forward+left"`, or `"still"` when fully idle).
- Both a prompt and a seed image are required before `start`. Missing
  preconditions surface as `command_error` on the `start` send.
- `rotation_speed_deg` range is `0.0…30.0`, default 5.0. Applies to
  both look axes.

### SANA-Streaming

- Live camera input (`set_mode(.live)`) requires sendonly
  `publishTrack` support, which is a v0.3 SDK stub. The typed wrapper
  throws `SanaStreaming.LocalError.liveModeNotYetSupported` to keep
  the SDK honest about what it can actually deliver end-to-end.
- File mode (`set_mode(.file)` + `setVideo(ref)`) works today.
- **Anchor re-grounding** is the specialty: every `anchorInterval`
  chunks (default 20) the model re-references the source. Lower for
  fidelity, higher for creative drift, `0` to disable.
- `set_anchor_interval` uses the wire key `chunks` (not `interval`).
- File mode auto-completes when the source clip's last frame ships.

## File uploads (for `set_image` / `set_video`)

```swift
let data = try Data(contentsOf: imageURL)
let ref = try await reactor.uploadFile(data: data, name: "scene.jpg", mimeType: "image/jpeg")
try await session.setImage(ref)
```

Typed wrappers expose convenience methods with sensible MIME defaults:

- `HeliosSession.uploadImage(data:name:mimeType:)` → `image/jpeg`
- `LingBotSession.uploadImage(data:name:mimeType:)` → `image/jpeg`
- `SanaStreamingSession.uploadVideo(data:name:mimeType:)` → `video/mp4`

Presigned upload URLs expire ~15 minutes after creation; reuse a
`FileRef` quickly after constructing it. Stale uploads surface as
`command_error`.

## Rendering video

Add `ReactorView(reactor:)` to your SwiftUI hierarchy. It listens for
`trackReceived(name: "main_video", …)` and hosts an `RTCMTLVideoView`
(iOS / iPadOS / visionOS / macOS).

```swift
struct ContentView: View {
    @State private var session = HeliosSession()
    var body: some View {
        ReactorView(reactor: session.reactor)
            .ignoresSafeArea()
            .task { try? await session.connect(jwt: jwtSource) }
    }
}
```

## SwiftUI bindings

`Reactor` and every typed wrapper are `@MainActor @Observable`. Reading
`session.snapshot?.currentChunk` from a view auto-tracks updates — no
`@StateObject`, no `objectWillChange` boilerplate.

```swift
struct ChunkBadge: View {
    let session: HeliosSession
    var body: some View {
        Text("chunk \(session.snapshot?.currentChunk ?? 0)")
    }
}
```

## Testing your integration (no GPU required)

```swift
@_spi(Testing) import SwiftReactor
import Testing

@Test func openerSequence() async throws {
    let mock = MockTransport()
    let reactor = Reactor(
        configuration: .init(modelName: "longlive-v2"),
        transportFactory: { _, _, _ in mock }
    )
    let session = ReactorSession<LongLiveV2>(reactor: reactor)
    reactor.connectForTesting(transport: mock)
    await mock.simulateReady()

    try await session.setShot(prompt: "opener")
    try await session.start()

    let commands = await mock.sentCommands.map(\.command)
    #expect(commands == ["set_shot", "start"])
}
```

Inject inbound messages with
`mock.simulateLongLiveMessage(type: "state", data: [...])` (the helper
is misnamed; it works for any model — it just builds the
`{type, data}` envelope).

## Sandbox entitlements (macOS apps)

```xml
<key>com.apple.security.network.client</key><true/>
<key>com.apple.security.network.server</key><true/>
```

Without `network.server`, ICE checking stalls forever against UDP-only
TURN servers. Symptom: silent hang at `iceConnectionState=1`, no
`connectionState` events.

## When the wire silently breaks

You sent a command via the generic layer and the model isn't doing
what you expect. Walk through:

1. Are you using the typed wrapper? If yes, you can't have misnamed a
   key (compile error). If no, that's the first thing to suspect.
2. Did the server emit a `command_error`? Subscribe via
   `reactor.onMessage` and dump the inner envelope. Typed wrappers
   surface `command_error` automatically via `lastCommandError` and
   `onCommandError`.
3. Is `status == .ready`? Commands sent during `connecting`/`waiting`
   throw `ReactorError(code: "NOT_READY")` from the generic layer.
4. For Helios / LingBot — did `conditions_ready` arrive yet? Both
   models require prompt + image before `start`.
5. For LongLive — past `session_chunk` for a `schedule_*`? Server
   rejects past chunks during active generation.

## Where to look in the source

- `Sources/SwiftReactor/Reactor.swift` — top-level entry point,
  connect / sendCommand / uploadFile.
- `Sources/SwiftReactor/Models/<Model>/` — one folder per model
  (`Session`, `Params`, `Messages`, `Error`).
- `Sources/SwiftReactor/Testing/MockTransport.swift` — public mock
  transport for unit tests.
- `Sources/SwiftReactor/UI/ReactorView.swift` — SwiftUI host for
  `main_video`.
- `Examples/SwiftReactorDemo/` — runnable four-tab demo.
- `Tests/SwiftReactorTests/` — regression-test patterns per model.

## Versions

- **0.3.0** — Ergonomic pass: `ReactorModel` enum + `Reactor(model:)`,
  per-session `.connect(...)` static factories, RevenueCat-style
  `Reactor.configure(jwt:)` + no-arg `.connect()`, `logLevel`,
  `DevJWTMinter` moved to `SwiftReactorDemoSupport` so the unsafe path
  requires extra friction at the package level.
- **0.2.0** — Helios, LingBot, SANA-Streaming typed wrappers; `FileRef`
  + `Reactor.uploadFile`; demo app; README + `AGENTS.md` polish.
- **0.1.0** — Initial release. Generic `Reactor` + `LongLiveV2Session`.

## Don't

- Don't ship the `rk_…` API key with the client binary. Mint JWTs
  server-side.
- Don't send raw `sendCommand("schedule_shot", ["session_chunk": 8])`.
  Use `scheduleShot(prompt:atSessionChunk:)` so the wire key is
  correct.
- Don't call `start()` more than once per run. Either the typed
  wrapper throws `alreadyStarted`, or the wire `start` is silently
  rejected. Call `reset()` to start a new run.
- Don't poll `status` in a tight loop. Subscribe via
  `reactor.on(.statusChanged) { … }` or just read it from a SwiftUI
  view — it's `@Observable`.
- Don't construct a `FileRef` by hand for production use. Use
  `Reactor.uploadFile(...)` (the convenience methods on each session
  wrap it).
- Don't ignore `command_error`. The typed wrappers surface them; the
  generic layer leaves them in the message stream — handle them or
  swallow user-facing errors.
