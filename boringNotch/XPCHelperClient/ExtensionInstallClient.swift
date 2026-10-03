
import CryptoKit
import Foundation

enum ExtensionInstallError: Error, LocalizedError {
    case downloadFailed(String)
    case hashMismatch
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let why): "The download failed: \(why)"
        case .hashMismatch: "The download did not match its published checksum."
        case .unavailable(let why): why
        }
    }
}

struct ExtensionInstallClient {
    let helper: XPCHelperClient

    static let extensionPoint = "theboringteam.boringnotch.notch-tab"

    struct Installed {
        let providerPath: String
        let extensionBundleID: String
    }

    @MainActor
    func install(from url: URL, expectedSHA256 hex: String, appName: String) async throws -> Installed {
        let archive = try await Self.download(url)
        try Self.verify(archive, against: hex)

        let service = await helper.extensionService()
        return try await service.withContinuation { service, continuation in
            service.installExtension(
                archive: archive,
                appName: appName,
                expectedExtensionPoint: Self.extensionPoint
            ) { path, bundleID, failure in
                if let path, let bundleID {
                    continuation.resume(
                        returning: Installed(providerPath: path, extensionBundleID: bundleID))
                } else {
                    continuation.resume(
                        throwing: ExtensionInstallError.unavailable(
                            failure ?? "The installer did not report a result."))
                }
            }
        }
    }

    @MainActor
    func uninstall(providerAt path: String) async throws {
        let service = await helper.extensionService()
        try await service.withContinuation { (service, continuation: CheckedContinuation<Void, Error>) in
            service.uninstallExtension(atPath: path) { failure in
                if let failure {
                    continuation.resume(throwing: ExtensionInstallError.unavailable(failure))
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    @MainActor
    func installedExtensionBundleIDs() async -> [String] {
        let service = await helper.extensionService()
        return (try? await service.withContinuation { service, continuation in
            service.installedExtensionBundleIDs { continuation.resume(returning: $0) }
        }) ?? []
    }

    @MainActor
    func isInstalled(extensionBundleID bundleID: String) async -> Bool {
        let service = await helper.extensionService()
        return (try? await service.withContinuation { service, continuation in
            service.isExtensionInstalled(bundleID) { continuation.resume(returning: $0) }
        }) ?? false
    }

    @MainActor
    func pruneForeignRecords(forExtensionBundleIDs identifiers: [String]) async -> [String] {
        guard !identifiers.isEmpty else { return [] }
        let service = await helper.extensionService()
        return (try? await service.withContinuation { service, continuation in
            service.pruneForeignExtensionRecords(forExtensionBundleIDs: identifiers) {
                continuation.resume(returning: $0)
            }
        }) ?? []
    }

    private static func download(_ url: URL) async throws -> Data {
        if url.isFileURL {
            return try Data(contentsOf: url)
        }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ExtensionInstallError.downloadFailed("the server answered \(http.statusCode)")
        }
        return data
    }

    private static func verify(_ archive: Data, against hex: String) throws {
        let digest = SHA256.hash(data: archive)
        let actual = digest.map { String(format: "%02x", $0) }.joined()
        guard actual.caseInsensitiveCompare(hex) == .orderedSame else {
            throw ExtensionInstallError.hashMismatch
        }
    }
}
