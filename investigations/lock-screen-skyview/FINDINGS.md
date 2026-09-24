# Investigation: Elevating macOS desktop widgets to the lock screen via SkyLight

**Branch:** `investigate/lock-screen-skyview` (off `feature/lock-screen-widgets`)
**Date:** 2026-09-23 · macOS 27.0.0 · probe artifacts in this directory

## The idea

macOS Sonoma+ hosts the user's desktop widgets (clock, weather, calendar — the
WidgetKit ones) in windows owned by the **Dock** process. The question: can a
normal app re-space those **foreign** windows into a SkyLight space pinned at
the lock-screen level — "elevating" them like the login screen's own widgets —
the same class of trick tools use to manipulate notification banners?

Explicitly **not** in scope: boring.notch's own widgets (those already have a
working lock-screen surface on this branch).

## What the repo already has (feature/lock-screen-widgets)

- `BoringNotchSkyLightWindow` — the notch's NSPanel; `enableSkyLight()` /
  `disableSkyLight()` delegate it in and out of a SkyLight space while the
  screen is locked (`showOnLockScreen` setting). Ships and works.
- `LockScreenWidgetCoordinator` + `LockScreenWidgetPanel` — a single widget
  deck panel created while locked, at `CGShieldingWindowLevel()`, delegated via
  `SkyLightOperator`, read-only, mouse-transparent. Wired to
  `screenDidLock/Unlock` in `boringNotchApp.swift`. This is the proven
  in-app pattern any "elevated surface" work would build on.
- `SkyLightWindow` SPM package internals (from the checked-out source):
  - `SkyLightOperator.shared` creates **one** space with
    `SLSSpaceCreate(cid, 1, 0)` and pins it via
    `SLSSpaceSetAbsoluteLevel(cid, space, 400)` —
    `kSLSSpaceAbsoluteLevelNotificationCenterAtScreenLock` (levels enum:
    SetupAssistant=100, SecurityAgent=200, ScreenLock=300,
    NotificationCenterAtScreenLock=400, Boot=500, VoiceOver=600).
  - `delegateWindow()` = `SLSSpaceAddWindowsAndRemoveFromSpaces(cid, space,
    [windowNumber], 7)`. Client-side, there is **no ownership check** in the
    API surface — the gate is inside WindowServer.

## Probe methodology

`LockScreenWidgetProbe.swift` (+ `HelperWindow.swift` child) performs staged
SkyLight calls with named CGError decoding, ever widening the test surface:

1. enumerate desktop-widget windows (CGWindowList — Dock-owned, layer 0),
2. create an elevated space (level 400) — *should always succeed*,
3. move **our own plain window** into it (control),
4. move **our own shielding-level panel** (exact `LockScreenWidgetPanel`
   replica) into it,
5. move a **foreign** window (owned by the helper child we spawn) into it,
6. verify on-screen visibility after each move, then restore.

Everything is self-owned or spawned by the probe; no user window is touched.
Runs were attempted as: bare CLI process → with live `NSApplication` → inside
an ad-hoc-signed minimal `.app` bundle.

## Results

| Stage | Result |
|---|---|
| `SLSMainConnectionID` | ok |
| `SLSSpaceCreate` + `SLSSpaceSetAbsoluteLevel(400)` + `SLSShowSpaces` | **ok** (every run) |
| `SLSCopyManagedDisplaySpaces` (read) | **ok** — 2 displays enumerated |
| `SLSSpaceAddWindowsAndRemoveFromSpaces` — own `NSWindow` | **err 3 `kCGErrorInvalidConnection`** |
| same — own shielding-level `NSPanel` (LockScreenWidgetPanel replica) | **err 3** |
| same — foreign helper-process window | **err 3** |
| Variant: `options=0` instead of `7` | **err 3** |
| Variant: separate `SLSAddWindowsToSpaces` | **err 3** |
| Variant: `cid = 0` (yabai-style) | space create itself rejected (`0x10000003`) |

Probe configurations that all produced the identical write-refusal:

| Configuration | Write result |
|---|---|
| Bare CLI process | err 3 |
| Live `NSApplication` run loop | err 3 |
| Ad-hoc-signed `.app` bundle | err 3 |
| + **Accessibility TCC granted** (`AXIsProcessTrusted()=true` observed) | err 3 |
| + App Sandbox entitlement (matching the shipped app) | err 3 |
| + linker `-platform_version macos 14.0 26.5` claim (27.0 SDK binary relabeled) | err 3 — claim alone is insufficient |

