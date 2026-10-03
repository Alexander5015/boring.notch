
import Foundation

enum ExtensionInstallRoot {
    static let url: URL = {
        URL(fileURLWithPath: realHomeDirectory, isDirectory: true)
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("BoringNotch", isDirectory: true)
            .appendingPathComponent("Extensions", isDirectory: true)
    }()

    static var realHomeDirectory: String {
        realHomeDirectory(in: NSHomeDirectory())
    }

    static func realHomeDirectory(in seen: String) -> String {
        let marker = "/Library/Containers/"
        guard let range = seen.range(of: marker) else { return seen }
        return String(seen[seen.startIndex..<range.lowerBound])
    }
}
