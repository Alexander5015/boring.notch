# Shelf Bookmark Resolution Hardening Design

## Context

Shelf bookmarks can block inside Foundation while resolving security-scoped URLs. The current branch moves that work off the main actor and gives each shelf item a two-second presentation timeout, but a timed-out retry can start another detached blocking task, refreshes can hide otherwise valid cached files from user actions, and metadata is read before security-scoped access begins.

## Goals

- Keep the app responsive when bookmark resolution stalls.
- Permit at most one blocking resolution for the same bookmark data at a time.
- Keep valid cached files usable while a refresh is pending or stalled.
- Read file metadata and stored display-name content with security-scoped access active.
- Preserve the current unavailable-file and retry presentation.

## Non-goals

- Forcefully interrupt Foundation's synchronous bookmark resolver in-process.
- Introduce a new helper executable or XPC protocol.
- Restructure unrelated shelf UI or persistence code.

## Design

### Bounded, single-flight bookmark resolution

`ShelfBookmarkResolver` will delegate blocking work to a small shared operation executor instead of spawning unrestricted detached tasks. The executor will cap concurrent blocking operations so stalled bookmark calls cannot consume the Swift cooperative executor or grow without bound.

An actor-owned dictionary keyed by bookmark `Data` will retain the task for each active resolution. Concurrent callers and retries for the same bookmark will await that task. The entry is removed only after the underlying operation returns, so cancelling a UI waiter cannot create a duplicate blocking operation.

Logical pending entries in `ShelfStateViewModel` may still be invalidated when a shelf item's presentation times out. A later retry creates a new logical waiter but joins the resolver's existing underlying operation.

### Cache-first refresh behavior

When `resolveFile(for:refresh:)` has a cache entry matching the current bookmark, it will return the cached file immediately. If refresh was requested, it will also schedule a background refresh through the existing prefetch path.

Bulk resolution will wait only for file items that lack cache entries. Its result will include cached files even when a refresh remains pending. This keeps Open, Share, Quick Look, Copy, Finder, compression, and image actions functional during a slow refresh.

### Security-scoped metadata

After resolving a bookmark URL, the live resolver will begin security-scoped access before requesting resource values or deriving the friendly display name. The scope will cover `resourceValues`, stored text-block reads, and `.webloc` reads, and will end before the immutable `ResolvedShelfFile` is returned.

## Error and timeout behavior

- A presentation timeout continues to mark an unresolved shelf item unavailable.
- Retry invalidates only the logical state-model waiter; it does not duplicate the underlying blocking operation.
- A failed operation clears its single-flight entry, allowing a later retry to perform a genuinely new attempt.
- A stalled background refresh does not displace or hide a valid cached file.
- Hard termination of a truly stuck Foundation call remains a future process-isolation improvement.

## Verification

- A standalone Swift regression harness will issue two concurrent resolutions for identical bookmark data and assert that the injected blocking resolver runs once.
- The application scheme will be built with the repository's macOS Xcode configuration.
- `git diff --check` and a focused final diff review will verify formatting and scope.
