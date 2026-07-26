import Foundation

private final class BlockingResolution: @unchecked Sendable {
    private let lock = NSLock()
    private let started = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private var invocationCount = 0

    func resolve(_ data: Data) -> ResolvedShelfFile? {
        lock.lock()
        invocationCount += 1
        lock.unlock()

        started.signal()
        release.wait()
        return nil
    }

    func waitForInvocation(timeout: TimeInterval = 1) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: self.started.wait(timeout: .now() + timeout) == .success)
            }
        }
    }

    func count() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return invocationCount
    }

    func unblock() {
        release.signal()
    }
}

private func waitForSignal(_ signal: DispatchSemaphore, timeout: TimeInterval = 1) async -> Bool {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: signal.wait(timeout: .now() + timeout) == .success)
        }
    }
}

@main
struct ShelfBookmarkResolverRegression {
    static func main() async {
        let payload = Data("identical-bookmark".utf8)
        let blockingResolution = BlockingResolution()
        let resolver = ShelfBookmarkResolver { data in
            blockingResolution.resolve(data)
        }

        let first = Task { await resolver.resolve(payload) }
        guard await blockingResolution.waitForInvocation() else {
            fputs("FAIL: underlying resolver did not start\n", stderr)
            exit(1)
        }

        let secondCallerSubmitted = DispatchSemaphore(value: 0)
        let second = Task {
            secondCallerSubmitted.signal()
            return await resolver.resolve(payload)
        }
        guard await waitForSignal(secondCallerSubmitted) else {
            fputs("FAIL: second caller did not start\n", stderr)
            exit(1)
        }

        let duplicateInvocationStarted = await blockingResolution.waitForInvocation()
        blockingResolution.unblock()
        blockingResolution.unblock()
        _ = await first.value
        _ = await second.value
        let calls = blockingResolution.count()

        guard !duplicateInvocationStarted, calls == 1 else {
            fputs("FAIL: expected one underlying call, got \(calls)\n", stderr)
            exit(1)
        }

        print("PASS: one underlying call")
    }
}
