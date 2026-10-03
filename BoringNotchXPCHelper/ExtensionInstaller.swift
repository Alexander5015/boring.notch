
import AppKit
import CoreServices
import Foundation

enum InstallFailure: Error, LocalizedError {
    case badArchive
    case notAnExtension(expected: String, found: String)
    case signatureInvalid(String)
    case launchServicesRefused(OSStatus, URL)
    case toolFailed(String, String)
    case timedOut(String)
    case notIndexed(String)

    var errorDescription: String? {
        switch self {
        case .badArchive:
            return "The download could not be opened as an extension package."
        case .notAnExtension(let expected, let found):
            return found == "none"
                ? "That package contains no app extension. It is built for a different kind of host."
                : "That package is built for \(found), not for \(expected)."
        case .signatureInvalid(let why):
            return "The package is not correctly signed: \(why)"
        case .launchServicesRefused(let status, let url):
            let reason = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
            return "macOS refused to register \(url.lastPathComponent): \(reason) (\(status))"
        case .toolFailed(let tool, let why):
            return "\(tool) failed: \(why)"
        case .timedOut(let tool):
            return "\(tool) did not respond in time."
        case .notIndexed(let bundleID):
            return "The system did not register \(bundleID). It may need approval in System Settings."
        }
    }
}

struct InstalledExtension {
    let providerPath: String
    let extensionBundleID: String
    let note: String?
}

enum Tool {
    struct Result {
        let status: Int32?
        let out: String
        let err: String
        let timedOut: Bool
        var succeeded: Bool { status == 0 && !timedOut }
    }

