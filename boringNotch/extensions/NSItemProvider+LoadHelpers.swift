//
//  NSItemProvider+LoadHelpers.swift
//  boringNotch
//
//  Created by Alexander on 2025-09-24.
//

import AppKit
import Foundation
import UniformTypeIdentifiers

extension UTType {
    /// Types accepted by the shelf, including AppKit's documented file-promise types.
    static var boringNotchShelfDropTypes: [UTType] {
        var types: [UTType] = [.fileURL, .url, .utf8PlainText, .plainText, .data, .image]
        for identifier in NSFilePromiseReceiver.readableDraggedTypes {
            guard let type = UTType(identifier), !types.contains(type) else { continue }
            types.append(type)
        }
        return types
    }
}

enum PromisedFileRepresentation {
    case notAvailable
    case delivered(URL)
}

extension NSItemProvider {
    func extractItem() async -> URL? {
        return await loadFileURL(typeIdentifier: UTType.item.identifier)
    }

    /// Detects if this provider supplies a regular file URL.
    func extractFileURL() async -> URL? {
        guard hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { return nil }
        return await loadFileURL(typeIdentifier: UTType.fileURL.identifier)
    }

    /// Loads an asynchronously supplied file representation.
    ///
    /// NSItemProvider owns the representation URL and may remove it when its callback
    /// returns. Copy it to app-owned storage before resuming the continuation.
    func extractPromisedFileURL() async -> PromisedFileRepresentation {
        let identifiers = registeredTypeIdentifiers
        let promiseTypes = Set(NSFilePromiseReceiver.readableDraggedTypes)
        let hasPromiseType = identifiers.contains { promiseTypes.contains($0) }

        let representationType: UTType?
        if hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            // A provider can expose a file URL that is not ready yet. Ask for file contents.
            representationType = .item
        } else {
            representationType = identifiers
                .compactMap { UTType($0) }
                .first { type in
                    let isFileContent = type.conforms(to: .content) || type.conforms(to: .directory)
                    let isGenericType = type == .data || type == .item || type == .url || type == .fileURL
                    let isText = type.conforms(to: .text)
                    return isFileContent && !isGenericType && (hasPromiseType || !isText)
                }
        }

        guard let representationType else { return .notAvailable }
        let suggestedName = self.suggestedName

