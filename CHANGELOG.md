# Changelog

All notable changes to SwiftReactor are documented here. The format is
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project
follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed (breaking)

- **One typed session class for the whole SDK.** The four per-model
  classes (`LongLiveV2Session`, `HeliosSession`, `LingBotSession`,
  `SanaStreamingSession`) collapse into a single generic
  `ReactorSession<Model>` parameterised by a `ReactorModelKind`
  conformer. Per-model command surfaces (`setShot`, `setMovement`,
  …) live in constrained extensions, so **wrong-model commands are
  a compile error** rather than a runtime trap. New spelling:
  ```swift
  let session = try await ReactorSession<LongLiveV2>.connect()
  ```
  Existing call sites in tests, demo, and consumer projects need a
  one-line update per session — see CHANGELOG diff.
- **`ReactorModel.longLive` → `.longLiveV2`** so the case name
  matches the namespace it picks. Other three (`.helios`,
  `.lingbot`, `.sanaStreaming`) unchanged. Models stay specific +
  versioned where Reactor versions them.

- **`SwiftReactor` namespace folded into `Reactor` class statics.**
  `SwiftReactor.configure(jwt:)` → `Reactor.configure(jwt:)`;
  `SwiftReactor.logLevel` → `Reactor.logLevel`;
  `SwiftReactor.Error.notConfigured` →
  `Reactor.ConfigurationError.notConfigured`. The old `SwiftReactor`
  enum collided with the module name `SwiftReactor`, breaking any
  consumer with its own `ReactorSession` type (e.g. Sunnyside Golf,
  which couldn't write `SwiftReactor.ReactorSession<LongLiveV2>`
  cleanly). Folding the surface onto `Reactor` matches RevenueCat's
  `Purchases.configure(...)` pattern exactly and removes the
  collision.

### Added

- **`ReactorModelKind` protocol** that the four namespace enums
  (`LongLiveV2`, `Helios`, `LingBot`, `SanaStreaming`) conform to.
  Pins each model's `StateMessage`, `CommandErrorMessage`,
  `Message`, `LocalError` associated types plus the static
  `asModel`, `decode(payload:)`, `extractState`,
  `extractCommandError`, `isGenerationComplete`,
  `snapshotIndicatesStopped` glue `ReactorSession` needs.
- **`ReactorConfiguration(model:)`** typed init to pair the
  `ReactorModel` enum at the configuration level too.

## [0.3.0] - 2026-06-24

Ergonomic pass. The headline change: typed-session `.connect()` is now
a one-line factory, and you can install a default `JWTSource` once at
app launch via `Reactor.configure(jwt:)` so subsequent calls
don't thread credentials through every view.

### Added

- **`ReactorModel` enum** with cases `.longLiveV2`, `.helios`, `.lingbot`,
  `.sanaStreaming`, `.custom(String)`. Prefer this over the raw string
  `Reactor(modelName: "longlive-v2")` initializer — typos become
  compile errors, autocomplete surfaces every typed wrapper, and the
  case docs explain each model at the call site. `Reactor(model:)`
  convenience init delegates to the existing modelName path.
- **`Reactor.configure(jwt:)`** — module-level default `JWTSource`,
  mirroring RevenueCat's `Purchases.configure(...)` pattern. Set once
  at app launch; every typed session's no-arg `.connect()` picks it
  up. Per-call `.connect(jwt: …)` still works and overrides.
- **`Reactor.logLevel`** — `.debug`/`.info`/`.warning`/`.error`
  verbosity dial for the SDK's OSLog output, mirroring
  `Purchases.logLevel`.
- **Per-session `.connect(...)` static factories** on every typed
  wrapper (`LongLiveV2Session`, `HeliosSession`, `LingBotSession`,
  `SanaStreamingSession`). Instantiate, connect, and return a ready
  session in one `try await`. Two overloads each: explicit
  `jwt:` argument, or no-arg pulling from `Reactor.sharedJWT`.
- **`JWTSource.provider(_:)` static factory** — same shape as the
  existing closure-init but reads better at call sites:
  `JWTSource.provider { try await fetchJWT() }`. The recommended
  pattern.