CGWindowList enumeration sees ~3.2k windows but **no desktop widgets are
currently placed on this Mac** (Dock-owned, layer 0, >40pt) — so the widget
discovery stage has nothing to list yet; the verdict above doesn't depend on
it (we never got past our own windows).

## Analysis (updated after full hypothesis sweep)

- The rejected calls are the *window-moving* ones; space create/pin/show and
  all display reads succeed, so shims/signatures are correct (an earlier
  `SLSCopyWindowsWithOptionsAndTags` attempt segfaulted and was replaced by
  CGWindowList — that call takes a `uint32` size, not pointers).
- `kCGErrorInvalidConnection` for **our own window** means WindowServer
  refuses the connection's authorization to mutate window↔space membership —
  the failure is upstream of any foreign-ownership question.
- Ruled out as the gate: app lifecycle (NSApplication), bundling/signing,
  **Accessibility TCC grant** (granted and observed `true`, still refused),
  the App Sandbox (tested; matches shipped app), cid=0 connection trick,
  and call-shape variants. Screen Recording grant remains untested but is
  implausible as the gate for a window-space write.
- **Revised conclusion:** WindowServer on macOS 27 gates
  `SLSSpaceAddWindowsAndRemoveFromSpaces` by the **calling binary's build
  context**, not by a blanket ban. The working release app and every failing
  probe differ in exactly three measurable ways:

  | | Release app (works) | Probe / local Debug (refused) |
  |---|---|---|
  | Linked SDK (`LC_BUILD_VERSION`) | **26.5** | 27.0 (claiming 26.5 via relink was **not** enough) |
  | Code signature | Team `JPWMG84CH8` (Developer ID, CI-signed) | ad-hoc |
  | TCC grants | full set (AX + Screen Recording et al.) | none-to-partial |

  The SDK-26.5 relink test rules out SDK version as the *sole* gate; the
  remaining discriminators are the team signature and/or the accumulated TCC
  state, which a locally ad-hoc-signed probe cannot replicate (no signing
  identity in any local keychain; release signing happens in CI).
- Consequence for the original question: elevating **Dock-owned desktop
  widgets** is not answerable with local tooling on this OS — the write
  primitive is context-gated. Whether Apple intends old-SDK binaries to
  retain this power indefinitely is unknowable; treat it as deprecated
  capability living on borrowed time.

## Manual tests (user, 2026-09-23)

- Debug build of `feature/lock-screen-widgets` (ad-hoc, SDK 27.0), *Show on
  Lock Screen* + widgets enabled: **nothing on the lock screen**.
- **Release app** (`/Applications/boringNotch.app`, v2.8-rc.0, build 278):
  lock-screen content **works, recently, on this same macOS 27.0.0**
  (user-confirmed).

So the primitive is **not removed** on macOS 27 — it is **gated by binary
context**.

## Plan (agreed: stop probing, plan around the gate)

1. **Develop the lock-screen feature against the release-style build**:
   local ad-hoc Debug builds made with the Xcode 27 SDK silently cannot
   exercise SkyLight delegation on macOS 27. Either (a) build via CI
   (`manual_build.yml` pins Xcode 26.6 and applies the team certificate —
   those artifacts carry the working context), or (b) install Xcode 26.x
   alongside and select it for this project while working on lock-screen
   code.
2. **Document the constraint in the feature PR**: the `showOnLockScreen`
   setting only functions in release-style builds (old-SDK link + team
   signature + TCC); note it prominently so "it doesn't work in my Debug
   build" is pre-answered.
3. **Add a runtime delegation check**: `BoringNotchSkyLightWindow`
   currently ignores `delegateWindow`'s absence of feedback. Log the call
   result once per lock session and expose a diagnostics line in settings
   ("lock-screen surface: active/unavailable"), so the feature degrades
   honestly on future OS/SDK combinations.
4. **Treat the capability as deprecated upstream**: file the SkyLightWindow
   issue with the test matrix (it's the first report of the 27-era gating)
   and keep the probe in-repo; if a future OS or SDK combination changes the
   gate, one rerun answers the foreign-desktop-widget question — the actual
   product idea — without new tooling.

## Reproduce

```bash
cd investigations/lock-screen-skyview
swiftc -O HelperWindow.swift -o helper-window
swiftc -O LockScreenWidgetProbe.swift -o lock-probe
./lock-probe ./helper-window            # or wrap in Probe.app (see git history)
```

`Probe.app/` in this directory is the ad-hoc-signed bundle variant
(`LSUIElement`, bundle id `local.freebuff.lockprobe`).
