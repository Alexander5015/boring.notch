
import Foundation

struct CatalogEntry: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let version: String
    let summary: String
    let developer: String
    let repository: URL?
    let license: String?

    let downloadURL: URL
    let sha256: String

    var providerAppName: String { "\(name.replacingOccurrences(of: " ", with: ""))" }
}

struct ExtensionCatalog: Sendable {

    enum CatalogError: Error, LocalizedError {
        case badRepository(String)
        case http(Int)
        case noRecords

        var errorDescription: String? {
            switch self {
            case .badRepository(let url): "\(url) is not a GitHub registry repository."
            case .http(let code): "The registry answered HTTP \(code)."
            case .noRecords: "The registry has no extension records."
            }
        }
    }

    static let registry = URL(string: "https://github.com/TheBoredTeam/boring-notch-extensions")!

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func load(from repository: URL = ExtensionCatalog.registry) async throws -> [CatalogEntry] {
        let listing = try await fetchJSON(url: contentsURL(for: repository))
        guard let files = try JSONSerialization.jsonObject(with: listing) as? [[String: Any]] else {
            throw CatalogError.noRecords
        }

        var entries: [CatalogEntry] = []
        for file in files {
            guard let name = file["name"] as? String, name.hasSuffix(".toml"),
                  let raw = file["download_url"] as? String,
                  let url = URL(string: raw),
                  let data = try? await fetch(url),
                  let text = String(data: data, encoding: .utf8),
                  let entry = CatalogEntry(record: text) else { continue }
            entries.append(entry)
        }
        guard !entries.isEmpty else { throw CatalogError.noRecords }
        return entries.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw CatalogError.http(http.statusCode)
        }
        return data
    }

    private func contentsURL(for repository: URL) -> URL {
        let parts = repository.path.split(separator: "/").map(String.init)
        return URL(
            string: "https://api.github.com/repos/\(parts[0])/\(parts[1])/contents/extensions")!
    }

    private func fetchJSON(url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw CatalogError.http(http.statusCode)
        }
        return data
    }
}

extension CatalogEntry {
    init?(record: String) {
        guard let root = try? TOML.parse(record),
              let id = root.string("id"),
              let name = root.string("name"),
              let version = root.string("version"),
              let release = root.table("release"),
              let urlString = release.string("url"),
              let url = URL(string: urlString),
              let sha = release.string("sha256")
        else { return nil }

        self.id = id
        self.name = name
        self.version = version
        self.summary = root.string("description") ?? ""
        self.developer = root.string("publisher") ?? ""
        self.repository = root.string("repository").flatMap(URL.init(string:))
        self.license = root.string("license")
        self.downloadURL = url
        self.sha256 = sha
    }
}