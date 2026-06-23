# Contributing to SwiftReactor

Thanks for considering a contribution. SwiftReactor's job is to mirror
the Reactor.inc real-time video-generation platform with the
ergonomics of a first-class Swift SDK — small, typed, easy to test.

## Quick start

```bash
git clone https://github.com/ioloro/SwiftReactor.git
cd SwiftReactor
swift build
xcodebuild test -scheme SwiftReactor-Package -destination 'platform=macOS,arch=arm64'
```

You'll need **Xcode 16+** (Swift 6.0) and macOS 14 / iOS 17 deployment
targets respected for any code touching the public surface.

## Why `xcodebuild test`, not `swift test`?

`swift test` can't dlopen `WebRTC.framework` from a SwiftPM test
bundle on macOS — the framework's `@rpath` resolution doesn't pick up
the bundle's runtime location. CI and local development both go
through `xcodebuild test`, which loads the framework correctly.

## Project shape

```
Sources/SwiftReactor/
├── Reactor.swift              ← top-level entry point
├── ReactorConfiguration.swift
├── ReactorStatus.swift
├── ReactorError.swift
├── FileRef.swift
├── Auth/                      ← JWTSource
├── Models/
│   ├── LongLiveV2/            ← typed wrapper + Params + Messages + Error
│   ├── Helios/
│   ├── LingBot/
│   └── SanaStreaming/
├── Networking/                ← CoordinatorClient, APIModels, AnyCodable
├── Testing/                   ← MockTransport (public)
├── UI/                        ← ReactorView
└── WebRTC/                    ← WebRTCTransport
Tests/SwiftReactorTests/
Examples/SwiftReactorDemo/     ← runnable per-model demo
```

## Adding a typed model wrapper

When Reactor announces a new model, mirror the LongLive-v2 layout:

1. Create `Sources/SwiftReactor/Models/<Model>/`.
2. Add `<Model>Params.swift` — public `enum <Model>` namespace plus
   per-command `Encodable, Sendable, Equatable` params structs. Use
   the **literal wire keys** (`at_session_chunk`, `image_strength`,
   etc.) as Swift property names. `// swiftlint:disable:next
   identifier_name` is the convention.
3. Add `<Model>Messages.swift` — `<Model>.Message` enum + per-event
   `Decodable, Sendable, Equatable` structs + `decode(from:)` and
   `decode(type:data:)` static methods.
4. Add `<Model>Error.swift` — `<Model>.LocalError` enum for
   client-side state-machine errors (`alreadyStarted`, `notReady`, +
   any model-specific guard).
5. Add `<Model>Session.swift` — the `@MainActor @Observable` wrapper.
   Mirror `LongLiveV2Session` for: `connect`, `disconnect`, typed
   commands, `snapshot`, `lastCommandError`, `hasStartedRun`, `onState`,
   `onCommandError`, `onChunkComplete`. Pull state from the server's
   `state` messages, never from the command stream.
6. Add `Tests/SwiftReactorTests/<Model>SessionTests.swift`. The
   minimum bar: at least one wire-schema test per command with a
   non-trivial wire key, the `start()` double-call guard, a
   `command_error` round-trip, and a `state` snapshot decode.
7. Add a section to `README.md` and a row to the supported-models
   table.
8. Add a row to `AGENTS.md` and an entry to the "Per-model gotchas"
   section.
9. Add a tab to `Examples/SwiftReactorDemo/` that goes deep on this
   model's specialty (not just a generic "send a prompt" form).

The schema source of truth is
`https://docs.reactor.inc/model-api-reference/<model>/schema`. When
the docs and the SDK disagree, the docs win.

## Style

- **No force-unwrap on public init paths.** If a literal `URL(string:)`
  could fail in principle, surface it as a `fatalError` with a clear
  message in a `static let`, so the failure is loud and immediate at
  load time (and caught by the unit-test pass that imports the SDK).
- **Doc comments (`///`) on every public symbol.** Three lines max for
  most properties; expand for anything with a non-obvious wire
  constraint or state-machine implication.
- **`@MainActor @Observable`** for SwiftUI-facing classes.
- **`Sendable`** on everything that crosses an isolation boundary
  (params, messages, errors, configuration). The compiler will tell
  you when you missed one.
- **No `print()`**. Use `OSLog` with the `com.ioloro.SwiftReactor`
  subsystem and a category matching the model name (`longlive-v2`,
  `helios`, …).
- **Wire keys are the model's contract.** If the Reactor docs say
  `at_session_chunk`, the Swift property is `at_session_chunk` (with a
  swiftlint disable comment). Renaming for "Swift style" is how the
  silent-default bugs come back.

## Tests

- Mirror the test pattern from `LongLiveV2SessionTests.swift`.
- One `MockTransport` per test. Don't share state across tests.
- Use `await mock.simulateLongLiveMessage(type:data:)` (the name is
  legacy — works for any model) to inject inbound state.
- Use `tinyWait()` (~100ms + 20 `Task.yield()`s) after injecting a
  message; the async-stream hop takes that long to flow through the
  callbacks.
- Don't use real network. The SDK is testable end-to-end with
  `MockTransport` — keep it that way.

## Commit / PR conventions

- Branch from `main`.
- One conceptual change per PR. Adding a new typed wrapper is one PR;
  refactoring the test helpers is another.
- Commit messages: imperative present tense, ≤ 72 chars on the first
  line, prose body if any. Match the existing log:
  `git log -10 --pretty=format:'%s'`.
- No `Co-Authored-By: Claude` trailers on commits to this repo — it's
  a public ioloro library and should read as published work.
- Update `CHANGELOG.md` for any user-visible change. The
  `[Unreleased]` section at the top of CHANGELOG is the right
  staging area.

## Releasing

1. Bump `ReactorConfiguration.currentSDKVersion`.
2. Move `[Unreleased]` entries to a dated version section in
   `CHANGELOG.md`.
3. Update the `from:` pin example in `README.md` if the major or
   minor moved.
4. Tag: `git tag -a v0.X.Y -m "v0.X.Y" && git push origin v0.X.Y`.
5. Cut a GitHub release with the CHANGELOG snippet as the body.

## Getting help

- File issues at https://github.com/ioloro/SwiftReactor/issues with
  a minimal repro.
- For Reactor-platform questions (not SDK questions), see
  https://docs.reactor.inc.
