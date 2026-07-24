//
//  ShelfItemViewModel.swift
//  boringNotch
//
//  Created by Alexander on 2025-09-24.
//

import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import CoreServices
import ObjectiveC

@MainActor
final class ShelfItemViewModel: ObservableObject {
    @Published private(set) var item: ShelfItem

    // MARK: - Localization helpers
    private struct Strings {
        static let tryAgain = NSLocalizedString("Shelf.ContextMenu.TryAgain", value: "Try Again", comment: "Context menu item: retry unavailable file")
        static let removeFromShelf = NSLocalizedString("Shelf.ContextMenu.RemoveFromShelf", value: "Remove from Shelf", comment: "Context menu item: remove unavailable file")
    }

    @Published var thumbnail: NSImage?
    @Published private(set) var fileResolutionState = ShelfFileResolutionState()
    private var quickShareLifecycle: SharingLifecycleDelegate?
    private static var sharingLifecycle: SharingLifecycleDelegate?
    private static var sharingAccessingURLs: [URL] = []
    private static var shareTask: Task<Void, Never>?
    private static var shareGeneration: UUID?
    private static var copiedURLs: [URL] = []
    private static var copyTask: Task<Void, Never>?
    private static var copyGeneration: UUID?
    private let resolutionTimeout: Duration
    private var resolutionTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    private let selection = ShelfSelectionModel.shared

    init(
        item: ShelfItem,
        resolutionTimeout: Duration = .seconds(2)
    ) {
        self.item = item
        self.resolutionTimeout = resolutionTimeout

        if case .file = item.kind {
            startFileResolution()
        }
    }

    var fileResolutionPhase: ShelfFileResolutionPhase? {
        guard case .file = item.kind else { return nil }
        return fileResolutionState.phase
    }

    var resolvedFileURL: URL? {
        guard case .available(let file) = fileResolutionState.phase else { return nil }
        return file.url
    }

    var isUnavailableFile: Bool {
        guard case .file = item.kind, fileResolutionState.phase == .unavailable else { return false }
        return true
    }

    var canDrag: Bool {
        guard case .file = item.kind else { return true }
        return resolvedFileURL != nil
    }

    var canRetryFileResolution: Bool {
        isUnavailableFile
    }

    var displayName: String {
        if let name = Self.nonFileDisplayName(for: item.kind) { return name }
        switch fileResolutionState.phase {
        case .loading:
            return NSLocalizedString("Shelf.File.Loading", value: "Loading…", comment: "Shelf file resolution state")
        case .available(let file):
            return file.displayName
        case .unavailable:
            return NSLocalizedString("Shelf.File.Unavailable", value: "File unavailable", comment: "Shelf file resolution state")
        }
    }

    var dragPreviewImage: NSImage {
        if let thumbnail { return thumbnail }
        if let symbolName = Self.nonFileSymbolName(for: item.kind) {
            return Self.thumbnailSymbolImage(systemName: symbolName) ?? NSImage()
        }
        let symbolName = isUnavailableFile ? "doc.questionmark" : "doc"
        return NSImage(systemSymbolName: symbolName, accessibilityDescription: displayName) ?? NSImage()
    }

    func retryResolution() {
        guard canRetryFileResolution else { return }
        startFileResolution(refresh: true, restartPending: true)
    }