    static func run(_ path: String, _ arguments: [String], seconds: TimeInterval = 15) -> Result {
        let tmp = NSTemporaryDirectory()
        let outURL = URL(fileURLWithPath: tmp).appendingPathComponent("bnk-o-\(UUID().uuidString)")
        let errURL = URL(fileURLWithPath: tmp).appendingPathComponent("bnk-e-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        defer {
            try? FileManager.default.removeItem(at: outURL)
            try? FileManager.default.removeItem(at: errURL)
        }

        guard let out = FileHandle(forWritingAtPath: outURL.path),
              let err = FileHandle(forWritingAtPath: errURL.path) else {
            return Result(status: nil, out: "", err: "", timedOut: false)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch {
            try? out.close(); try? err.close()
            return Result(status: nil, out: "", err: error.localizedDescription, timedOut: false)
        }

        let deadline = Date().addingTimeInterval(seconds)
        var timedOut = false
        while process.isRunning {
            if Date() >= deadline {
                timedOut = true
                process.terminate()
                let grace = Date().addingTimeInterval(1)
                while process.isRunning && Date() < grace {
                    Thread.sleep(forTimeInterval: 0.02)
                }
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        process.waitUntilExit()
        try? out.close(); try? err.close()

        let outText = (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
        let errText = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
        return Result(status: timedOut ? nil : process.terminationStatus,
                      out: outText, err: errText, timedOut: timedOut)
    }
}

enum ExtensionInstaller {

    static let installRoot: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("BoringNotch", isDirectory: true)
            .appendingPathComponent("Extensions", isDirectory: true)
    }()

    private static let lsregister =
        "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    static func install(
        archive: Data,
        appName: String,
        expectedExtensionPoint: String
    ) throws -> InstalledExtension {
        let scratch = installRoot
            .deletingLastPathComponent()
            .appendingPathComponent("InstallScratch", isDirectory: true)
        try? FileManager.default.removeItem(at: scratch)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let zip = scratch.appendingPathComponent("pack.zip")
        guard (try? archive.write(to: zip, options: .atomic)) != nil else {
            throw InstallFailure.badArchive
        }

        let unpacked = scratch.appendingPathComponent("unpacked", isDirectory: true)
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        let unzip = Tool.run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
        if unzip.timedOut { throw InstallFailure.timedOut("ditto") }
        guard unzip.succeeded else { throw InstallFailure.toolFailed("ditto", unzip.err) }

        guard let provider = try firstAppBundle(in: unpacked) else {
            throw InstallFailure.badArchive
        }

        let extensionBundleID = try validate(
            provider: provider, expectedExtensionPoint: expectedExtensionPoint)

        evictStaleRecords(for: extensionBundleID, keeping: provider)

        let appName = appName.hasSuffix(".app") ? appName : appName + ".app"
        let destination = installRoot
            .appendingPathComponent(safe(Bundle(url: provider)?.bundleIdentifier ?? "unknown"), isDirectory: true)
            .appendingPathComponent(appName, isDirectory: true)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: provider, to: destination)

        try register(destination)
        try awaitIndexed(extensionBundleID, inside: destination)

        return InstalledExtension(
            providerPath: destination.path,
            extensionBundleID: extensionBundleID,
            note: nil)
    }

    private static func register(_ provider: URL) throws {
        let status = LSRegisterURL(provider as CFURL, true)
        guard status == noErr else { throw InstallFailure.launchServicesRefused(status, provider) }

        for appex in embeddedExtensions(of: provider) {
            let result = Tool.run("/usr/bin/pluginkit", ["-a", appex.path])
            if result.timedOut { throw InstallFailure.timedOut("pluginkit") }
            guard result.succeeded else {
                throw InstallFailure.toolFailed("pluginkit", result.err)
            }
        }
    }

    private static func samePath(_ lhs: String, _ rhs: String) -> Bool {
        lhs.lowercased() == rhs.lowercased()
    }

    private static func evictStaleRecords(for bundleID: String, keeping provider: URL) {
        guard let keep = try? firstExtensionBundle(in: provider) else { return }
        let wanted = keep.standardizedFileURL.path
        for path in registeredPaths(for: bundleID) {
            let normalised = URL(fileURLWithPath: path).standardizedFileURL.path
            guard !samePath(normalised, wanted) else { continue }
            _ = Tool.run("/usr/bin/pluginkit", ["-r", normalised])
        }
    }

    static func embeddedExtensions(of provider: URL) -> [URL] {
        let directory = provider.appendingPathComponent("Contents/Extensions", isDirectory: true)
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return contents.filter { $0.hasSuffix(".appex") }
            .map { directory.appendingPathComponent($0) }
    }

    private static func awaitIndexed(_ bundleID: String, inside provider: URL) throws {
        guard let appex = try? firstExtensionBundle(in: provider) else {
            throw InstallFailure.notAnExtension(expected: "", found: "none")
        }
        let wanted = appex.standardizedFileURL.path
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            let found = registeredPaths(for: bundleID)
                .contains { (path: String) in
                    samePath(URL(fileURLWithPath: path).standardizedFileURL.path, wanted)
                }
            if found { return }
            Thread.sleep(forTimeInterval: 0.4)
        }
        throw InstallFailure.notIndexed(bundleID)
    }

    static func registeredPaths(for bundleID: String) -> [String] {
        let result = Tool.run("/usr/bin/pluginkit", ["-m", "-v", "-A", "-D", "-i", bundleID])
        guard result.succeeded else { return [] }
        return result.out
            .split(separator: "\n")
            .compactMap { line -> String? in
                guard let path = line.split(separator: "\t").last,
                      path.hasPrefix("/") else { return nil }
                return String(path)
            }
            .filter { !$0.isEmpty }
    }

