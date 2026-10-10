//
//  ShelfDropService.swift
//  boringNotch
//
//  Created by Alexander on 2025-09-26.
//

import AppKit
import Foundation
import UniformTypeIdentifiers

struct ShelfDropService {
    static func items(from providers: [NSItemProvider]) async -> [ShelfItem] {
        var seenProviders = Set<ObjectIdentifier>()
        let uniqueProviders = providers.filter {
            seenProviders.insert(ObjectIdentifier($0)).inserted
        }

        // Process distinct providers concurrently for better performance with large drops.
        await withTaskGroup(of: ShelfItem?.self) { group in
            for provider in uniqueProviders {
                group.addTask {
                    await processProvider(provider)
                }
            }

            var results: [ShelfItem] = []
            results.reserveCapacity(uniqueProviders.count)

            for await item in group {
                if let item = item {
                    results.append(item)
                }
            }

            return results
        }
    }

    private static func processProvider(_ provider: NSItemProvider) async -> ShelfItem? {
        if let actualFileURL = await provider.extractFileURL(),
           let bookmark = createBookmark(for: actualFileURL) {
            return await ShelfItem(kind: .file(bookmark: bookmark), isTemporary: false)
        }

        switch await provider.extractPromisedFileURL() {
        case .delivered(let promisedURL):
            guard let bookmark = createBookmark(for: promisedURL) else {
                TemporaryFileStorageService.shared.removeTemporaryFileIfNeeded(at: promisedURL)
                return nil
            }
            return await ShelfItem(kind: .file(bookmark: bookmark), isTemporary: true)
        case .notAvailable:
            break
        }

        if let url = await provider.extractURL() {
            if url.isFileURL {
                if let bookmark = createBookmark(for: url) {
                    return await ShelfItem(kind: .file(bookmark: bookmark), isTemporary: false)
                }
            } else {
                return await ShelfItem(kind: .link(url: url), isTemporary: false)
            }
            return nil
        }

        if let text = await provider.extractText() {
            return await ShelfItem(kind: .text(string: text), isTemporary: false)
        }

        if let data = await provider.loadData() {
            if let tempDataURL = await TemporaryFileStorageService.shared.createTempFile(for: .data(data, suggestedName: provider.suggestedName)),
               let bookmark = createBookmark(for: tempDataURL) {
                return await ShelfItem(kind: .file(bookmark: bookmark), isTemporary: true)
            }
            return nil
        }

        if let fileURL = await provider.extractItem() {
            if let bookmark = createBookmark(for: fileURL) {
                return await ShelfItem(kind: .file(bookmark: bookmark), isTemporary: false)
            }
        }

        return nil
    }

    private static func createBookmark(for url: URL) -> Data? {
        return (try? Bookmark(url: url))?.data
    }
}
