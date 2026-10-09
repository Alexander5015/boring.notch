//
//  ThumbnailService.swift
//  boringNotch
//
//  Created by Alexander on 2025-10-07.
//

import Foundation
import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

actor ThumbnailService {
    static let shared = ThumbnailService()

    // Use NSCache for automatic memory management and thread safety
    private let cache = NSCache<NSString, CGImage>()
    private var pendingRequests: [String: Task<CGImage?, Never>] = [:]
    private let thumbnailGenerator = QLThumbnailGenerator.shared
    private let maxCacheSize = 100
    private let maxCacheCostBytes = 8 * 1024 * 1024

    private init() {
        cache.countLimit = maxCacheSize
        cache.totalCostLimit = maxCacheCostBytes
    }

    func thumbnail(for url: URL, size: CGSize) async -> CGImage? {
        let cacheKey = url.path as NSString

        if let cachedImage = cache.object(forKey: cacheKey) {
            return cachedImage
        }

        let stringKey = cacheKey as String
        if let pending = pendingRequests[stringKey] {
            return await pending.value
        }

        let task = Task<CGImage?, Never> {
            // Generate image directly
            let sendableImage = await generateQuickLookThumbnail(for: url, size: size)

            if let validImage = sendableImage {
                cache.setObject(
                    validImage,
                    forKey: cacheKey,
                    cost: validImage.bytesPerRow * validImage.height
                )
            }

            pendingRequests[stringKey] = nil
            return sendableImage
        }

        pendingRequests[stringKey] = task
        return await task.value
    }

    func clearCache() {
        cache.removeAllObjects()
    }

    func clearCache(for url: URL) {
        cache.removeObject(forKey: url.path as NSString)
    }

    private func generateQuickLookThumbnail(for url: URL, size: CGSize) async -> CGImage? {
        let scale = await MainActor.run { NSScreen.main?.backingScaleFactor ?? 2.0 }

        return await url.accessSecurityScopedResource { scopedURL -> CGImage? in
            let request = QLThumbnailGenerator.Request(
                fileAt: scopedURL,
                size: size,
                scale: scale,
                representationTypes: .all
            )
            request.iconMode = true

            let representation = try? await thumbnailGenerator.generateBestRepresentation(for: request)
            guard let rep = representation else { return nil }
            return rep.cgImage
        }
    }
}