        return await withCheckedContinuation { continuation in
            _ = loadFileRepresentation(for: representationType, openInPlace: false) { url, _, error in
                guard error == nil else {
                    Log.general.error(
                        "Failed to load promised file representation for \(representationType.identifier): \(error!.localizedDescription)"
                    )
                    continuation.resume(returning: .notAvailable)
                    return
                }

                guard let url, url.isFileURL, FileManager.default.fileExists(atPath: url.path) else {
                    Log.general.error(
                        "Promised file representation for \(representationType.identifier) returned no valid file."
                    )
                    continuation.resume(returning: .notAvailable)
                    return
                }

                guard let preservedURL = TemporaryFileStorageService.createTemporaryCopy(
                    of: url,
                    suggestedName: suggestedName
                ) else {
                    continuation.resume(returning: .notAvailable)
                    return
                }
                continuation.resume(returning: .delivered(preservedURL))
            }
        }
    }

    /// Loads raw data for the given type identifier
    func loadData() async -> Data? {
        NSLog(String(describing: self.registeredTypeIdentifiers))
        guard hasItemConformingToTypeIdentifier(UTType.data.identifier) else { return nil }
        return await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            loadItem(forTypeIdentifier: UTType.data.identifier, options: nil) { item, error in
                if let error = error {
                    Log.general.error("Error loading data for type \(UTType.data.identifier): \(error.localizedDescription)")
                    cont.resume(returning: nil)
                    return
                }
                if let url = item as? URL, let data = try? Data(contentsOf: url) {
                    if !url.absoluteString.contains("com.apple.SwiftUI.filePromises") {
                        cont.resume(returning: nil)
                        return
                    }
                    self.suggestedName = self.suggestedName ?? url.lastPathComponent

                    let fileManager = FileManager.default
                    let folderURL = url.deletingLastPathComponent()

                    do {
                        // Delete the file first
                        try fileManager.removeItem(at: url)
                        Log.general.debug("Deleted file: \(url.path)")

                        // Check folder contents
                        let contents = try fileManager.contentsOfDirectory(atPath: folderURL.path)
                        if contents.isEmpty {
                            try fileManager.removeItem(at: folderURL)
                            Log.general.debug("Folder was empty, deleted folder: \(folderURL.path)")
                        } else {
                            Log.general.debug("Folder not deleted — it still contains \(contents.count) item(s).")
                        }
                    } catch {
                        Log.general.error("Error: \(error.localizedDescription)")
                    }

                    cont.resume(returning: data)
                } else if let data = item as? Data {
                    cont.resume(returning: data)
                } else {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    /// Attempts to extract a URL (web link) from the provider
    func extractURL() async -> URL? {
        if self.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let url = await loadURL(typeIdentifier: UTType.url.identifier) {
                // Validate URL
                guard url.scheme != nil else { return nil }
                return url
            }
        }

        return nil
    }

    func extractText() async -> String? {
        let textTypes = [UTType.utf8PlainText.identifier, UTType.plainText.identifier]

        for typeIdentifier in textTypes where self.hasItemConformingToTypeIdentifier(typeIdentifier) {
            if let text = await loadText(typeIdentifier: typeIdentifier) {
                return text
            }
        }

        return nil
    }

    /// Loads a file URL from the provider for the given type identifier.
    func loadFileURL(typeIdentifier: String) async -> URL? {
        await withCheckedContinuation { (cont: CheckedContinuation<URL?, Never>) in
            self.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, error in
                if let error = error {
                    Log.general.error("❌ Error loading item for type \(typeIdentifier): \(error.localizedDescription)")
                    cont.resume(returning: nil)
                    return
                }
                var resolvedURL: URL?
                if let url = item as? URL {
                    // Direct URL provided
                    resolvedURL = url
                } else if let data = item as? Data {
                    // Some providers hand out a UTF-8 file URL string, others a bookmark. Prefer parsing string first.
                    if let string = String(data: data, encoding: .utf8) {
                        if let url = URL(string: string) {
                            resolvedURL = url
                        } else if string.hasPrefix("/") {
                            // Plain file system path
                            resolvedURL = URL(fileURLWithPath: string)
                        }
                    }
                    if resolvedURL == nil {
                        // Fallback: try treating the data as a bookmark
                        let bookmark = Bookmark(data: data)
                        resolvedURL = bookmark.resolvedURL
                    }
                } else if let string = item as? String {
                    if let url = URL(string: string) {
                        resolvedURL = url
                    } else if string.hasPrefix("/") {
                        resolvedURL = URL(fileURLWithPath: string)
                    }
                }
                cont.resume(returning: resolvedURL)
            }
        }
    }

    /// Loads a URL from the provider for the given type identifier.
    func loadURL(typeIdentifier: String) async -> URL? {
        await withCheckedContinuation { (cont: CheckedContinuation<URL?, Never>) in
            self.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, error in
                if error != nil {
                    cont.resume(returning: nil)
                    return
                }

                if let url = item as? URL {
                    cont.resume(returning: url)
                } else if let data = item as? Data {
                    if let string = String(data: data, encoding: .utf8) {
                        if let url = URL(string: string) {
                            cont.resume(returning: url)
                            return
                        } else if string.hasPrefix("/") {
                            cont.resume(returning: URL(fileURLWithPath: string))
                            return
                        }
                    }
                    cont.resume(returning: nil)
                } else if let string = item as? String {
                    if let url = URL(string: string) {
                        cont.resume(returning: url)
                    } else if string.hasPrefix("/") {
                        cont.resume(returning: URL(fileURLWithPath: string))
                    } else {
                        cont.resume(returning: nil)
                    }
                } else {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    /// Loads text from the provider for the given type identifier.
    func loadText(typeIdentifier: String) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            self.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, error in
                if error != nil {
                    cont.resume(returning: nil)
                    return
                }

                if let string = item as? String {
                    cont.resume(returning: string)
                } else if let data = item as? Data,
                          let string = String(data: data, encoding: .utf8) {
                    cont.resume(returning: string)
                } else {
                    cont.resume(returning: nil)
                }
            }
        }
    }
}
