
import Foundation

enum ExtensionInstallRoot {
    static let url: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("BoringNotch", isDirectory: true)
            .appendingPathComponent("Extensions", isDirectory: true)
    }()
}
