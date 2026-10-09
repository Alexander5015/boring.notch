//
//  QuickShareService.swift
//  boringNotch
//
//  Created by Alexander on 2025-09-24.
//

import AppKit
import Foundation
import UniformTypeIdentifiers

/// Dynamic representation of a sharing provider discovered at runtime
struct QuickShareProvider: Identifiable, Hashable, Sendable {
    static let airDropId = "AirDrop"
    static let systemShareMenuId = "System Share Menu"
    static let systemShareMenu = QuickShareProvider(id: systemShareMenuId, supportsRawText: true)

    var id: String
    var supportsRawText: Bool

    /// AirDrop remains the preferred default; the UI resolves this against
    /// providers discovered when Quick Share is actually used.
    static var defaultProvider: QuickShareProvider {
        QuickShareProvider(id: airDropId, supportsRawText: false)
    }

    static func preferredProvider(from providers: [QuickShareProvider]) -> QuickShareProvider {
        providers.first(where: { $0.id == airDropId })
            ?? providers.first
            ?? .systemShareMenu
    }

    static func resolve(selectedID: String, from providers: [QuickShareProvider]) -> QuickShareProvider {
        if let selected = providers.first(where: { $0.id == selectedID }) {
            return selected
        }
        guard selectedID == defaultProvider.id else { return .systemShareMenu }
        return preferredProvider(from: providers)
    }
}

