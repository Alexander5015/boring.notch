# File-drop and process-lifecycle change record

- **Date brief received:** 2026-10-09
- **Implementer:** OpenAI assistant (independent implementation)
- **Target repository:** `Alexander5015/boring.notch`
- **Base branch:** `TheBoredTeam/boring.notch:dev`
- **Base commit:** `bf52277dc8fda94741f90772c8f35d7601dcdd1b`
- **Working branch:** `codex/file-drop-concurrency-2026-10-09`
- **Platform / language:** macOS application; Xcode project currently specifies Swift 5 language mode and a macOS 14.0 deployment target.

## Access restrictions and provenance

Implementation was derived from the supplied behavior brief, the target fork's source and existing test conventions, and official Apple API documentation. No third-party pull request, patch, implementation branch, or externally derived tests were used as implementation material. Tests in this change were authored independently from the acceptance criteria.

A working branch was briefly created in the parent repository before the fork destination was clarified. No file modifications were left on that parent branch; this change is committed only to the personal fork branch above.

## Sources consulted

- Apple Developer Documentation, `NSItemProvider.loadFileRepresentation(for:openInPlace:completionHandler:)`: https://developer.apple.com/documentation/foundation/nsitemprovider/loadfilerepresentation%28for%3Aopeninplace%3Acompletionhandler%3A%29
- Apple Developer Documentation, `Process.terminationHandler`: https://developer.apple.com/documentation/foundation/process/terminationhandler
- Apple Developer Documentation, `NSFilePromiseReceiver.receivePromisedFiles(atDestination:options:operationQueue:reader:)`: https://developer.apple.com/documentation/appkit/nsfilepromisereceiver/receivepromisedfiles%28atdestination%3Aoptions%3Aoperationqueue%3Areader%3A%29
- Apple Developer Documentation, Supporting Drag and Drop Through File Promises: https://developer.apple.com/documentation/appkit/supporting-drag-and-drop-through-file-promises
- Target fork source and its `boringNotchTests` XCTest conventions.

## Implementation notes

- Added file-representation fallback for promised/content-backed drops and copies the provider-owned file into an app-owned temporary directory before its callback ends.
- Included AppKit's documented file-promise drag types in shelf drop targets while retaining ordinary URL/text/data types.
- Ensured invalid or failed file representations do not become shelf items and retained the existing temporary-file cleanup model.
- Deduplicated repeated references to the same `NSItemProvider` before concurrent processing.
- Added an awaitable, MainActor-isolated shelf processing entry point so tests can synchronize on collection mutation.
- Added independent tests for background promised delivery, failed delivery, direct URL drops, multiple/repeated providers, actor-safe child termination, stop/shutdown behavior, and process exit status.
- No dependencies were added or existing dependencies changed.

## Tests and review

- **Tests added:** `boringNotchTests/FileDropAndProcessLifecycleTests.swift`
- **Test results:** Pending macOS/Xcode execution. This editing environment does not provide a macOS AppKit/Xcode runtime, so the XCTest target has not been executed locally.
- **Concurrency diagnostics/build:** Not yet run. Run the project build and full XCTest suite on macOS before release.
- **Implementation commit:** Recorded in the follow-up entry after commit creation.
- **Code provenance review:** Initial self-review performed on 2026-10-09; independent second-person provenance review remains outstanding.
- **Dependency/license review:** No new dependencies or incorporated third-party material; independent release review remains outstanding.
- **Outstanding concerns:** Validate actual drops from Finder, Safari, Mail, and other file-promise sources on macOS; confirm the project's configured CI/build covers the new test file.
