# SLSSpaceAddWindowsAndRemoveFromSpaces returns kCGErrorInvalidConnection on macOS 27 — appears gated by calling binary's build context

## Summary

On macOS 27.0.0, `SLSSpaceAddWindowsAndRemoveFromSpaces` (and
`SLSAddWindowsToSpaces`) return `kCGErrorInvalidConnection` (CGError 3) for
**every process we tested except one Developer ID-signed app built against
the macOS 26.5 SDK** — including that same app's own code when rebuilt
ad-hoc against the 27.0 SDK. Space *creation*, `SLSSpaceSetAbsoluteLevel`,
`SLSShowSpaces`, and display-space reads all still succeed; only the
window↔space *write* calls are refused.

An app in our project (boring.notch) delegates its lock-screen panel with
exactly these calls. Its CI-signed release build (Team ID, linked SDK 26.5)
**still works on macOS 27**. Everything we built locally fails.

## Test matrix (probe available; see repro below)

Every run: `SLSMainConnectionID` ok, `SLSSpaceCreate(cid, 1, 0)` ok,
`SLSSpaceSetAbsoluteLevel(…, 400)` ok, `SLSShowSpaces` ok,
`SLSCopyManagedDisplaySpaces` ok (reads work).

| Configuration | `SLSSpaceAddWindowsAndRemoveFromSpaces` |
|---|---|
| Bare CLI process (own window) | err 3 |
| Live `NSApplication` run loop (own window) | err 3 |
| Ad-hoc-signed `.app` bundle (own window) | err 3 |
| Same + **Accessibility TCC granted** (`AXIsProcessTrusted() == true` observed) | err 3 |
| Same + App Sandbox entitlement | err 3 |
| 27.0-SDK binary relinked with `-platform_version macos 14.0 26.5` | err 3 |
| Own `NSPanel` at `CGShieldingWindowLevel()` | err 3 |
| Foreign-process window (child process we spawned) | err 3 |
| `SLSAddWindowsToSpaces` variant | err 3 |
| `cid = 0` (CGSMainConnectionID) | space creation itself refused (`0x10000003`) |
| **CI release app: Developer ID team-signed, linked SDK 26.5** | **success** (lock-screen surface appears; user-confirmed) |

Environment: macOS 27.0.0 (25A…), Xcode with macOS 27.0 SDK.

## Observations

- Reads and space creation work from any process; only window↔space writes
  are gated.
- Accessibility TCC and App Sandbox make no difference.
- Relabeling a 27.0-SDK binary's `LC_BUILD_VERSION` to claim SDK 26.5 is
  **not** sufficient — so the gate is not purely the recorded SDK version.
- The one working binary differs by (a) real team Developer ID signature,
  (b) genuinely linked 26.5 SDK, (c) full TCC grants. Local keychains have no
  signing identity, so the signature/TCC split could not be isolated further.

## Questions

1. Is this gating intentional (i.e., is cross-space window delegation being
   deprecated for non-Apple processes)?
2. Which factor is decisive: Developer ID signature, linked SDK, TCC state,
   or a combination?

## Repro

`swiftc` a minimal AppKit app (NSApplication run loop, one borderless window),
bind `SLSMainConnectionID` / `SLSSpaceCreate` / `SLSSpaceSetAbsoluteLevel` /
`SLSShowSpaces` / `SLSSpaceAddWindowsAndRemoveFromSpaces` from
`/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight`,
create a space, pin it at absolute level 400, then attempt
`SLSSpaceAddWindowsAndRemoveFromSpaces(cid, space, [ownWindowNumber], 7)`.
Observe CGError 3 on macOS 27 with an ad-hoc signature, and success with the
26.5-SDK Developer ID-signed binary described above.
