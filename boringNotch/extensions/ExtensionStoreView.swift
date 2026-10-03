
import ExtensionKit
import SwiftUI

@MainActor
@Observable
final class ExtensionStoreModel {
    private(set) var entries: [CatalogEntry] = []
    private(set) var loading = true
    private(set) var failure: String?

    private(set) var installedPacks: Set<String> = []

    private(set) var working: [String: Progress] = [:]

    enum Progress: Equatable {
        case installing
        case installed
        case failed(String)
    }

    private let client: ExtensionInstallClient
    private let catalog: ExtensionCatalog

    init() {
        self.client = ExtensionInstallClient(helper: .shared)
        self.catalog = ExtensionCatalog()
    }

    func load() async {
        loading = true
        failure = nil
        await refreshInstalled()
        do {
            entries = try await catalog.load()
            if CommandLine.arguments.contains("--tmp-store-install") {
                Task { @MainActor in if let first = entries.first { await install(first) } }
            }
        } catch {
            NSLog("ExtensionStore: catalog unavailable: %@", error.localizedDescription)
            failure = error.localizedDescription
        }
        loading = false
    }

    func refreshInstalled() async {
        var packs: Set<String> = []
        for entry in entries {
            for bundleID in entry.bundleIDs
            where await client.isInstalled(extensionBundleID: bundleID) {
                packs.insert(entry.id)
            }
        }
        installedPacks = packs
    }

    func install(_ entry: CatalogEntry) async {
        guard working[entry.id] == nil else { return }
        working[entry.id] = .installing
        defer { working[entry.id] = nil }
        do {
            _ = try await client.install(
                from: entry.downloadURL,
                expectedSHA256: entry.sha256,
                appName: entry.providerAppName)
            working[entry.id] = .installed
            await refreshInstalled()
        } catch {
            working[entry.id] = .failed(error.localizedDescription)
        }
    }

    func state(for entry: CatalogEntry) -> Progress? { working[entry.id] }
    func isInstalled(_ entry: CatalogEntry) -> Bool {
        installedPacks.contains(entry.id)
    }
}

struct ExtensionStoreView: View {
    @State private var model = ExtensionStoreModel()
    @State private var showingApproval = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: 620, height: 460)
        .task { await model.load() }
        .sheet(isPresented: $showingApproval) {
            ExtensionApprovalView()
                .frame(minWidth: 560, minHeight: 420)
        }
    }

    private var header: some View {
        HStack {
            Text("Extensions").font(.headline)
            Spacer()
            Button {
                showingApproval = true
            } label: {
                Label("Manage", systemImage: "checklist")
            }
            .help("Approve, enable or disable installed extensions")
        }
        .padding()
    }

    @ViewBuilder
    private var content: some View {
        if model.loading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.entries.isEmpty {
            unavailable(model.failure ?? "The registry has nothing to offer right now.")
        } else {
            List(model.entries) { entry in
                row(entry)
            }
        }
    }

    private func row(_ entry: CatalogEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name).font(.headline)
                if !entry.summary.isEmpty {
                    Text(entry.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    Text("v\(entry.version)")
                    if !entry.developer.isEmpty { Text("· \(entry.developer)") }
                    if let license = entry.license { Text("· \(license)") }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            action(for: entry)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func action(for entry: CatalogEntry) -> some View {
        switch model.state(for: entry) {
        case .installing:
            ProgressView().controlSize(.small)
        case .installed:
            Label("Installed", systemImage: "checkmark.circle.fill")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.green)
                .font(.callout)
        case .failed(let why):
            VStack(alignment: .trailing, spacing: 4) {
                Text(why).font(.caption).foregroundStyle(.red).multilineTextAlignment(.trailing)
                button("Retry", entry)
            }
        case nil:
            if model.isInstalled(entry) {
                HStack(spacing: 8) {
                    Label("Installed", systemImage: "checkmark.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.green)
                        .font(.callout)
                    Button("Reinstall") {
                        Task { await model.install(entry) }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            } else {
                button("Install", entry)
            }
        }
    }

    private func button(_ title: String, _ entry: CatalogEntry) -> some View {
        Button(title) {
            Task { await model.install(entry) }
        }
        .buttonStyle(.borderedProminent)
    }

    private func unavailable(_ why: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.circle").font(.system(size: 26)).foregroundStyle(.tertiary)
            Text(why).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

struct ExtensionApprovalView: NSViewControllerRepresentable {
    func makeNSViewController(context: Context) -> EXAppExtensionBrowserViewController {
        EXAppExtensionBrowserViewController()
    }

    func updateNSViewController(_ controller: EXAppExtensionBrowserViewController, context: Context) {}
}