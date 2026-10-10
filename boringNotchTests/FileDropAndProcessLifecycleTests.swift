import AppKit
import XCTest
import UniformTypeIdentifiers

@testable import boringNotch

private final class BackgroundCallbackRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func recordCurrentQueue() {
        lock.lock()
        value = !Thread.isMainThread
        lock.unlock()
    }

    var ranInBackground: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

@MainActor
final class FileDropConcurrencyTests: XCTestCase {
    func testPromisedFileDeliveredFromBackgroundQueueIsAddedToShelf() async throws {
        let (sourceDirectory, sourceURL, contents) = try makeSourceFile(named: "promised.pdf")
        let shelf = ShelfStateViewModel.shared
        let initialIDs = Set(shelf.items.map(\.id))
        let recorder = BackgroundCallbackRecorder()
        let provider = makePromisedProvider(
            for: sourceURL,
            contentsType: .pdf,
            recorder: recorder
        )
        defer {
            removeNewShelfItems(from: shelf, excluding: initialIDs)
            try? FileManager.default.removeItem(at: sourceDirectory)
        }

        let delivered = await shelf.processDrop([provider])

        XCTAssertTrue(recorder.ranInBackground, "The provider must deliver its representation on a background queue.")
        XCTAssertEqual(delivered.count, 1)
        let item = try XCTUnwrap(shelf.items.first { !initialIDs.contains($0.id) })
        XCTAssertTrue(item.isTemporary)
        let storedURL = try XCTUnwrap(fileURL(for: item))
        XCTAssertTrue(FileManager.default.fileExists(atPath: storedURL.path))
        XCTAssertEqual(try Data(contentsOf: storedURL), contents)
    }

    func testFailedPromisedFileDoesNotAddAnItem() async throws {
        let (sourceDirectory, sourceURL, _) = try makeSourceFile(named: "failed.pdf")
        let shelf = ShelfStateViewModel.shared
        let initialIDs = Set(shelf.items.map(\.id))
        let recorder = BackgroundCallbackRecorder()
        let provider = makePromisedProvider(
            for: sourceURL,
            contentsType: .pdf,
            recorder: recorder,
            shouldFail: true
        )
        defer {
            removeNewShelfItems(from: shelf, excluding: initialIDs)
            try? FileManager.default.removeItem(at: sourceDirectory)
        }

        let delivered = await shelf.processDrop([provider])

        XCTAssertTrue(recorder.ranInBackground)
        XCTAssertTrue(delivered.isEmpty)
        XCTAssertEqual(Set(shelf.items.map(\.id)), initialIDs)
    }