- **`DevJWTMinter`** in `SwiftReactorDemoSupport`. POSTs `/tokens`
  with your `rk_…` key and returns a JWT. Lives in the support target
  on purpose — pulling it in requires adding `SwiftReactorDemoSupport`
  to your `Package.swift`, which is the friction that keeps the
  unsafe path out of production code by autocomplete. Mirrors the
  pattern of Python SDK's `fetch_jwt_token(api_key=…)`. First use
  logs a one-time warning to OSLog.
- **Tests for the new ergonomic surface**: `ReactorModelTests` pins
  the wire-name mapping for every case; `SwiftReactorConfigureTests`
  covers `configure(jwt:)` round-trip and the `notConfigured` error
  path for every session; `DevJWTMinterTests` exercises the happy
  path, header correctness, HTTP error surfacing, and the
  `jwtSource(apiKey:)` convenience via a `URLProtocol` stub.

### Changed

- **Demo app's `DemoSettings`** now uses
  `DevJWTMinter.jwtSource(apiKey:)` instead of inlining the
  `POST /tokens` flow. Demonstrates the recommended dev-only path.
- **README quickstart** rewritten — leads with the 2-step
  `Reactor.configure(...)` + `LongLiveV2Session.connect()` flow.
  Auth section shows the three modes (`.provider`, `.staticToken`,
  `DevJWTMinter`) in order of safety with a 🚨 callout for the dev
  helper. Generic `Reactor` + `sendCommand` is now a "Custom models"
  section at the bottom rather than the headline pattern.
- **AGENTS.md** updated to match the new patterns end-to-end.
- **License section** of the README corrected from MIT to Apache 2.0
  to match the actual `LICENSE` file.
- **`ReactorConfiguration.currentSDKVersion`** bumped to `0.3.0`.

### Fixed

- **Demo app: `TextField` no longer silently swallows keystrokes.**
  `swift run SwiftReactorDemo` produced a `LSBackgroundOnly` process
  (no `Info.plist` in a SwiftPM `executableTarget`), so macOS refused
  to route key events to the focused responder even though the field
  reported `focused=true` over AX. Fixed by calling
  `NSApplication.shared.setActivationPolicy(.regular)` from
  `App.init`, factored into a new `SwiftReactorDemoSupport` library
  target (`DemoActivationPolicy.applyRegular()`) with a regression
  test (`DemoActivationPolicyTests`).
- **LongLive demo tab: preflight no longer lies after auto-reset.**
  The `LongLiveTab` was caching a local `hasSentSetShot` `@State`
  flag for the "setShot sent" preflight step. After a
  `generation_complete + auto-reset` cycle, the server clears
  `hasPrompt` but the cached flag stayed `true`, so the preflight
  showed all green while the next `start` shipped into a
  `[start] No prompt set` rejection. Same bug shape the Helios /
  LingBot / SANA tabs already had a fix for via `PreflightGates`.
  The tab now derives its `openerReady` gate from
  `PreflightGates.longLiveOpenerReady(snapshot:)`. The combined
  `setShot + start` button also polls the snapshot for server
  confirmation before firing `start`, the same pattern the other
  three tabs use.
- **CI: workflow no longer assumes `/Applications/Xcode_16.app`.**
  GitHub macOS runner images ship versioned Xcode installs
  (`Xcode_16.0.app`, `Xcode_16.1.app`, …) and rotate which one is
  available. The workflow now uses `maxim-lobanov/setup-xcode@v1`
  with `xcode-version: latest-stable` on the `macos-15` runner
  (Swift 6.0 requires Xcode 16+ which `macos-14`'s default doesn't
  provide).

### Added

- `SwiftReactorDemoSupport` library target containing testable
  demo-app helpers. Not part of the SwiftReactor SDK surface; it
  exists because SwiftPM test targets can't link executable targets,
  so the demo's testable bits need a separate library home.
- `PreflightGates.longLiveOpenerReady(snapshot:)`, the fourth gate
  helper, matching the existing Helios / LingBot / SANA helpers, so
  every tab derives its preflight from the live snapshot rather than
  caching server-ack events that go stale across an auto-reset.
