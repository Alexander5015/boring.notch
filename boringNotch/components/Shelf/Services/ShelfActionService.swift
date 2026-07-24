//
//  ShelfActionService.swift
//  boringNotch
//
//  Created by Alexander on 2025-10-07.
//

import AppKit
import Foundation

/// Common actions shared by shelf item interactions.
@MainActor
enum ShelfActionService {

    static func open(_ item: ShelfItem) {
        switch item.kind {
        case .file:
            Task {
                guard let file = await ShelfStateViewModel.shared.resolveFile(for: item, refresh: true) else {
                    return
                }
                _ = file.url.accessSecurityScopedResource { url in
                    NSWorkspace.shared.open(url)
                }
            }
        case .link(let url):
            NSWorkspace.shared.open(url)
        case .text(let string):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(string, forType: .string)
        }
    }

    static func remove(_ item: ShelfItem) {
        ShelfStateViewModel.shared.remove(item)
    }
}
