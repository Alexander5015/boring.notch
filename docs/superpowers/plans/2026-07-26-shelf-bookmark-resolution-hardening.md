# Shelf Bookmark Resolution Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent duplicate stalled bookmark work, preserve usable cached shelf files during refreshes, and perform bookmark metadata reads within security-scoped access.

**Architecture:** `ShelfBookmarkResolver` will use a bounded blocking executor plus an actor-managed single-flight registry keyed by bookmark data. `ShelfStateViewModel` will return matching cache entries immediately while refresh work proceeds, and the live resolver will collect metadata inside a security-scoped closure.

**Tech Stack:** Swift 6, Foundation structured concurrency, `OperationQueue`, AppKit security-scoped bookmarks, Xcode macOS application build

## Global Constraints

- Do not introduce a new package dependency.
- Do not change shelf persistence encoding.
- Do not add process or XPC isolation in this change.
- Preserve the existing two-second presentation timeout.

---

### Task 1: Add bounded single-flight bookmark execution

**Files:**
- Modify: `boringNotch/components/Shelf/Models/Bookmark.swift`
- Create: `Tests/ShelfBookmarkResolverRegression.swift`

**Interfaces:**
- Consumes: `ShelfBookmarkResolver.init(resolution:)` and `resolve(_:)`
- Produces: unchanged `ShelfBookmarkResolver.resolve(_:) async -> ResolvedShelfFile?` behavior with one active blocking operation per bookmark payload

- [x] **Step 1: Write the resolver regression harness**

Create a standalone async executable that injects a blocking resolution closure, starts two resolutions with identical `Data`, and exits unsuccessfully unless the closure was invoked exactly once.

- [x] **Step 2: Run the harness to verify the current implementation fails**

Compile `Bookmark.swift`, `URL+SecurityScoped.swift`, and the harness with `swiftc`, then run the executable. Expected result before implementation: the harness reports two underlying calls.

- [x] **Step 3: Implement the bounded executor and single-flight registry**

Add a sendable executor backed by `OperationQueue` with a small `maxConcurrentOperationCount`. Add an actor that stores tokenized tasks by bookmark data, reuses an existing task, and removes only the entry matching the completed token. Route `ShelfBookmarkResolver.resolve(_:)` through this registry.

- [x] **Step 4: Run the harness to verify it passes**

Recompile and run the same standalone executable. Expected result: one underlying call and exit status zero.

### Task 2: Preserve cached files while refreshing

**Files:**
- Modify: `boringNotch/components/Shelf/ViewModels/ShelfStateViewModel.swift`

**Interfaces:**
- Consumes: `prefetchFileResolution(for:refresh:restartPending:)`
- Produces: cache-first `resolveFile(for:refresh:restartPending:)` and bulk resolution that waits only for uncached item IDs

- [x] **Step 1: Change single-item resolution to cache-first refresh**

When bookmark data matches a cached entry, return the cached file. If `refresh` is true, call the prefetch method first so cache refresh remains asynchronous.

- [x] **Step 2: Change bulk waiting to target uncached items**

Compute the set of file IDs lacking cache entries after prefetch. Poll pending state only for that set, and remove the `pendingFileResolutions[item.id] == nil` requirement from result construction.

- [x] **Step 3: Inspect all call sites**

Confirm Open, Share, Quick Look, Copy, Finder, compression, and image actions continue requesting refresh where appropriate while now receiving cached results immediately.

### Task 3: Scope metadata access and verify integration

**Files:**
- Modify: `boringNotch/components/Shelf/Models/Bookmark.swift`

**Interfaces:**
- Consumes: `URL.accessSecurityScopedResource(accessor:)`
- Produces: `ResolvedShelfFile` populated while security-scoped access covers metadata and display-name reads

- [x] **Step 1: Wrap metadata extraction**

Move resource-value lookup, `shelfDisplayName`, and `ResolvedShelfFile` construction into `url.accessSecurityScopedResource`.

- [x] **Step 2: Build the macOS application**

Run the `boringNotch` Xcode scheme for the macOS destination with derived data and cloned packages under `/tmp`. Expected result: `BUILD SUCCEEDED`.

- [x] **Step 3: Run repository checks**

Run the standalone regression harness and `git diff --check`. Expected result: both commands exit zero.

- [x] **Step 4: Review the final diff**

Confirm the change is limited to the resolver, cache behavior, regression harness, and approved design/plan documentation.
