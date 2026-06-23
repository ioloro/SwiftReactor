# Changelog

All notable changes to SwiftReactor are documented here. The format is
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project
follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
