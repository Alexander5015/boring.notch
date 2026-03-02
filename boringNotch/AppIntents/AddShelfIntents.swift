//
//  AddShelfIntents.swift
//  boringNotch
//
//  Created by Alexander on 2026-03-01.
//  Refactored to provide three separate intents for files, URLs and text.
//


import AppIntents
import Foundation

// MARK: - Add file intent

struct AddShelfFileIntent: AppIntent {
    static var title: LocalizedStringResource = "Add Files to Shelf"
    static var description = IntentDescription("Add one or more files to your shelf")

    @Parameter(title: "Files", default: [])
    var files: [IntentFile]

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        var addedCount = 0
        var names: [String] = []

        for f in files {
            if let fileURL = f.fileURL {
                let bookmarkData = try Bookmark(url: fileURL).data
                let newItem = ShelfItem(kind: .file(bookmark: bookmarkData), isTemporary: false)
                ShelfStateViewModel.shared.add([newItem])
                addedCount += 1
                names.append(fileURL.lastPathComponent)
            }
        }

        if addedCount == 0 {
            throw NSError(domain: "AddShelfFileIntent", code: 1, userInfo: [NSLocalizedDescriptionKey: "No valid files provided"]) 
        }

        let title = addedCount == 1 ? names.first! : "\(addedCount) files"
        return .result(dialog: "Added \(title) to your shelf")
    }
}

// MARK: - Add URL intent

struct AddShelfURLIntent: AppIntent {
    static var title: LocalizedStringResource = "Add Links to Shelf"
    static var description = IntentDescription("Add one or more links to your shelf")

    @Parameter(title: "Links", default: [])
    var urls: [URL]

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        var addedCount = 0
        var samples: [String] = []
        for u in urls {
            let newItem = ShelfItem(kind: .link(url: u), isTemporary: false)
            ShelfStateViewModel.shared.add([newItem])
            addedCount += 1
            samples.append(u.absoluteString)
        }

        if addedCount == 0 {
            throw NSError(domain: "AddShelfURLIntent", code: 1, userInfo: [NSLocalizedDescriptionKey: "No links provided"]) 
        }

        let title = addedCount == 1 ? samples.first! : "\(addedCount) links"
        return .result(dialog: "Added \(title) to your shelf")
    }
}

// MARK: - Add Text intent

struct AddShelfTextIntent: AppIntent {
    static var title: LocalizedStringResource = "Add Text to Shelf"
    static var description = IntentDescription("Add one or more pieces of text to your shelf")

    @Parameter(title: "Texts", default: [])
    var texts: [String]

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        var addedCount = 0
        for t in texts where !t.isEmpty {
            let newItem = ShelfItem(kind: .text(string: t), isTemporary: false)
            ShelfStateViewModel.shared.add([newItem])
            addedCount += 1
        }

        if addedCount == 0 {
            throw NSError(domain: "AddShelfTextIntent", code: 1, userInfo: [NSLocalizedDescriptionKey: "No text provided"]) 
        }

        let title = addedCount == 1 ? texts.first! : "\(addedCount) texts"
        return .result(dialog: "Added \(title) to your shelf")
    }
}

// Register intents
struct ShelfShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
            AppShortcut(
                intent: AddShelfFileIntent(),
                phrases: [
                    "Add files to \(.applicationName)",
                    "Add items to shelf with \(.applicationName)"
                ],
                shortTitle: "Add File",
                systemImageName: "doc.fill"
            )
            AppShortcut(
                intent: AddShelfURLIntent(),
                phrases: [
                    "Add links to \(.applicationName)",
                    "Add URLs to \(.applicationName)"
                ],
                shortTitle: "Add Link",
                systemImageName: "link"
            )
            AppShortcut(
                intent: AddShelfTextIntent(),
                phrases: [
                    "Add text to \(.applicationName)",
                    "Add notes to \(.applicationName)"
                ],
                shortTitle: "Add Text",
                systemImageName: "text.quote"
            )
    }
}
