//
//  ShelfStateViewModel.swift
//  boringNotch
//
//  Created by Alexander on 2025-10-09.

import Foundation
import AppKit
import Defaults

@MainActor
final class ShelfStateViewModel: ObservableObject {
    static let shared = ShelfStateViewModel()

    @Published private(set) var items: [ShelfItem] = [] {
        didSet { schedulePersistence() }
    }

    @Published var isLoading: Bool = false

    var isEmpty: Bool { items.isEmpty }

    // Debounced persistence
    private var persistenceTask: Task<Void, Never>?
    private let persistenceDelay: Duration = .seconds(1)
    private var retentionCleanupTask: Task<Void, Never>?

    private init() {
        items = ShelfPersistenceService.shared.load()
        // Persist migration defaults for entries created before timestamps/pins existed.
        schedulePersistence()

        retentionCleanupTask = Task { @MainActor [weak self] in
            self?.cleanupExpiredItems()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    break
                }
                guard !Task.isCancelled, let self else { break }
                self.cleanupExpiredItems()
            }
        }
    }

    private func schedulePersistence() {
        persistenceTask?.cancel()
        persistenceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: self?.persistenceDelay ?? .seconds(1))
            guard let self = self, !Task.isCancelled else { return }
            await ShelfPersistenceService.shared.saveAsync(self.items)
        }
    }

    func add(_ newItems: [ShelfItem]) {
        guard !newItems.isEmpty else { return }
        var merged = items
        // Deduplicate by identityKey while preserving order (existing first)
        var seen: Set<String> = Set(merged.map { $0.identityKey })
        for it in newItems {
            let key = it.identityKey
            if !seen.contains(key) {
                merged.append(it)
                seen.insert(key)
            }
        }
        items = merged
    }

    func remove(_ item: ShelfItem) {
        item.cleanupStoredData()
        items.removeAll { $0.id == item.id }
    }

    func togglePinned(_ item: ShelfItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let current = items[index]
        items[index] = ShelfItem(
            id: current.id,
            kind: current.kind,
            isTemporary: current.isTemporary,
            createdAt: current.createdAt,
            isPinned: !current.isPinned
        )
    }

    /// Removes expired, unpinned entries from the shelf. Original files are only
    /// unlinked from the shelf; cleanupStoredData deletes only app-owned temporary files.
    func cleanupExpiredItems() {
        guard let duration = Defaults[.shelfRetentionPeriod].duration else { return }
        let cutoff = Date().addingTimeInterval(-duration)
        let expiredItems = items.filter { !$0.isPinned && $0.createdAt <= cutoff }
        guard !expiredItems.isEmpty else { return }

        let expiredIDs = Set(expiredItems.map(\.id))
        for item in expiredItems {
            item.cleanupStoredData()
        }
        items.removeAll { expiredIDs.contains($0.id) }
        Log.shelf.info("Removed \(expiredItems.count) expired shelf item(s)")
    }

    func updateBookmark(for item: ShelfItem, bookmark: Data) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        if case .file = items[idx].kind {
            let current = items[idx]
            items[idx] = ShelfItem(
                id: current.id,
                kind: .file(bookmark: bookmark),
                isTemporary: current.isTemporary,
                createdAt: current.createdAt,
                isPinned: current.isPinned
            )
        }
    }

    func load(_ providers: [NSItemProvider]) {
        guard !providers.isEmpty else { return }
        isLoading = true
        Task { [weak self] in
            let dropped = await ShelfDropService.items(from: providers)
            await MainActor.run {
                self?.add(dropped)
                self?.isLoading = false
            }
        }
    }

    func cleanupInvalidItems() {
        Task { [weak self] in
            guard let self else { return }
            var keep: [ShelfItem] = []
            for item in self.items {
                switch item.kind {
                case .file(let data):
                    let bookmark = Bookmark(data: data)
                    if await bookmark.validate() {
                        keep.append(item)
                    } else {
                        item.cleanupStoredData()
                    }
                default:
                    keep.append(item)
                }
            }
            await MainActor.run { self.items = keep }
        }
    }

    /// Resolves the file URL for an item and updates the bookmark if stale.
    /// Use this for user-initiated actions where bookmark refresh is desired.
    func resolveAndUpdateBookmark(for item: ShelfItem) -> URL? {
        guard case .file(let bookmarkData) = item.kind else { return nil }
        let bookmark = Bookmark(data: bookmarkData)
        let result = bookmark.resolve()
        if let refreshed = result.refreshedData, refreshed != bookmarkData {
            NSLog("Bookmark for \(item) stale; refreshing")
            updateBookmark(for: item, bookmark: refreshed)
        }
        return result.url
    }

    func resolveFileURLs(for items: [ShelfItem]) -> [URL] {
        items.compactMap { $0.fileURL }
    }

    @MainActor
    func flushSync() {
        // Cancel any scheduled persistence task (we'll save synchronously now)
        persistenceTask?.cancel()
        persistenceTask = nil

        // Perform a synchronous, atomic save to disk
        ShelfPersistenceService.shared.save(self.items)
    }
}