    private func startFileResolution(
        refresh: Bool = false,
        restartPending: Bool = false
    ) {
        guard case .file(let bookmarkData) = item.kind else { return }

        resolutionTask?.cancel()
        timeoutTask?.cancel()
        thumbnail = nil

        let generation = fileResolutionState.begin()
        let resolutionItem = item
        let pendingToken = ShelfStateViewModel.shared.prefetchFileResolution(
            for: resolutionItem,
            refresh: refresh,
            restartPending: restartPending
        )
        resolutionTask = Task { [weak self] in
            let resolvedFile = await ShelfStateViewModel.shared.resolveFile(
                for: resolutionItem,
                refresh: false
            )
            guard !Task.isCancelled,
                  let self,
                  self.fileResolutionState.finish(resolvedFile, generation: generation) else { return }

            guard let resolvedFile else { return }
            let effectiveBookmarkData = resolvedFile.refreshedBookmarkData ?? bookmarkData
            self.item = ShelfItem(
                id: self.item.id,
                kind: .file(bookmark: effectiveBookmarkData),
                isTemporary: self.item.isTemporary,
                fileIdentity: ShelfItem.fileIdentity(for: resolvedFile.url)
            )
            await self.loadThumbnail(for: resolvedFile.url)
        }

        let timeout = resolutionTimeout
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled,
                  let self,
                  self.fileResolutionState.timeOut(generation: generation) else {
                return
            }
            if let pendingToken {
                ShelfStateViewModel.shared.invalidatePendingResolution(
                    for: resolutionItem.id,
                    bookmarkData: bookmarkData,
                    token: pendingToken
                )
            }
        }
    }

    private func loadThumbnail(for url: URL) async {
        let workspaceIcon = await Task.detached(priority: .utility) {
            NSWorkspace.shared.icon(forFile: url.path)
        }.value
        guard resolvedFileURL == url else { return }
        thumbnail = workspaceIcon

        if let image = await ThumbnailService.shared.thumbnail(for: url, size: CGSize(width: 56, height: 56)) {
            guard resolvedFileURL == url else { return }
            self.thumbnail = NSImage(cgImage: image, size: CGSize(width: 56, height: 56))
        }
    }

    private static func nonFileDisplayName(for kind: ShelfItemKind) -> String? {
        switch kind {
        case .file:
            return nil
        case .text(let string):
            return string.trimmingCharacters(in: .whitespacesAndNewlines)
        case .link(let url):
            let string = url.absoluteString
            if string.hasPrefix("https://") { return String(string.dropFirst("https://".count)) }
            if string.hasPrefix("http://") { return String(string.dropFirst("http://".count)) }
            return string
        }
    }

    private static func nonFileSymbolName(for kind: ShelfItemKind) -> String? {
        switch kind {
        case .file: nil
        case .text: "text.justifyleft"
        case .link: "link"
        }
    }

    private static func thumbnailSymbolImage(systemName: String) -> NSImage? {
        let size = CGSize(width: 64, height: 80)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        NSColor.white.setFill()
        NSBezierPath(
            roundedRect: CGRect(origin: .zero, size: size).insetBy(dx: 2, dy: 2),
            xRadius: 4,
            yRadius: 4
        ).fill()

        guard let symbol = NSImage(systemSymbolName: systemName, accessibilityDescription: nil) else {
            return image
        }
        symbol.draw(in: CGRect(x: 13, y: 21, width: 38, height: 38))
        return image
    }

    private func replaceBookmarkAfterRename(_ bookmarkData: Data, url: URL) {
        ShelfStateViewModel.shared.updateBookmark(for: item, bookmark: bookmarkData, resolvedURL: url)
        item = ShelfItem(
            id: item.id,
            kind: .file(bookmark: bookmarkData),
            isTemporary: item.isTemporary,
            fileIdentity: ShelfItem.fileIdentity(for: url)
        )
        startFileResolution(refresh: true)
    }

    // MARK: - Actions
    func handleClick(event: NSEvent, view: NSView) {
        let flags = event.modifierFlags
        if flags.contains(.shift) {
            selection.shiftSelect(to: item, in: ShelfStateViewModel.shared.items)
        } else if flags.contains(.command) {
            selection.toggle(item)
        } else if flags.contains(.control) {
            handleRightClick(event: event, view: view)
        } else {
            if !selection.isSelected(item.id) { selection.selectSingle(item) }
        }
        if event.clickCount == 2 { handleDoubleClick() }
    }

    func handleRightClick(event: NSEvent, view: NSView) {
        if !selection.isSelected(item.id) { selection.selectSingle(item) }
        presentContextMenu(event: event, in: view)
    }

    func handleDoubleClick() {
        let selected = ShelfSelectionModel.shared.selectedItems(in: ShelfStateViewModel.shared.items)
        for it in selected { ShelfActionService.open(it) }
    }

    func shareItem(from view: NSView?) {
        guard Self.sharingLifecycle == nil else { return }

        Self.shareTask?.cancel()
        let generation = UUID()
        Self.shareGeneration = generation
        Self.shareTask = Task {
            var itemsToShare: [Any] = []
            var fileURLs: [URL] = []
            if case .text(let text) = item.kind {
                itemsToShare.append(text)
            } else {
                let selectedItems = ShelfSelectionModel.shared.selectedItems(in: ShelfStateViewModel.shared.items)
                let filesByItemID = await ShelfStateViewModel.shared.resolvedFilesByItemID(
                    for: selectedItems,
                    refresh: true
                )

                for item in selectedItems {
                    switch item.kind {
                    case .file:
                        if let url = filesByItemID[item.id]?.url {
                            itemsToShare.append(url)
                            fileURLs.append(url)
                        }
                    case .text(let string):
                        itemsToShare.append(string)
                    case .link(let url):
                        itemsToShare.append(url)
                    }
                }
            }
            
            guard !Task.isCancelled,
                  Self.shareGeneration == generation,
                  !itemsToShare.isEmpty else {
                return
            }

            // Start security-scoped access for all file URLs and keep it active during sharing
            let accessingURLs = fileURLs.filter { $0.startAccessingSecurityScopedResource() }
            guard !Task.isCancelled, Self.shareGeneration == generation else {
                for url in accessingURLs {
                    url.stopAccessingSecurityScopedResource()
                }
                return
            }
            Self.sharingAccessingURLs = accessingURLs

            // Create and retain lifecycle delegate for the entire share operation
            let lifecycle = SharingStateManager.shared.makeDelegate {
                guard Self.shareGeneration == generation else { return }
                Self.sharingLifecycle = nil
                Self.shareTask = nil
                Self.shareGeneration = nil
                Self.stopSharingAccessingURLs()
            }
            Self.sharingLifecycle = lifecycle

            let picker = NSSharingServicePicker(items: itemsToShare)
            picker.delegate = lifecycle
            lifecycle.markPickerBegan()
            if let view {
                picker.show(relativeTo: .zero, of: view, preferredEdge: .minY)
            }
        }
    }
    
    private static func stopSharingAccessingURLs() {
        for url in sharingAccessingURLs {
            url.stopAccessingSecurityScopedResource()
        }
        sharingAccessingURLs.removeAll()
    }

    /// Call this closure to request a QuickLook preview for the given URLs.
    var onQuickLookRequest: (([URL]) -> Void)?

    // MARK: - Context Menu helpers (extracted from view)
    private func ensureContextMenuSelection() {
        if !selection.isSelected(item.id) { selection.selectSingle(item) }
    }

    func presentContextMenu(event: NSEvent, in view: NSView) {
        ensureContextMenuSelection()
        let menu = NSMenu()

        func addMenuItem(title: String) {
            let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            menu.addItem(mi)
        }

        if isUnavailableFile {
            if canRetryFileResolution {
                addMenuItem(title: Strings.tryAgain)
                menu.addItem(NSMenuItem.separator())
            }
            addMenuItem(title: Strings.removeFromShelf)

            let actionTarget = MenuActionTarget(item: item, view: view, viewModel: self)
            for menuItem in menu.items where !menuItem.isSeparatorItem {
                menuItem.target = actionTarget
                menuItem.action = #selector(MenuActionTarget.handle(_:))
            }
            menu.retainActionTarget(actionTarget)
            NSMenu.popUpContextMenu(menu, with: event, for: view)
            return
        }

        let selectedItems = ShelfSelectionModel.shared.selectedItems(in: ShelfStateViewModel.shared.items)
        let selectedFiles = selectedItems.compactMap { ShelfStateViewModel.shared.resolvedFile(for: $0) }
        let selectedFileURLs = selectedFiles.map(\.url)
        let selectedLinkURLs: [URL] = selectedItems.compactMap { itm in
            if case .link(let url) = itm.kind { return url }
            return nil
        }
        // URLs valid for Open/Open With (exclude folders)
        let selectedOpenableURLs = selectedItems.compactMap { itm -> URL? in
            if let file = ShelfStateViewModel.shared.resolvedFile(for: itm) {
                return file.isDirectory ? nil : file.url
            }
            if case .link(let url) = itm.kind { return url }
            return nil
        }

        if !selectedOpenableURLs.isEmpty {
            addMenuItem(title: "Open")
        }

        if !selectedOpenableURLs.isEmpty {
            let openWith = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
            let submenu = NSMenu()

            // Choose a representative URL to compute apps (prefer current item if not a folder)
            let baseFileForApps: ResolvedShelfFile? = {
                if let file = ShelfStateViewModel.shared.resolvedFile(for: item), !file.isDirectory {
                    return file
                }
                return selectedFiles.first(where: { !$0.isDirectory })
            }()
            let baseURLForApps: URL? = {
                if let file = baseFileForApps { return file.url }
                if case .link(let u) = item.kind { return u }
                return selectedOpenableURLs.first
            }()

            let openWithApps: [URL] = {
                guard let u = baseURLForApps else { return [] }
                if u.isFileURL {
                    var results = NSWorkspace.shared.urlsForApplications(toOpen: u)
                    if results.isEmpty,
                       let identifier = baseFileForApps?.contentTypeIdentifier,
                       let uti = UTType(identifier) {
                        results = NSWorkspace.shared.urlsForApplications(toOpen: uti)
                    }
                    return Array(Set(results))
                } else {
                    return Array(Set(NSWorkspace.shared.urlsForApplications(toOpen: u)))
                }
            }()
            let defaultApp = defaultAppURL()

            if openWithApps.isEmpty {
                let noApps = NSMenuItem(title: "No Compatible Apps Found", action: nil, keyEquivalent: "")
                noApps.isEnabled = false
                submenu.addItem(noApps)
            } else {
                if let defaultApp = defaultApp {
                    let appName = appDisplayName(for: defaultApp)
                    let def = NSMenuItem(title: appName, action: nil, keyEquivalent: "")
                    def.representedObject = defaultApp
                    def.image = nsAppIcon(for: defaultApp, size: 16)

                    let title = NSMutableAttributedString(string: appName, attributes: [
                        .font: NSFont.menuFont(ofSize: 0),
                        .foregroundColor: NSColor.labelColor
                    ])
                    let defaultPart = NSAttributedString(string: " (default)", attributes: [
                        .font: NSFont.menuFont(ofSize: 0),
                        .foregroundColor: NSColor.secondaryLabelColor
                    ])
                    title.append(defaultPart)
                    def.attributedTitle = title
                    submenu.addItem(def)

                    if openWithApps.count > 1 || !openWithApps.contains(defaultApp) {
                        submenu.addItem(NSMenuItem.separator())
                    }
                }
                for appURL in openWithApps where appURL != defaultApp {
                    let mi = NSMenuItem(title: appDisplayName(for: appURL), action: nil, keyEquivalent: "")
                    mi.representedObject = appURL
                    mi.image = nsAppIcon(for: appURL, size: 16)
                    submenu.addItem(mi)
                }
            }

            submenu.addItem(NSMenuItem.separator())
            let other = NSMenuItem(title: "Other…", action: nil, keyEquivalent: "")
            other.representedObject = "__OTHER__"
            submenu.addItem(other)

            openWith.submenu = submenu
            menu.addItem(openWith)
        }

        if !selectedFileURLs.isEmpty { addMenuItem(title: "Show in Finder") }
        // Allow Quick Look for files and link URLs
        if !selectedFileURLs.isEmpty || !selectedLinkURLs.isEmpty {
            // Add Quick Look menu item
            let quickLookItem = NSMenuItem(title: "Quick Look", action: nil, keyEquivalent: "")
            menu.addItem(quickLookItem)
            
            // Add Slideshow as alternate menu item (shown when Option key is held)
            let slideshowItem = NSMenuItem(title: "Quick Look", action: nil, keyEquivalent: "")
            slideshowItem.isAlternate = true
            slideshowItem.keyEquivalentModifierMask = [.option]
            menu.addItem(slideshowItem)
        }

        menu.addItem(NSMenuItem.separator())
        addMenuItem(title: "Share…")
        
        // Add image processing options for image files grouped under "Image Actions"
        let imageURLs = selectedFiles.filter(Self.isImageFile).map(\.url)
        if !imageURLs.isEmpty {
            menu.addItem(NSMenuItem.separator())

            let imageActions = NSMenuItem(title: "Image Actions", action: nil, keyEquivalent: "")
            let imageSubmenu = NSMenu()

            // Remove Background - only for single images
            if imageURLs.count == 1 {
                let removeBg = NSMenuItem(title: "Remove Background", action: nil, keyEquivalent: "")
                imageSubmenu.addItem(removeBg)
            }

            // Convert Image - only for single images
            if imageURLs.count == 1 {
                let convertItem = NSMenuItem(title: "Convert Image…", action: nil, keyEquivalent: "")
                imageSubmenu.addItem(convertItem)
            }

            // Create PDF - for one or more images
            let createPDF = NSMenuItem(title: "Create PDF", action: nil, keyEquivalent: "")
            imageSubmenu.addItem(createPDF)

            imageActions.submenu = imageSubmenu
            menu.addItem(imageActions)
            menu.addItem(NSMenuItem.separator())
        }

        // Add compression option for files/folders (single or multiple)
        if !selectedFileURLs.isEmpty {
            let compressItem = NSMenuItem(title: "Compress", action: nil, keyEquivalent: "")
            menu.addItem(compressItem)
        }

        if selectedItems.count == 1, case .file(_) = item.kind { addMenuItem(title: "Rename") }

        // Always show "Copy" for all item types
        addMenuItem(title: "Copy")
        // If there are file URLs, add "Copy Path" as an alternate menu item (Option key)
        if !selectedFileURLs.isEmpty {
            let copyPathItem = NSMenuItem(title: "Copy Path", action: nil, keyEquivalent: "")
            copyPathItem.isAlternate = true
            copyPathItem.keyEquivalentModifierMask = [.option]
            menu.addItem(copyPathItem)
        }

        menu.addItem(NSMenuItem.separator())
        addMenuItem(title: "Remove")

        let actionTarget = MenuActionTarget(item: item, view: view, viewModel: self)

        for menuItem in menu.items {
            if menuItem.isSeparatorItem { continue }
            menuItem.target = actionTarget
            menuItem.action = #selector(MenuActionTarget.handle(_:))

            if let submenu = menuItem.submenu {
                for subItem in submenu.items {
                    if !subItem.isSeparatorItem {
                        subItem.target = actionTarget
                        subItem.action = #selector(MenuActionTarget.handle(_:))
                    }
                }
            }
        }
        
        menu.retainActionTarget(actionTarget)
        
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    private static func isImageFile(_ file: ResolvedShelfFile) -> Bool {
        if let identifier = file.contentTypeIdentifier,
           let contentType = UTType(identifier) {
            return contentType.conforms(to: .image)
        }
        return UTType(filenameExtension: file.url.pathExtension)?.conforms(to: .image) == true
    }

    private final class MenuActionTarget: NSObject {
        let item: ShelfItem
        weak var view: NSView?
        weak var viewModel: ShelfItemViewModel?

        // Keep associated objects (like accessory view handlers) without magic keys
        private static var sliderHandlerAssoc = AssociatedObject<AnyObject>()

        init(item: ShelfItem, view: NSView, viewModel: ShelfItemViewModel) {
            self.item = item
            self.view = view
            self.viewModel = viewModel
        }

        @MainActor @objc func handle(_ sender: NSMenuItem) {
            let title = sender.title

            if let marker = sender.representedObject as? String, marker == "__OTHER__" {
                Task {
                    _ = await ShelfStateViewModel.shared.resolveFile(for: item, refresh: true)
                    openWithPanel()
                }
                return
            }

            if let appURL = sender.representedObject as? URL {
                let selected = ShelfSelectionModel.shared.selectedItems(in: ShelfStateViewModel.shared.items)
                
                Task {
                    let filesByItemID = await ShelfStateViewModel.shared.resolvedFilesByItemID(
                        for: selected,
                        refresh: true
                    )
                    var allSelectedURLs: [URL] = []

                    for itm in selected {
                        if let fileURL = filesByItemID[itm.id]?.url {
                            allSelectedURLs.append(fileURL)
                        } else if case .link(let url) = itm.kind {
                            allSelectedURLs.append(url)
                        }
                    }

                    guard !allSelectedURLs.isEmpty else { return }

                    let config = NSWorkspace.OpenConfiguration()

                    let fileURLs = allSelectedURLs.filter { $0.isFileURL }
                    do {
                        if !fileURLs.isEmpty {
                            _ = try await fileURLs.accessSecurityScopedResources { _ in
                                try await NSWorkspace.shared.open(allSelectedURLs, withApplicationAt: appURL, configuration: config)
                            }
                        } else {
                            try await NSWorkspace.shared.open(allSelectedURLs, withApplicationAt: appURL, configuration: config)
                        }
                    } catch {
                        print("❌ Failed to open with application: \(error.localizedDescription)")
                    }
                }
                return
            }

            switch title {
            case Strings.tryAgain:
                viewModel?.retryResolution()

            case Strings.removeFromShelf:
                ShelfActionService.remove(item)

            case "Quick Look":
                // Handle all selected items for Quick Look, not just the clicked item
                let selected = ShelfSelectionModel.shared.selectedItems(in: ShelfStateViewModel.shared.items)
                Task {
                    let filesByItemID = await ShelfStateViewModel.shared.resolvedFilesByItemID(
                        for: selected,
                        refresh: true
                    )
                    let urls: [URL] = selected.compactMap { item in
                        if let fileURL = filesByItemID[item.id]?.url {
                            return fileURL
                        }
                        if case .link(let url) = item.kind {
                            return url
                        }
                        return nil
                    }
                    if !urls.isEmpty {
                        viewModel?.onQuickLookRequest?(urls)
                    }
                }

            case "Open":
                let selected = ShelfSelectionModel.shared.selectedItems(in: ShelfStateViewModel.shared.items)
                for it in selected { ShelfActionService.open(it) }

            case "Share…":
                viewModel?.shareItem(from: view)

            case "Rename":
                let selected = ShelfSelectionModel.shared.selectedItems(in: ShelfStateViewModel.shared.items)
                if selected.count == 1, let single = selected.first { showRenameDialog(for: single) }

            case "Show in Finder":
                let selected = ShelfSelectionModel.shared.selectedItems(in: ShelfStateViewModel.shared.items)
                Task {
                    let urls = await ShelfStateViewModel.shared.resolvedFileURLs(for: selected, refresh: true)
                    if !urls.isEmpty {
                        await urls.accessSecurityScopedResources { accessibleURLs in
                            NSWorkspace.shared.activateFileViewerSelecting(accessibleURLs)
                        }
                    }
                }

            case "Copy Path":
                let selected = ShelfSelectionModel.shared.selectedItems(in: ShelfStateViewModel.shared.items)
                Task {
                    let fileURLs = await ShelfStateViewModel.shared.resolvedFileURLs(for: selected, refresh: true)
                    let paths = fileURLs.map(\.path)
                    if !paths.isEmpty {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
                    }
                }

            case "Copy":
                let selected = ShelfSelectionModel.shared.selectedItems(in: ShelfStateViewModel.shared.items)
                let pb = NSPasteboard.general

                ShelfItemViewModel.copyTask?.cancel()

                // Stop accessing previously copied URLs
                for url in ShelfItemViewModel.copiedURLs {
                    url.stopAccessingSecurityScopedResource()
                }
                ShelfItemViewModel.copiedURLs.removeAll()
                pb.clearContents()

                let generation = UUID()
                ShelfItemViewModel.copyGeneration = generation
                ShelfItemViewModel.copyTask = Task {
                    let fileURLs = await ShelfStateViewModel.shared.resolvedFileURLs(for: selected, refresh: true)
                    guard !Task.isCancelled,
                          ShelfItemViewModel.copyGeneration == generation else {
                        return
                    }

                    if !fileURLs.isEmpty {
                        // Start security-scoped access for all URLs and keep them active
                        let accessingURLs = fileURLs.filter { $0.startAccessingSecurityScopedResource() }
                        guard !Task.isCancelled,
                              ShelfItemViewModel.copyGeneration == generation else {
                            for url in accessingURLs {
                                url.stopAccessingSecurityScopedResource()
                            }
                            return
                        }

                        ShelfItemViewModel.copiedURLs = accessingURLs
                        NSLog("🔐 Started security-scoped access for \(ShelfItemViewModel.copiedURLs.count) copied files")

                        // Write to pasteboard
                        pb.writeObjects(fileURLs as [NSURL])
                    } else {
                        let strings = selected.compactMap { selectedItem -> String? in
                            switch selectedItem.kind {
                            case .text(let string): return string
                            case .link(let url): return url.absoluteString
                            case .file: return nil
                            }
                        }
                        if !strings.isEmpty {
                            pb.clearContents()
                            pb.setString(strings.joined(separator: "\n"), forType: .string)
                        }
                    }
                }

            case "Remove":
                let selected = ShelfSelectionModel.shared.selectedItems(in: ShelfStateViewModel.shared.items)
                for it in selected { ShelfActionService.remove(it) }
                
            case "Remove Background":
                handleRemoveBackground()
                
            case "Convert Image…":
                showConvertImageDialog()
                
            case "Create PDF":
                handleCreatePDF()
            
            case "Compress":
                let selected = ShelfSelectionModel.shared.selectedItems(in: ShelfStateViewModel.shared.items)
                Task {
                    let fileURLs = await ShelfStateViewModel.shared.resolvedFileURLs(for: selected, refresh: true)
                    guard !fileURLs.isEmpty else { return }

                    // Create ZIP in a temporary location while holding access to selected resources
                    if let zipTempURL = await fileURLs.accessSecurityScopedResources(accessor: { urls in
                        await TemporaryFileStorageService.shared.createZip(from: urls)
                    }) {
                        if let bookmark = try? Bookmark(url: zipTempURL) {
                            let newItem = ShelfItem(
                                kind: .file(bookmark: bookmark.data),
                                isTemporary: true,
                                fileIdentity: ShelfItem.fileIdentity(for: zipTempURL)
                            )
                            ShelfStateViewModel.shared.add([newItem])
                        } else {
                            // Fallback: reveal the temporary file in Finder
                            NSWorkspace.shared.activateFileViewerSelecting([zipTempURL])
                        }
                    }
                }
                
            default:
                break
            }
        }

        @MainActor
        private func openWithPanel() {
            // Support both file items and link items
            let targetURL: URL?
            let needsSecurityScope: Bool
            let resolvedFile = ShelfStateViewModel.shared.resolvedFile(for: item)
            
            if let resolvedFile {
                targetURL = resolvedFile.url
                needsSecurityScope = true
            } else if case .link(let url) = item.kind {
                targetURL = url
                needsSecurityScope = false
            } else {
                targetURL = nil
                needsSecurityScope = false
            }
            guard let fileURL = targetURL else { return }

            let panel = NSOpenPanel()
            panel.title = "Choose Application"
            panel.message = "Choose an application to open the document \"\(viewModel?.displayName ?? "")\"."
            panel.prompt = "Open"
            panel.allowsMultipleSelection = false
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.resolvesAliases = true
            if #available(macOS 12.0, *) {
                panel.allowedContentTypes = [.application]
            }
            panel.directoryURL = URL(fileURLWithPath: "/Applications")

            // Compute recommended applications for the selected target
            let recommendedApps: Set<URL> = {
                let apps: [URL]
                if let identifier = resolvedFile?.contentTypeIdentifier,
                   let uti = UTType(identifier) {
                    apps = NSWorkspace.shared.urlsForApplications(toOpen: uti)
                } else {
                    apps = NSWorkspace.shared.urlsForApplications(toOpen: fileURL)
                }
                return Set(apps.map { $0.standardizedFileURL })
            }()

            // Delegate to filter entries when in "Recommended Applications" mode
            final class AppChooserDelegate: NSObject, NSOpenSavePanelDelegate {
                enum Mode { case recommended, all }
                var mode: Mode = .recommended
                let recommended: Set<URL>
                init(recommended: Set<URL>) { self.recommended = recommended }
                
                func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
                    let ext = url.pathExtension.lowercased()
                    if ext == "app" {
                        switch mode {
                        case .all:
                            return true
                        case .recommended:
                            // Standardize URLs for reliable comparison
                            let std = url.standardizedFileURL
                            return recommended.contains(std)
                        }
                    }

                    var isDirectory: ObjCBool = false
                    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                        return true
                    }
                    
                    return false
                }
            }

            let chooserDelegate = AppChooserDelegate(recommended: recommendedApps)
            panel.delegate = chooserDelegate

            let enableLabel = NSTextField(labelWithString: "Enable:")
            enableLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
            enableLabel.alignment = .natural
            enableLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.addItems(withTitles: ["Recommended Applications", "All Applications"])
            popup.font = .systemFont(ofSize: NSFont.systemFontSize)
            popup.selectItem(at: 0)
            
            popup.setContentHuggingPriority(.defaultLow, for: .horizontal)
            popup.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
            
            let alwaysCheckbox = NSButton(checkboxWithTitle: "Always Open With", target: nil, action: nil)
            alwaysCheckbox.font = .systemFont(ofSize: NSFont.systemFontSize)
            alwaysCheckbox.setContentHuggingPriority(.defaultLow, for: .horizontal)

            let row = NSStackView(views: [enableLabel, popup])
            row.orientation = .horizontal
            row.spacing = 8
            row.alignment = .centerY
            row.distribution = .fill
            
            let column = NSStackView(views: [row, alwaysCheckbox])
            column.orientation = .vertical
            column.spacing = 12
            column.alignment = .centerX
            column.distribution = .fill
            column.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
            
            panel.accessoryView = column
            panel.isAccessoryViewDisclosed = true

            // Wire up popup to switch filter mode
            class PopupBinder: NSObject {
                weak var popup: NSPopUpButton?
                weak var chooserDelegate: AppChooserDelegate?
                weak var panel: NSOpenPanel?
                init(popup: NSPopUpButton, chooserDelegate: AppChooserDelegate, panel: NSOpenPanel) {
                    self.popup = popup
                    self.chooserDelegate = chooserDelegate
                    self.panel = panel
                }
                @MainActor @objc func changed(_ sender: Any?) {
                    if popup?.indexOfSelectedItem == 1 {
                        chooserDelegate?.mode = .all
                    } else {
                        chooserDelegate?.mode = .recommended
                    }
                    if let panel = panel {
                        panel.validateVisibleColumns()
                        let currentDir = panel.directoryURL
                        panel.directoryURL = currentDir
                    }
                }
            }
            let binder = PopupBinder(popup: popup, chooserDelegate: chooserDelegate, panel: panel)
            popup.target = binder
            popup.action = #selector(PopupBinder.changed(_:))

            panel.begin { response in
                if response == .OK, let appURL = panel.url {
                    Task {
                        do {
                            let config = NSWorkspace.OpenConfiguration()
                            if alwaysCheckbox.state == .on, let bundleID = Bundle(url: appURL)?.bundleIdentifier {
                                if let contentTypeIdentifier = resolvedFile?.contentTypeIdentifier {
                                    let status = LSSetDefaultRoleHandlerForContentType(contentTypeIdentifier as CFString, LSRolesMask.all, bundleID as CFString)
                                    if status != noErr { print("⚠️ Failed to set default handler for \(contentTypeIdentifier): \(status)") }
                                } else if let scheme = fileURL.scheme {
                                    let status = LSSetDefaultHandlerForURLScheme(scheme as CFString, bundleID as CFString)
                                    if status != noErr { print("⚠️ Failed to set default handler for scheme \(scheme): \(status)") }
                                }
                            }

                            if needsSecurityScope {
                                _ = try await fileURL.accessSecurityScopedResource { accessibleURL in
                                    try await NSWorkspace.shared.open([accessibleURL], withApplicationAt: appURL, configuration: config)
                                }
                            } else {
                                try await NSWorkspace.shared.open([fileURL], withApplicationAt: appURL, configuration: config)
                            }
                        } catch {
                            print("❌ Failed to open with application: \(error.localizedDescription)")
                        }
                    }
                }
                // Keep binder/delegate alive until panel finishes
                _ = binder
                _ = chooserDelegate
            }
        }
        
        @MainActor
        private func showRenameDialog(for item: ShelfItem) {
            guard case .file = item.kind else { return }
            Task {
                if let fileURL = await ShelfStateViewModel.shared.resolveFile(for: item, refresh: true)?.url {
                    // Start security-scoped access and keep it active until rename completes.
                    let didStart = fileURL.startAccessingSecurityScopedResource()

                    let savePanel = NSSavePanel()
                    savePanel.title = "Rename File"
                    savePanel.prompt = "Rename"
                    savePanel.nameFieldStringValue = fileURL.lastPathComponent
                    savePanel.directoryURL = fileURL.deletingLastPathComponent()
                    savePanel.begin { response in
                        if response == .OK, let newURL = savePanel.url {
                            Task {
                                do {
                                    NSLog("🔐 Rename: moving from \(fileURL.path) to \(newURL.path) (securityScope=\(didStart))")

                                    try FileManager.default.moveItem(at: fileURL, to: newURL)

                                    if let newBookmark = try? Bookmark(url: newURL) {
                                        self.viewModel?.replaceBookmarkAfterRename(newBookmark.data, url: newURL)
                                    }
                                } catch {
                                    print("❌ Failed to rename file: \(error.localizedDescription)")
                                }
                                if didStart { fileURL.stopAccessingSecurityScopedResource() }
                            }
                        } else {
                            if didStart { fileURL.stopAccessingSecurityScopedResource() }
                        }
                    }
                }
            }
        }
        
        @MainActor
        private func handleRemoveBackground() {
            let selected = ShelfSelectionModel.shared.selectedItems(in: ShelfStateViewModel.shared.items)
            Task {
                let imageURLs = await ShelfStateViewModel.shared
                    .resolvedFiles(for: selected, refresh: true)
                    .filter(ShelfItemViewModel.isImageFile)
                    .map(\.url)
                guard let imageURL = imageURLs.first else { return }

                do {
                    let resultURL = try await imageURL.accessSecurityScopedResource { url in
                        try await ImageProcessingService.shared.removeBackground(from: url)
                    }
                    
                    if let resultURL = resultURL {
                        // Create bookmark and add to shelf as temporary item
                        if let bookmark = try? Bookmark(url: resultURL) {
                            let newItem = ShelfItem(
                                kind: .file(bookmark: bookmark.data),
                                isTemporary: true,
                                fileIdentity: ShelfItem.fileIdentity(for: resultURL)
                            )
                            ShelfStateViewModel.shared.add([newItem])
                        }
                    }
                } catch {
                    print("❌ Failed to remove background: \(error.localizedDescription)")
                    showErrorAlert(title: "Background Removal Failed", message: error.localizedDescription)
                }
            }
        }
        
        @MainActor
        private func handleCreatePDF() {
            let selected = ShelfSelectionModel.shared.selectedItems(in: ShelfStateViewModel.shared.items)
            Task {
                let imageURLs = await ShelfStateViewModel.shared
                    .resolvedFiles(for: selected, refresh: true)
                    .filter(ShelfItemViewModel.isImageFile)
                    .map(\.url)
                guard !imageURLs.isEmpty else { return }

                do {
                    let resultURL = try await imageURLs.accessSecurityScopedResources { urls in
                        try await ImageProcessingService.shared.createPDF(from: urls)
                    }
                    
                    if let resultURL = resultURL {
                        // Create bookmark and add to shelf as temporary item
                        if let bookmark = try? Bookmark(url: resultURL) {
                            let newItem = ShelfItem(
                                kind: .file(bookmark: bookmark.data),
                                isTemporary: true,
                                fileIdentity: ShelfItem.fileIdentity(for: resultURL)
                            )
                            ShelfStateViewModel.shared.add([newItem])
                        }
                    }
                } catch {
                    print("❌ Failed to create PDF: \(error.localizedDescription)")
                    showErrorAlert(title: "PDF Creation Failed", message: error.localizedDescription)
                }
            }
        }
        
        @MainActor
        private func showConvertImageDialog() {
            let selected = ShelfSelectionModel.shared.selectedItems(in: ShelfStateViewModel.shared.items)
            Task {
                let imageURLs = await ShelfStateViewModel.shared
                    .resolvedFiles(for: selected, refresh: true)
                    .filter(ShelfItemViewModel.isImageFile)
                    .map(\.url)
                guard let imageURL = imageURLs.first else { return }
                showConvertImageDialog(for: imageURL)
            }
        }

        @MainActor
        private func showConvertImageDialog(for imageURL: URL) {
            // Create and show conversion options dialog with better layout
            let alert = NSAlert()
            alert.messageText = "Convert Image"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Convert")
            alert.addButton(withTitle: "Cancel")
            
            // Create accessory view with better spacing and organization
            let accessoryView = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 180))
            accessoryView.wantsLayer = true
            
            // MARK: Format Row
            let formatLabel = NSTextField(labelWithString: "Format:")
            formatLabel.frame = NSRect(x: 0, y: 145, width: 100, height: 20)
            formatLabel.font = .systemFont(ofSize: 12, weight: .medium)
            accessoryView.addSubview(formatLabel)
            
            let formatPopup = NSPopUpButton(frame: NSRect(x: 120, y: 140, width: 250, height: 28))
            formatPopup.addItems(withTitles: ["PNG", "JPEG", "HEIC", "TIFF", "BMP"])
            formatPopup.selectItem(at: 0)
            formatPopup.font = .systemFont(ofSize: 12)
            accessoryView.addSubview(formatPopup)
            
            // MARK: Image Size Row
            let imageSizeLabel = NSTextField(labelWithString: "Image Size:")
            imageSizeLabel.frame = NSRect(x: 0, y: 105, width: 100, height: 20)
            imageSizeLabel.font = .systemFont(ofSize: 12, weight: .medium)
            accessoryView.addSubview(imageSizeLabel)
            
            let imageSizePopup = NSPopUpButton(frame: NSRect(x: 120, y: 100, width: 160, height: 28))
            imageSizePopup.addItems(withTitles: ["Actual Size", "Large", "Medium", "Small", "Custom..."])
            imageSizePopup.selectItem(at: 0)
            imageSizePopup.font = .systemFont(ofSize: 12)
            accessoryView.addSubview(imageSizePopup)
            
            // Custom size field (initially hidden)
            let customSizeField = NSTextField(frame: NSRect(x: 285, y: 103, width: 85, height: 22))
            customSizeField.placeholderString = "e.g., 1920"
            customSizeField.font = .systemFont(ofSize: 12)
            customSizeField.isHidden = true
            accessoryView.addSubview(customSizeField)
            
            // MARK: Preserve Metadata Checkbox
            let metadataCheckbox = NSButton(checkboxWithTitle: "Preserve Metadata", target: nil, action: nil)
            metadataCheckbox.frame = NSRect(x: 120, y: 65, width: 200, height: 20)
            metadataCheckbox.font = .systemFont(ofSize: 12)
            metadataCheckbox.state = .on
            accessoryView.addSubview(metadataCheckbox)
            
            // MARK: Separator line
            let separatorLine = NSView(frame: NSRect(x: 0, y: 50, width: 380, height: 1))
            separatorLine.wantsLayer = true
            separatorLine.layer?.backgroundColor = NSColor.separatorColor.cgColor
            accessoryView.addSubview(separatorLine)
            
            // MARK: Format-specific options (shown/hidden based on format selection)
            let qualityRow = NSView(frame: NSRect(x: 0, y: 15, width: 380, height: 30))
            qualityRow.wantsLayer = true
            
            let qualityLabel = NSTextField(labelWithString: "Compression:")
            qualityLabel.frame = NSRect(x: 0, y: 7, width: 100, height: 20)
            qualityLabel.font = .systemFont(ofSize: 12, weight: .medium)
            qualityRow.addSubview(qualityLabel)
            
            let qualitySlider = NSSlider(frame: NSRect(x: 120, y: 12, width: 200, height: 20))
            qualitySlider.minValue = 0.0
            qualitySlider.maxValue = 1.0
            qualitySlider.doubleValue = 0.85
            accessoryView.addSubview(qualitySlider)
            
            let qualityValueLabel = NSTextField(labelWithString: "85%")
            qualityValueLabel.frame = NSRect(x: 325, y: 7, width: 55, height: 20)
            qualityValueLabel.font = .systemFont(ofSize: 12)
            qualityValueLabel.alignment = .left
            accessoryView.addSubview(qualityValueLabel)
            
            // Update quality label and hide/show compression row based on format
            let updateQualityLabel = {
                let value = Int(qualitySlider.doubleValue * 100)
                qualityValueLabel.stringValue = "\(value)%"
            }
            
            let updateCompressionVisibility = {
                let formatIndex = formatPopup.indexOfSelectedItem
                let showCompression = formatIndex == 1 || formatIndex == 2 // JPEG or HEIC
                qualitySlider.isHidden = !showCompression
                qualityValueLabel.isHidden = !showCompression
                qualityLabel.isHidden = !showCompression
            }
            
            let updateCustomSizeVisibility = {
                let sizeIndex = imageSizePopup.indexOfSelectedItem
                customSizeField.isHidden = sizeIndex != 4 // Show only for "Custom..."
            }
            
            // Create a target object to handle slider value changes
            class SliderHandler: NSObject {
                let updateLabel: () -> Void
                let updateVisibility: () -> Void
                let updateCustomSize: () -> Void
                init(updateLabel: @escaping () -> Void, updateVisibility: @escaping () -> Void, updateCustomSize: @escaping () -> Void) {
                    self.updateLabel = updateLabel
                    self.updateVisibility = updateVisibility
                    self.updateCustomSize = updateCustomSize
                }
                @objc func sliderChanged(_ sender: NSSlider) {
                    updateLabel()
                }
                @objc func formatChanged(_ sender: NSPopUpButton) {
                    updateVisibility()
                }
                @objc func sizeChanged(_ sender: NSPopUpButton) {
                    updateCustomSize()
                }
            }
            
            let handler = SliderHandler(updateLabel: updateQualityLabel, updateVisibility: updateCompressionVisibility, updateCustomSize: updateCustomSizeVisibility)
            qualitySlider.target = handler
            qualitySlider.action = #selector(SliderHandler.sliderChanged(_:))
            qualitySlider.isContinuous = true
            
            formatPopup.target = handler
            formatPopup.action = #selector(SliderHandler.formatChanged(_:))
            
            imageSizePopup.target = handler
            imageSizePopup.action = #selector(SliderHandler.sizeChanged(_:))
            
            updateCompressionVisibility()
            updateQualityLabel()
            updateCustomSizeVisibility()
            
            // Keep the handler alive using the `AssociatedObject` helper instead of a magic string key
            MenuActionTarget.sliderHandlerAssoc[accessoryView] = handler
            
            alert.accessoryView = accessoryView
            
            let response = alert.runModal()
            
            if response == .alertFirstButtonReturn {
                // Get selected options
                let formatIndex = formatPopup.indexOfSelectedItem
                let format: ImageConversionOptions.ImageFormat
                switch formatIndex {
                case 0: format = .png
                case 1: format = .jpeg
                case 2: format = .heic
                case 3: format = .tiff
                case 4: format = .bmp
                default: format = .png
                }
                
                let quality = qualitySlider.doubleValue
                
                // Get max dimension based on image size selection
                let maxDimension: CGFloat? = {
                    let sizeIndex = imageSizePopup.indexOfSelectedItem
                    switch sizeIndex {
                    case 0: return nil // Actual Size
                    case 1: return 1280 // Large 
                    case 2: return 640  // Medium 
                    case 3: return 320  // Small 
                    case 4: // Custom (user-specified)
                        let text = customSizeField.stringValue.trimmingCharacters(in: .whitespaces)
                        guard !text.isEmpty, let value = Double(text), value > 0 else { return nil }
                        return CGFloat(value)
                    default: return nil
                    }
                }()
                
                let removeMetadata = metadataCheckbox.state == .off // Note: we invert this
                
                let options = ImageConversionOptions(
                    format: format,
                    compressionQuality: quality,
                    maxDimension: maxDimension,
                    removeMetadata: removeMetadata
                )
                
                Task {
                    do {
                        let resultURL = try await imageURL.accessSecurityScopedResource { url in
                            try await ImageProcessingService.shared.convertImage(from: url, options: options)
                        }
                        
                        if let resultURL = resultURL {
                            // Create bookmark and add to shelf as temporary item
                            if let bookmark = try? Bookmark(url: resultURL) {
                                let newItem = ShelfItem(
                                    kind: .file(bookmark: bookmark.data),
                                    isTemporary: true,
                                    fileIdentity: ShelfItem.fileIdentity(for: resultURL)
                                )
                                ShelfStateViewModel.shared.add([newItem])
                            }
                        }
                    } catch {
                        print("❌ Failed to convert image: \(error.localizedDescription)")
                        showErrorAlert(title: "Image Conversion Failed", message: error.localizedDescription)
                    }
                }
            }
        }
        
        @MainActor
        private func showErrorAlert(title: String, message: String) {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    // MARK: - Private helpers
    private func appDisplayName(for appURL: URL) -> String {
        (try? appURL.resourceValues(forKeys: [.localizedNameKey]).localizedName) ?? appURL.lastPathComponent
    }

    private func nsAppIcon(for appURL: URL, size: CGFloat) -> NSImage? {
        let baseIcon = NSWorkspace.shared.icon(forFile: appURL.path)
        baseIcon.isTemplate = false

        let targetSize = NSSize(width: size, height: size)
        let rendered = NSImage(size: targetSize, flipped: false) { rect in
            NSGraphicsContext.current?.imageInterpolation = .high
            baseIcon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0, respectFlipped: true, hints: [
                .interpolation: NSImageInterpolation.high.rawValue
            ])
            return true
        }

        rendered.size = targetSize
        return rendered
    }

    private func defaultAppURL() -> URL? {
        if let fileURL = ShelfStateViewModel.shared.resolvedFileURL(for: item) {
            return NSWorkspace.shared.urlForApplication(toOpen: fileURL)
        } else if case .link(let url) = item.kind {
            return NSWorkspace.shared.urlForApplication(toOpen: url)
        }
        return nil
    }
}

fileprivate extension Sequence {
    func asyncCompactMap<T>(_ transform: (Element) async -> T?) async -> [T] {
        var result: [T] = []
        for element in self {
            if let transformed = await transform(element) {
                result.append(transformed)
            }
        }
        return result
    }
}