    func testOrdinaryFileURLDropStillAddsTheOriginalFile() async throws {
        let (sourceDirectory, sourceURL, contents) = try makeSourceFile(named: "ordinary.pdf")
        let shelf = ShelfStateViewModel.shared
        let initialIDs = Set(shelf.items.map(\.id))
        let provider = NSItemProvider(object: sourceURL as NSURL)
        defer {
            removeNewShelfItems(from: shelf, excluding: initialIDs)
            try? FileManager.default.removeItem(at: sourceDirectory)
        }

        let delivered = await shelf.processDrop([provider])

        XCTAssertEqual(delivered.count, 1)
        let item = try XCTUnwrap(shelf.items.first { !initialIDs.contains($0.id) })
        XCTAssertFalse(item.isTemporary)
        XCTAssertEqual(try fileURL(for: item)?.standardizedFileURL, sourceURL.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: sourceURL), contents)
    }

    func testSeveralPromisesAndRepeatedProviderAreRepresentedOnceEach() async throws {
        let (firstDirectory, firstURL, firstContents) = try makeSourceFile(named: "first.pdf")
        let (secondDirectory, secondURL, secondContents) = try makeSourceFile(named: "second.pdf")
        let shelf = ShelfStateViewModel.shared
        let initialIDs = Set(shelf.items.map(\.id))
        let first = makePromisedProvider(for: firstURL, contentsType: .pdf)
        let second = makePromisedProvider(for: secondURL, contentsType: .pdf)
        defer {
            removeNewShelfItems(from: shelf, excluding: initialIDs)
            try? FileManager.default.removeItem(at: firstDirectory)
            try? FileManager.default.removeItem(at: secondDirectory)
        }

        let delivered = await shelf.processDrop([first, second, first])

        XCTAssertEqual(delivered.count, 2)
        let newItems = shelf.items.filter { !initialIDs.contains($0.id) }
        XCTAssertEqual(newItems.count, 2)
        let deliveredContents = try Set(newItems.map { try fileContents(of: $0) })
        XCTAssertEqual(deliveredContents, Set([firstContents, secondContents]))
    }

    private func makePromisedProvider(
        for sourceURL: URL,
        contentsType: UTType,
        recorder: BackgroundCallbackRecorder? = nil,
        shouldFail: Bool = false
    ) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = sourceURL.lastPathComponent
        provider.registerFileRepresentation(
            for: contentsType,
            visibility: .all,
            openInPlace: false
        ) { completion in
            let progress = Progress(totalUnitCount: 1)
            DispatchQueue.global(qos: .userInitiated).async {
                recorder?.recordCurrentQueue()
                if shouldFail {
                    completion(nil, false, NSError(
                        domain: "FileDropConcurrencyTests",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Simulated promised-file failure"]
                    ))
                } else {
                    completion(sourceURL, false, nil)
                }
                progress.completedUnitCount = 1
            }
            return progress
        }
        return provider
    }

    private func makeSourceFile(named name: String) throws -> (URL, URL, Data) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileDropConcurrencyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        let contents = Data("%PDF-1.4\nindependent test payload\n".utf8)
        try contents.write(to: url)
        return (directory, url, contents)
    }

    private func fileURL(for item: ShelfItem) throws -> URL? {
        guard case .file(let bookmarkData) = item.kind else { return nil }
        return Bookmark(data: bookmarkData).resolvedURL
    }

    private func fileContents(of item: ShelfItem) throws -> Data {
        let url = try XCTUnwrap(fileURL(for: item))
        return try Data(contentsOf: url)
    }

    private func removeNewShelfItems(from shelf: ShelfStateViewModel, excluding initialIDs: Set<UUID>) {
        for item in shelf.items.filter({ !initialIDs.contains($0.id) }) {
            shelf.remove(item)
        }
    }
}

@MainActor
final class NowPlayingStreamSessionConcurrencyTests: XCTestCase {
    func testUnexpectedChildTerminationNotifiesOnMainActor() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "exit 23"]

        let failure = expectation(description: "unexpected termination is forwarded to the main actor")
        var callbackCount = 0
        let session = NowPlayingStreamSession(
            process: process,
            onUpdate: { _ in },
            onFailure: {
                XCTAssertTrue(Thread.isMainThread)
                callbackCount += 1
                failure.fulfill()
            }
        )

        session.start()
        await fulfillment(of: [failure], timeout: 5)
        XCTAssertEqual(callbackCount, 1)
        session.stop()
    }

    func testExplicitStopSuppressesTerminationFollowUp() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 2; exit 9"]

        let failure = expectation(description: "stopped session must not trigger a restart")
        failure.isInverted = true
        let session = NowPlayingStreamSession(
            process: process,
            onUpdate: { _ in },
            onFailure: { failure.fulfill() }
        )

        session.start()
        // Both calls run synchronously on MainActor. Stop wins before a queued termination hop can run.
        session.stop()
        await fulfillment(of: [failure], timeout: 0.5)
    }

    func testTimedProcessRunnerUsesTheActualExitStatus() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "exit 23"]

        let succeeded = try await TimedProcessRunner.exitsSuccessfully(process, timeout: .seconds(3))
        XCTAssertFalse(succeeded)
    }
}