- End-to-end golden-path test suites for all four typed wrappers
  (`LongLiveV2GoldenPathTests`, `HeliosGoldenPathTests`,
  `LingBotGoldenPathTests`, `SanaStreamingGoldenPathTests`). Each
  walks the full demo-tab command sequence against `MockTransport`,
  injects realistic server responses (state, command_error,
  conditions_ready, chunk_complete, generation_complete) between
  commands, and asserts both the observable wrapper state
  (`snapshot`, `hasStartedRun`, `lastCommandError`) and the wire
  payload shape (right wire keys, right enum raw values, right
  command order). Catches: stale gates after `generation_complete +
  auto-reset`, double-`start` on a recovered session, wire-key
  drift on `schedule_shot` / `set_anchor_interval` /
  `set_look_horizontal`, optimistic-local-flag reconciliation when
  the server emits `command_error` instead of accepting `start`.

## [0.2.0] - 2026-06-23

Adds typed wrappers for every Reactor model, file uploads, and a
runnable demo. No source-breaking changes from `0.1.0` for consumers
of `Reactor` or `LongLiveV2Session`.

### Added

- **`HeliosSession`** — typed wrapper for the Helios model. Commands:
  `setPrompt`, `schedulePrompt(_:atChunk:)`, `setImage`,
  `setConditioning(prompt:image:)`, `setImageStrength`, `setSRScale`,
  `setSeed`, `start`, `pause`, `resume`, `reset`. Snapshot mirrors the
  server's `state` message (including `scheduledPrompts`).
- **`LingBotSession`** — typed wrapper for the LingBot model. Typed
  enums for `Movement`, `LookHorizontal`, `LookVertical`. Sticky-input
  semantics documented in headers.
- **`SanaStreamingSession`** — typed wrapper for the SANA-Streaming
  model. File mode supported end-to-end; live-camera mode throws
  `liveModeNotYetSupported` until `publishTrack` lands in v0.3.
- **`FileRef`** — public value type for uploaded files. Embeds in
  command payloads as `{upload_id, name, mime_type, size}` matching the
  Python SDK's `FileRef`.
- **`Reactor.uploadFile(data:name:mimeType:)`** — runs the
  coordinator's two-step presigned-URL flow and returns a `FileRef`.
  Typed wrappers expose `uploadImage` / `uploadVideo` convenience
  methods with sensible MIME defaults.
- **`ReactorConfiguration.localBaseURL`** — for `reactor local`
  runtime testing at `http://localhost:8080`.
- **`Examples/SwiftReactorDemo/`** — SwiftUI demo with one tab per
  model, going deep on each model's specialty.
- **`AGENTS.md`** — LLM-friendly onboarding doc.
- **`CONTRIBUTING.md`** — build / test / PR conventions.
- **`.github/workflows/test.yml`** — CI running `swift build` and
  `xcodebuild test` on every push.
- 19 new regression tests across the three new wrappers
  (`HeliosSessionTests`, `LingBotSessionTests`,
  `SanaStreamingSessionTests`).

### Changed

- `ReactorConfiguration.productionBaseURL` no longer force-unwraps a
  literal `URL(string:)` — uses `URLComponents` with a `fatalError`
  guard that surfaces in tests if the constant ever becomes malformed.
- `ReactorConfiguration.currentSDKVersion` is now the canonical place
  for the SDK version string (sent as `client_info.sdk_version`).
- README rewritten: per-model sections, auth model, sandbox
  entitlements, troubleshooting, JS/Python sibling links.
- Doc comments added to `ReactorConfiguration`, `JWTSource`,
  `ReactorStatus`, `TransportStatus`.

### Fixed

- README package-version pin (`0.2.0`) now matches `Package.swift`.

## [0.1.0] - 2026-06-22

Initial public release.

### Added

- Generic `Reactor` class mirroring `@reactor-team/js-sdk`.
- `LongLiveV2Session` typed wrapper covering the multi-shot grammar
  (`setShot`, `sceneCut`, `scheduleShot`, `scheduleSceneCut`, `start`,
  `pause`, `resume`, `reset`).
- `MockTransport` public test-only transport for consumer unit tests.
- `ReactorView` SwiftUI host for `main_video`.
- WebRTC pin: `stasel/WebRTC` `140.0.0..<141.0.0`.
