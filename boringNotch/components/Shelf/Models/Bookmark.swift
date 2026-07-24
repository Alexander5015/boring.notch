//
//  Bookmark.swift
//  boringNotch
//
//  Created by Alexander on 2025-10-08.
//

import Foundation
import AppKit
import UniformTypeIdentifiers

struct ResolvedShelfFile: Equatable, Sendable {
    let url: URL
    let refreshedBookmarkData: Data?
    let displayName: String
    let isDirectory: Bool
    let contentTypeIdentifier: String?

    init(
        url: URL,
        refreshedBookmarkData: Data?,
        displayName: String,
        isDirectory: Bool = false,
        contentTypeIdentifier: String? = nil
    ) {
        self.url = url
        self.refreshedBookmarkData = refreshedBookmarkData
        self.displayName = displayName
        self.isDirectory = isDirectory
        self.contentTypeIdentifier = contentTypeIdentifier
    }
}

enum ShelfFileResolutionPhase: Equatable, Sendable {
    case loading
    case available(ResolvedShelfFile)
    case unavailable
}

struct ShelfFileResolutionState: Sendable {
    private(set) var phase: ShelfFileResolutionPhase = .loading
    private var generation: UInt = 0

    mutating func begin() -> UInt {
        generation &+= 1
        phase = .loading
        return generation
    }

    @discardableResult
    mutating func timeOut(generation candidate: UInt) -> Bool {
        guard candidate == generation, phase == .loading else { return false }
        phase = .unavailable
        return true
    }

    @discardableResult
    mutating func finish(_ file: ResolvedShelfFile?, generation candidate: UInt) -> Bool {
        guard candidate == generation else { return false }
        phase = file.map(ShelfFileResolutionPhase.available) ?? .unavailable
        return true
    }
}

struct ShelfBookmarkResolver: Sendable {
    private let resolution: @Sendable (Data) -> ResolvedShelfFile?

    init(resolution: @escaping @Sendable (Data) -> ResolvedShelfFile?) {
        self.resolution = resolution
    }

    func resolve(_ data: Data) async -> ResolvedShelfFile? {
        let resolution = self.resolution
        return await Task.detached(priority: .utility) {
            resolution(data)
        }.value
    }
}

struct Bookmark: Sendable, Equatable, Codable {
    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(url: URL) throws {
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else {
            throw NSError(domain: "Bookmark", code: 1, userInfo: [NSLocalizedDescriptionKey: "Not a valid file URL or file does not exist at \(url.path)"])
        }
        do {
            let bookmark = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            NSLog("✅ Successfully created bookmark for \(url.path)")
            self.data = bookmark
        } catch {
            NSLog("❌ Failed to create bookmark for \(url.path): \(error.localizedDescription)")
            throw error
        }
    }

    func resolve() -> (url: URL?, refreshedData: Data?) {
        guard !data.isEmpty else { return (nil, nil) }
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if isStale, let newData = try? url.bookmarkData(options: [.withSecurityScope]) {
                NSLog("⚠️ Bookmark was stale for \(url.path), refreshed")
                return (url, newData)
            }
            return (url, nil)
        } catch {
            NSLog("❌ Failed to resolve bookmark: \(error.localizedDescription)")
            return (nil, nil)
        }
    }

    /// Simple URL resolution without refresh tracking. Use for read-only access.
    var resolvedURL: URL? {
        resolve().url
    }

    func validate() async -> Bool {
        let (url, _) = resolve()
        guard let url = url else { return false }
        return url.accessSecurityScopedResource { url in
            FileManager.default.fileExists(atPath: url.path)
        }
    }

    func withAccess<T: Sendable>(_ block: @Sendable (URL) async throws -> T) async rethrows -> T? {
        guard let url = resolvedURL else { return nil }
        return try await url.accessSecurityScopedResource { url in
            try await block(url)
        }
    }

    func withAccess<T>(_ block: (URL) throws -> T) rethrows -> T? {
        guard let url = resolvedURL else { return nil }
        return try url.accessSecurityScopedResource { url in
            try block(url)
        }
    }
}

extension ShelfBookmarkResolver {
    static let live = ShelfBookmarkResolver { bookmarkData in
        let result = Bookmark(data: bookmarkData).resolve()
        guard let url = result.url else { return nil }
        let resourceValues = try? url.resourceValues(
            forKeys: [.contentTypeKey, .isDirectoryKey, .localizedNameKey]
        )
        return ResolvedShelfFile(
            url: url,
            refreshedBookmarkData: result.refreshedData,
            displayName: shelfDisplayName(for: url, localizedName: resourceValues?.localizedName),
            isDirectory: resourceValues?.isDirectory ?? false,
            contentTypeIdentifier: resourceValues?.contentType?.identifier
        )
    }
}

private func shelfDisplayName(for url: URL, localizedName: String?) -> String {
    if url.pathExtension.lowercased() == "json", url.path.contains("TextBlocks") {
        struct TextBlockData: Codable {
            let content: String
            let title: String?

            var displayTitle: String {
                if let title, !title.isEmpty { return title }
                let firstLine = content.components(separatedBy: .newlines).first ?? content
                return firstLine.count > 50 ? String(firstLine.prefix(47)) + "..." : firstLine
            }
        }

        if let data = try? Data(contentsOf: url) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let textData = try? decoder.decode(TextBlockData.self, from: data) {
                return textData.displayTitle
            }
        }
    } else if url.pathExtension.lowercased() == "webloc", url.path.contains("WebLocs"),
              let data = try? Data(contentsOf: url),
              let propertyList = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let urlString = propertyList["URL"] as? String {
        return (propertyList["Title"] as? String) ?? urlString
    }

    return localizedName ?? url.lastPathComponent
}
