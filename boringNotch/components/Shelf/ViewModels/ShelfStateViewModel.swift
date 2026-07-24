//
//  ShelfStateViewModel.swift
//  boringNotch
//
//  Created by Alexander on 2025-10-09.

import Foundation
import AppKit

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

    private struct CachedFileResolution {
        let bookmarkData: Data
        let file: ResolvedShelfFile
    }

    private struct PendingFileResolution {
        let token: UUID
        let bookmarkData: Data
        let task: Task<ResolvedShelfFile?, Never>
    }

    private var cachedFileResolutions: [UUID: CachedFileResolution] = [:]
    private var pendingFileResolutions: [UUID: PendingFileResolution] = [:]

    private init() {
        items = ShelfPersistenceService.shared.load()
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
        let identityURL = item.fileIdentity.map(URL.init(fileURLWithPath:))
        let cachedURL = cachedFileResolutions[item.id]?.file.url ?? identityURL
        let pendingTask = pendingFileResolutions[item.id]?.task

        if item.isTemporary {
            if let cachedURL {
                Task {
                    await TemporaryFileStorageService.shared.removeTemporaryFileIfNeededAsync(at: cachedURL)
                }
            } else if let pendingTask {
                Task {
                    if let url = await pendingTask.value?.url {
                        await TemporaryFileStorageService.shared.removeTemporaryFileIfNeededAsync(at: url)
                    }
                }
            } else if case .file(let bookmarkData) = item.kind {
                Task {
                    if let url = await ShelfBookmarkResolver.live.resolve(bookmarkData)?.url {
                        await TemporaryFileStorageService.shared.removeTemporaryFileIfNeededAsync(at: url)
                    }
                }
            }
        }

        cachedFileResolutions[item.id] = nil
        pendingFileResolutions[item.id] = nil
        items.removeAll { $0.id == item.id }
    }

    func resolvedFileURL(for item: ShelfItem) -> URL? {
        cachedFileResolutions[item.id]?.file.url
    }

    func resolvedFile(for item: ShelfItem) -> ResolvedShelfFile? {
        cachedFileResolutions[item.id]?.file
    }

    func resolveFile(
        for item: ShelfItem,
        refresh: Bool = false,
        restartPending: Bool = false
    ) async -> ResolvedShelfFile? {
        let currentItem = items.first(where: { $0.id == item.id }) ?? item
        guard case .file(let bookmarkData) = currentItem.kind else { return nil }

        if !refresh,
           let cached = cachedFileResolutions[item.id],
           cached.bookmarkData == bookmarkData {
            return cached.file
        }

        let pending = pendingResolution(
            for: item.id,
            bookmarkData: bookmarkData,
            restart: restartPending
        )
        let file = await pending.task.value
        guard pendingFileResolutions[item.id]?.token == pending.token else {
            return cachedFileResolutions[item.id]?.file
        }
        applyResolution(file, for: item.id, bookmarkData: bookmarkData, token: pending.token)
        return cachedFileResolutions[item.id]?.file
    }

    func prefetchFileResolution(for items: [ShelfItem], refresh: Bool = false) {
        for item in items {
            prefetchFileResolution(for: item, refresh: refresh)
        }
    }

    @discardableResult
    func prefetchFileResolution(
        for item: ShelfItem,
        refresh: Bool = false,
        restartPending: Bool = false
    ) -> UUID? {
        let currentItem = items.first(where: { $0.id == item.id }) ?? item
        guard case .file(let bookmarkData) = currentItem.kind else { return nil }
        if !refresh,
           let cached = cachedFileResolutions[item.id],
           cached.bookmarkData == bookmarkData {
            return nil
        }

        let pending = pendingResolution(
            for: item.id,
            bookmarkData: bookmarkData,
            restart: restartPending
        )
        Task { [weak self] in
            let file = await pending.task.value
            self?.applyResolution(
                file,
                for: item.id,
                bookmarkData: bookmarkData,
                token: pending.token
            )
        }
        return pending.token
    }

    func invalidatePendingResolution(
        for itemID: UUID,
        bookmarkData: Data,
        token: UUID
    ) {
        guard let pending = pendingFileResolutions[itemID],
              pending.bookmarkData == bookmarkData,
              pending.token == token else {
            return
        }

        pendingFileResolutions[itemID] = nil
        pending.task.cancel()
    }

    func resolvedFilesByItemID(
        for items: [ShelfItem],
        refresh: Bool = false,
        timeout: Duration = .seconds(2)
    ) async -> [UUID: ResolvedShelfFile] {
        let fileItems = items.filter {
            if case .file = $0.kind { return true }
            return false
        }
        guard !fileItems.isEmpty else { return [:] }

        prefetchFileResolution(for: fileItems, refresh: refresh)
        let itemIDs = Set(fileItems.map(\.id))
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)

        while !Task.isCancelled,
              clock.now < deadline,
              pendingFileResolutions.keys.contains(where: itemIDs.contains) {
            try? await Task.sleep(for: .milliseconds(25))
        }

        guard !Task.isCancelled else { return [:] }
        return Dictionary(uniqueKeysWithValues: fileItems.compactMap { item in
            guard pendingFileResolutions[item.id] == nil else { return nil }
            guard let file = cachedFileResolutions[item.id]?.file else { return nil }
            return (item.id, file)
        })
    }

    func resolvedFiles(
        for items: [ShelfItem],
        refresh: Bool = false,
        timeout: Duration = .seconds(2)
    ) async -> [ResolvedShelfFile] {
        let filesByItemID = await resolvedFilesByItemID(
            for: items,
            refresh: refresh,
            timeout: timeout
        )
        return items.compactMap { filesByItemID[$0.id] }
    }

    func resolvedFileURLs(
        for items: [ShelfItem],
        refresh: Bool = false,
        timeout: Duration = .seconds(2)
    ) async -> [URL] {
        await resolvedFiles(for: items, refresh: refresh, timeout: timeout).map(\.url)
    }

    private func pendingResolution(
        for itemID: UUID,
        bookmarkData: Data,
        restart: Bool = false
    ) -> PendingFileResolution {
        if !restart,
           let pending = pendingFileResolutions[itemID],
           pending.bookmarkData == bookmarkData {
            return pending
        }

        let pending = PendingFileResolution(
            token: UUID(),
            bookmarkData: bookmarkData,
            task: Task {
                await ShelfBookmarkResolver.live.resolve(bookmarkData)
            }
        )
        pendingFileResolutions[itemID] = pending
        return pending
    }

    func updateBookmark(for item: ShelfItem, bookmark: Data, resolvedURL: URL? = nil) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        if case .file = items[idx].kind {
            let fileIdentity = resolvedURL.map(ShelfItem.fileIdentity(for:)) ?? items[idx].fileIdentity
            items[idx] = ShelfItem(
                id: items[idx].id,
                kind: .file(bookmark: bookmark),
                isTemporary: items[idx].isTemporary,
                fileIdentity: fileIdentity
            )

            cachedFileResolutions[item.id] = nil
        }
    }

    private func applyResolution(
        _ file: ResolvedShelfFile?,
        for itemID: UUID,
        bookmarkData: Data,
        token: UUID
    ) {
        guard pendingFileResolutions[itemID]?.token == token else { return }
        pendingFileResolutions[itemID] = nil

        guard let file,
              let index = items.firstIndex(where: { $0.id == itemID }),
              case .file(let currentBookmarkData) = items[index].kind,
              currentBookmarkData == bookmarkData else {
            cachedFileResolutions[itemID] = nil
            return
        }

        let effectiveBookmarkData = file.refreshedBookmarkData ?? bookmarkData
        let current = items[index]
        let fileIdentity = ShelfItem.fileIdentity(for: file.url)
        if effectiveBookmarkData != bookmarkData || current.fileIdentity != fileIdentity {
            items[index] = ShelfItem(
                id: current.id,
                kind: .file(bookmark: effectiveBookmarkData),
                isTemporary: current.isTemporary,
                fileIdentity: fileIdentity
            )
        }

        cachedFileResolutions[itemID] = CachedFileResolution(
            bookmarkData: effectiveBookmarkData,
            file: ResolvedShelfFile(
                url: file.url,
                refreshedBookmarkData: file.refreshedBookmarkData,
                displayName: file.displayName,
                isDirectory: file.isDirectory,
                contentTypeIdentifier: file.contentTypeIdentifier
            )
        )
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

    @MainActor
    func flushSync() {
        // Cancel any scheduled persistence task (we'll save synchronously now)
        persistenceTask?.cancel()
        persistenceTask = nil

        // Perform a synchronous, atomic save to disk
        ShelfPersistenceService.shared.save(self.items)
    }
}