private actor ApplicationIconIndex {
    private var cachedURLsByName: [String: URL]?

    func urlsByName() -> [String: URL] {
        if let cachedURLsByName {
            return cachedURLsByName
        }

        var urlsByName: [String: URL] = [:]
        for root in Self.applicationSearchRoots {
            Self.indexApplications(in: root, into: &urlsByName)
        }

        cachedURLsByName = urlsByName
        return urlsByName
    }

    static func normalizedApplicationName(_ name: String) -> String {
        name
            .replacingOccurrences(of: ".app", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private static var applicationSearchRoots: [URL] {
        var roots = FileManager.default.urls(for: .applicationDirectory, in: .userDomainMask)
        roots.append(contentsOf: [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
            URL(fileURLWithPath: "/System/Library/CoreServices/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app/Contents/Applications", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer/Applications", isDirectory: true)
        ])
        return roots
    }

    private static func indexApplications(in root: URL, into urlsByName: inout [String: URL]) {
        guard FileManager.default.fileExists(atPath: root.path),
              let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isApplicationKey, .localizedNameKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
              ) else {
            return
        }

        for case let url as URL in enumerator where url.pathExtension == "app" {
            indexApplication(url, into: &urlsByName)
        }
    }

    private static func indexApplication(_ applicationURL: URL, into urlsByName: inout [String: URL]) {
        cacheApplicationName(applicationURL.deletingPathExtension().lastPathComponent, for: applicationURL, in: &urlsByName)

        if let localizedName = try? applicationURL.resourceValues(forKeys: [.localizedNameKey]).localizedName {
            cacheApplicationName(localizedName, for: applicationURL, in: &urlsByName)
        }

        guard let bundle = Bundle(url: applicationURL) else { return }

        if let bundleName = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String {
            cacheApplicationName(bundleName, for: applicationURL, in: &urlsByName)
        }

        if let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String {
            cacheApplicationName(displayName, for: applicationURL, in: &urlsByName)
        }
    }

    private static func cacheApplicationName(_ name: String, for applicationURL: URL, in urlsByName: inout [String: URL]) {
        let normalizedName = normalizedApplicationName(name)
        guard !normalizedName.isEmpty, urlsByName[normalizedName] == nil else { return }
        urlsByName[normalizedName] = applicationURL
    }
}

/// Keeps sandbox access alive until the corresponding sharing lifecycle ends,
/// even if the Shelf view (and its QuickShareService) is removed meanwhile.
private final class SecurityScopedResourceLease {
    private let lock = NSLock()
    private var urls: [URL]
    private var isReleased = false

    init(urls: [URL]) {
        self.urls = urls.filter { $0.startAccessingSecurityScopedResource() }
    }

    func release() {
        lock.lock()
        guard !isReleased else {
            lock.unlock()
            return
        }
        isReleased = true
        let urlsToRelease = urls
        urls.removeAll(keepingCapacity: false)
        lock.unlock()

        for url in urlsToRelease {
            url.stopAccessingSecurityScopedResource()
        }
    }

    deinit {
        release()
    }
}

final class QuickShareService: ObservableObject {
    @Published var availableProviders: [QuickShareProvider] = []
    @Published var isPickerOpen = false

    private var cachedApplicationURLsByName: [String: URL]?
    private var cachedServices: [String: NSSharingService] = [:]
    private var cachedIcons: [String: NSImage] = [:]
    private var applicationIconIndex = ApplicationIconIndex()
    private var isApplicationIconCacheLoading = false
    private var providerDiscoveryTask: Task<Void, Never>?
    private var iconCacheTask: Task<Void, Never>?
    private var isActive = false
    private var activeDropOperations = 0
    private var activeShareDelegates: [UUID: SharingLifecycleDelegate] = [:]
    private var activeShareLeases: [UUID: SecurityScopedResourceLease] = [:]

    init() {}

    deinit {
        providerDiscoveryTask?.cancel()
        iconCacheTask?.cancel()
    }

    @MainActor
    func activate() {
        guard !isActive else { return }
        isActive = true
        startProviderDiscoveryIfNeeded()
    }

    @MainActor
    func deactivate() {
        isActive = false
        providerDiscoveryTask?.cancel()
        iconCacheTask?.cancel()
        iconCacheTask = nil
        isApplicationIconCacheLoading = false
        releaseCachedResourcesIfIdle()
    }

    @MainActor
    private func startProviderDiscoveryIfNeeded() {
        guard isActive, availableProviders.isEmpty, providerDiscoveryTask == nil else { return }

        providerDiscoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.discoverAvailableProviders()
            self.providerDiscoveryTask = nil

            if self.isActive, self.availableProviders.isEmpty {
                self.startProviderDiscoveryIfNeeded()
            } else if !self.isActive {
                self.releaseCachedResourcesIfIdle()
            }
        }
    }

    @MainActor
    private func releaseCachedResourcesIfIdle() {
        guard !isActive,
              !isPickerOpen,
              activeDropOperations == 0,
              activeShareDelegates.isEmpty,
              providerDiscoveryTask == nil
        else {
            return
        }

        cachedApplicationURLsByName = nil
        cachedServices.removeAll(keepingCapacity: false)
        cachedIcons.removeAll(keepingCapacity: false)
        availableProviders.removeAll(keepingCapacity: false)
        applicationIconIndex = ApplicationIconIndex()
    }

    // MARK: - Icon Retrieval

    @MainActor
    func icon(for providerId: String, size: CGFloat) -> NSImage? {
        if let cachedIcon = cachedIcons[providerId] {
            return resizedIcon(cachedIcon, to: size)
        }

        if let providerIcon = applicationIcon(for: providerId) {
            cachedIcons[providerId] = providerIcon
            return resizedIcon(providerIcon, to: size)
        }

        warmApplicationIconCacheIfNeeded()

        // For system share menu, return a generic share icon
        if providerId == QuickShareProvider.systemShareMenuId {
            return NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Share")
        }

        // Try to get icon from cached service
        if let service = cachedServices[providerId] {
            return resizedIcon(service.image, to: size)
        }

        return nil
    }

    private func applicationIcon(for providerId: String) -> NSImage? {
        guard let applicationURL = cachedApplicationURLsByName?[ApplicationIconIndex.normalizedApplicationName(providerId)] else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: applicationURL.path)
    }

    @MainActor
    private func warmApplicationIconCacheIfNeeded() {
        guard isActive, cachedApplicationURLsByName == nil, !isApplicationIconCacheLoading else { return }
        isApplicationIconCacheLoading = true

        let index = applicationIconIndex
        iconCacheTask = Task(priority: .utility) { @MainActor [weak self, index] in
            let urlsByName = await index.urlsByName()
            guard !Task.isCancelled, let self, self.isActive else { return }
            self.cachedApplicationURLsByName = urlsByName
            self.isApplicationIconCacheLoading = false
            self.iconCacheTask = nil
        }
    }

    private func resizedIcon(_ image: NSImage, to size: CGFloat) -> NSImage {
        let targetSize = NSSize(width: size, height: size)
        return NSImage(size: targetSize, flipped: false) { rect in
            image.draw(in: rect,
                       from: NSRect(origin: .zero, size: image.size),
                       operation: .copy,
                       fraction: 1.0)
            return true
        }
    }
    // MARK: - Provider Discovery

    @MainActor
    func discoverAvailableProviders() async {
        let finder = ShareServiceFinder()

        let testItems: [Any] = [
            URL(string: "http://example.com")!,
            "Test" as NSString
        ]

        let services = await finder.findApplicableServices(for: testItems)
        guard isActive, !Task.isCancelled else { return }

        var providers: [QuickShareProvider] = []

        for svc in services {
            let title = svc.title
            let supportsRawText = svc.canPerform(withItems: ["Test Text"])
            let provider = QuickShareProvider(id: title, supportsRawText: supportsRawText)
            if !providers.contains(provider) {
                providers.append(provider)
                cachedServices[title] = svc
            }
        }

        if let idx = providers.firstIndex(where: { $0.id == QuickShareProvider.airDropId }) {
            let ad = providers.remove(at: idx)
            providers.insert(ad, at: 0)
        }

        if !providers.contains(where: { $0.id == QuickShareProvider.systemShareMenuId }) {
            providers.append(.systemShareMenu)
        }

        availableProviders = providers
    }

    // MARK: - File Picker
    @MainActor
    func showFilePicker(for provider: QuickShareProvider, from view: NSView?) async {
        guard isActive else { return }
        guard !isPickerOpen else {
            Log.shelf.error("⚠️ QuickShareService: File picker already open")
            return
        }

        isPickerOpen = true
        SharingStateManager.shared.beginInteraction()

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.title = "Select Files for \(provider.id)"
        panel.message = "Choose files to share via \(provider.id)"

        let response = panel.runModal()
        isPickerOpen = false

        // Start the share before ending the picker interaction, avoiding a gap
        // in which the notch could close and tear down the source view.
        if response == .OK && !panel.urls.isEmpty {
            await shareFilesOrText(panel.urls, using: provider, from: view)
        }

        SharingStateManager.shared.endInteraction()
        releaseCachedResourcesIfIdle()
    }

    // MARK: - Sharing
    @MainActor
    func shareFilesOrText(
        _ items: [Any],
        using provider: QuickShareProvider,
        from view: NSView?,
        onCompletion: (@MainActor () -> Void)? = nil
    ) async {
        let fileURLs = items.compactMap { $0 as? URL }.filter { $0.isFileURL }
        let service = cachedServices[provider.id].flatMap { $0.canPerform(withItems: items) ? $0 : nil }

        // Without a direct provider or an anchor view, there is nowhere to show
        // the system picker. Do not start security-scoped access in that case.
        guard service != nil || view != nil else {
            onCompletion?()
            return
        }

        let shareID = UUID()
        let lease = SecurityScopedResourceLease(urls: fileURLs)
        let delegate = SharingStateManager.shared.makeDelegate { [weak self, lease, service, onCompletion] in
            // Release sandbox access only when the system reports the share ended.
            lease.release()
            service?.delegate = nil
            Task { @MainActor [weak self, onCompletion] in
                onCompletion?()
                self?.finishSharing(id: shareID)
            }
        }

        activeShareLeases[shareID] = lease
        activeShareDelegates[shareID] = delegate

        if let service {
            delegate.markServiceBegan()
            service.delegate = delegate
            service.perform(withItems: items)
        } else if let view {
            let picker = NSSharingServicePicker(items: items)
            picker.delegate = delegate
            delegate.markPickerBegan()
            picker.show(relativeTo: .zero, of: view, preferredEdge: .minY)
        }
    }

    @MainActor
    private func finishSharing(id: UUID) {
        activeShareLeases.removeValue(forKey: id)?.release()
        activeShareDelegates.removeValue(forKey: id)
        releaseCachedResourcesIfIdle()
    }
// MARK: - SharingServiceDelegate

private class SharingServiceDelegate: NSObject {}

    @MainActor
    func shareDroppedFiles(_ providers: [NSItemProvider], using shareProvider: QuickShareProvider, from view: NSView?) async {
        activeDropOperations += 1
        defer {
            activeDropOperations -= 1
            releaseCachedResourcesIfIdle()
        }

        var itemsToShare: [Any] = []
        var foundText: String?

        for provider in providers {
            if let webURL = await provider.extractURL() {
                itemsToShare.append(webURL)
            } else if foundText == nil, let text = await provider.extractText() {
                foundText = text
            } else if let itemFileURL = await provider.extractItem() {
                let resolvedURL = await resolveShelfItemBookmark(for: itemFileURL) ?? itemFileURL
                itemsToShare.append(resolvedURL)
            }
        }

        // If text was found, prioritize sharing it.
        if let text = foundText {
            if shareProvider.supportsRawText {
                await shareFilesOrText([text], using: shareProvider, from: view)
            } else {
                if let tempTextURL = await TemporaryFileStorageService.shared.createTempFile(for: .text(text)) {
                    await shareFilesOrText(
                        [tempTextURL],
                        using: shareProvider,
                        from: view,
                        onCompletion: {
                            TemporaryFileStorageService.shared.removeTemporaryFileIfNeeded(at: tempTextURL)
                        }
                    )
                } else {
                    await shareFilesOrText([text], using: shareProvider, from: view)
                }
            }
        } else if !itemsToShare.isEmpty {
            await shareFilesOrText(itemsToShare, using: shareProvider, from: view)
        }
    }

    private func resolveShelfItemBookmark(for fileURL: URL) async -> URL? {
        let items = await ShelfStateViewModel.shared.items

        for itm in items {
            if let resolved = await ShelfStateViewModel.shared.resolveAndUpdateBookmark(for: itm) {
                if resolved.standardizedFileURL.path == fileURL.standardizedFileURL.path {
                    return resolved
                }
            }
        }
        Log.shelf.error("❌ Failed to resolve bookmark for shelf item")
        return nil
    }
}

