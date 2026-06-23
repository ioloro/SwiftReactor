# SwiftReactor Demo

A SwiftUI macOS app with one tab per Reactor model, going deep on each
model's specialty.

## Run it

From the package root:

```bash
swift run SwiftReactorDemo
```

The app opens a window; the Settings sheet pops on first launch so you
can paste either a pre-minted JWT (fastest) or your `rk_…` API key.

You can also pre-set `REACTOR_API_KEY` in the environment:

```bash
REACTOR_API_KEY=rk_yourkey swift run SwiftReactorDemo
```

> **Don't ship the API key with a client binary in production.** Mint
> JWTs server-side and hand them in via `JWTSource { try await
> fetchJWT() }`. The demo accepts the key directly only because it's a
> local-dev sample.

## Tabs

| Tab | What it shows | Specialty |
| --- | --- | --- |
| LongLive-v2 | Opener + soft `setShot` vs. hard `sceneCut` + `scheduleShot` at +N | Multi-shot narrative, 48-chunk per-scene budget (live meter) |
| Helios | Image picker + atomic `setConditioning` + scheduled prompt + SR scale | Image-conditioned streaming, schedulable prompt changes |
| LingBot | Sticky movement / look buttons + composite-action snapshot | Persistent action inputs (joystick-style) |
| SANA-Streaming | MP4 source picker + mid-edit prompt + anchor-interval slider + re-anchor event log | Video-to-video editing, anchor re-grounding |

## What "live mode disabled" means on the SANA tab

SANA-Streaming supports a `live` mode where you'd push frames from a
local camera over a sendonly `camera` track. SwiftReactor's transport
doesn't ship `publishTrack` yet (v0.3 milestone), so the typed wrapper
throws `liveModeNotYetSupported` to keep the demo honest about what
runs end-to-end. The button is wired up; it just throws and surfaces
the explanation.