    static func providerPath(forExtensionBundleID bundleID: String) -> String? {
        let fileManager = FileManager.default
        guard let providers = try? fileManager.contentsOfDirectory(
            at: installRoot, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
        else { return nil }
        var candidates: [URL] = []
        for directory in providers {
            guard let apps = try? fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
            else { continue }
            candidates.append(contentsOf: apps.filter { $0.pathExtension == "app" })
        }
        candidates.append(contentsOf: providers.filter { $0.pathExtension == "app" })
        for provider in candidates {
            guard let appex = try? firstExtensionBundle(in: provider),
                  Bundle(url: appex)?.bundleIdentifier == bundleID else { continue }
            return provider.path
        }
        return nil
    }

    @discardableResult
    static func pruneForeignRecords(forExtensionBundleIDs identifiers: [String]) -> [String] {
        let root = installRoot.standardizedFileURL.path
        var removed: [String] = []
        for identifier in identifiers {
            for path in registeredPaths(for: identifier) {
                let normalised = URL(fileURLWithPath: path).standardizedFileURL.path
                guard !normalised.lowercased().hasPrefix(root.lowercased() + "/") else { continue }
                if Tool.run("/usr/bin/pluginkit", ["-r", normalised]).succeeded {
                    removed.append(normalised)
                }
            }
        }
        return removed
    }

    static func isRegistered(_ bundleID: String) -> Bool {
        !registeredPaths(for: bundleID).isEmpty
    }

    static func installedExtensionBundleIDs() -> [String] {
        let result = Tool.run("/usr/bin/pluginkit", ["-m", "-v", "-A", "-D"])
        guard result.succeeded else { return [] }
        var seen: Set<String> = []
        for line in result.out.split(separator: "\n") {
            guard let paren = line.firstIndex(of: "(") else { continue }
            let identifier = line[..<paren]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "+-"))
                .trimmingCharacters(in: .whitespaces)
            guard identifier.contains("."), !identifier.contains(" ") else { continue }
            seen.insert(identifier)
        }
        return Array(seen).sorted()
    }

    static func uninstall(providerAt path: String) throws {
        let url = URL(fileURLWithPath: path)
        let root = installRoot.standardizedFileURL.path
        guard url.standardizedFileURL.path.lowercased().hasPrefix(root.lowercased() + "/") else {
            throw InstallFailure.toolFailed("uninstall", "\(path) is not an installed extension")
        }
        if let appex = try? firstExtensionBundle(in: url) {
            _ = Tool.run("/usr/bin/pluginkit", ["-r", appex.path])
        }
        try? FileManager.default.removeItem(at: url)
        _ = Tool.run(lsregister, ["-u", url.path])
    }

    private static func validate(
        provider: URL,
        expectedExtensionPoint: String
    ) throws -> String {
        guard let appex = try firstExtensionBundle(in: provider) else {
            throw InstallFailure.notAnExtension(expected: expectedExtensionPoint, found: "none")
        }
        guard let info = Bundle(url: appex)?.object(forInfoDictionaryKey: "EXAppExtensionAttributes")
                as? [String: Any] else {
            throw InstallFailure.notAnExtension(expected: expectedExtensionPoint, found: "none")
        }
        let point = (info["EXExtensionPointIdentifier"] as? String) ?? "none"
        guard point == expectedExtensionPoint else {
            throw InstallFailure.notAnExtension(expected: expectedExtensionPoint, found: point)
        }
        guard let bundleID = Bundle(url: appex)?.bundleIdentifier else {
            throw InstallFailure.notAnExtension(expected: expectedExtensionPoint, found: "none")
        }

        let verify = Tool.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", appex.path])
        if verify.timedOut { throw InstallFailure.timedOut("codesign") }
        guard verify.succeeded else {
            throw InstallFailure.signatureInvalid(
                verify.err.isEmpty ? "the signature did not verify" : verify.err)
        }
        return bundleID
    }

    private static func firstAppBundle(in directory: URL) throws -> URL? {
        try firstBundle(in: directory, withExtension: "app")
    }

    private static func firstExtensionBundle(in app: URL) throws -> URL? {
        let nested = app.appendingPathComponent("Contents/Extensions", isDirectory: true)
        return try firstBundle(in: nested, withExtension: "appex")
    }

    private static func firstBundle(in directory: URL, withExtension ext: String) throws -> URL? {
        let children = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
        return children.first { $0.pathExtension == ext }
    }

    private static func safe(_ identifier: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
        var out = ""
        for scalar in identifier.unicodeScalars {
            out.unicodeScalars.append(allowed.contains(scalar) ? scalar : "_")
        }
        return out
    }
}