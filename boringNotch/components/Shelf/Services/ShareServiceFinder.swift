//
//  ShareServiceFinder.swift
//  boringNotch
//
//  Created by Alexander on 2025-10-06.
//

import Cocoa

@MainActor
private final class ShareServiceFinderRequest {
    private let picker: NSSharingServicePicker
    private var continuation: CheckedContinuation<[NSSharingService], Never>?
    private var timeoutTask: Task<Void, Never>?
    private var isFinished = false
    private var resultBeforeWait: [NSSharingService]?

    init(picker: NSSharingServicePicker) {
        self.picker = picker
    }

    func wait(relativeTo view: NSView, timeout: TimeInterval) async -> [NSSharingService] {
        await withCheckedContinuation { continuation in
            guard !isFinished else {
                continuation.resume(returning: resultBeforeWait ?? [])
                return
            }

            self.continuation = continuation
            timeoutTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: .seconds(timeout))
                } catch {
                    return
                }

                guard let self, !Task.isCancelled, !self.isFinished else { return }
                Log.shelf.debug("Warning: timed out waiting for sharing services")
                self.finish([])
            }

            picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        }
    }

    func finish(_ services: [NSSharingService]) {
        guard !isFinished else { return }
        isFinished = true

        timeoutTask?.cancel()
        timeoutTask = nil
        picker.close()

        if let continuation {
            self.continuation = nil
            continuation.resume(returning: services)
        } else {
            resultBeforeWait = services
        }
    }
}

class ShareServiceFinder: NSObject, NSSharingServicePickerDelegate {
    @MainActor
    private var onServicesCaptured: (([NSSharingService]) -> Void)?

    /// Returns share services asynchronously without blocking the UI.
    /// Cancelling provider discovery also closes its temporary picker.
    @MainActor
    func findApplicableServices(for items: [Any], timeout: TimeInterval = 2.0) async -> [NSSharingService] {
        let dummyView = NSView(frame: .zero)
        let picker = NSSharingServicePicker(items: items)
        picker.delegate = self
        let request = ShareServiceFinderRequest(picker: picker)

        onServicesCaptured = { services in
            request.finish(services)
        }

        let services = await withTaskCancellationHandler {
            await request.wait(relativeTo: dummyView, timeout: timeout)
        } onCancel: {
            Task { @MainActor [weak request] in
                request?.finish([])
            }
        }

        onServicesCaptured = nil
        return services
    }

    // MARK: NSSharingServicePickerDelegate

    func sharingServicePicker(
        _ picker: NSSharingServicePicker,
        sharingServicesForItems items: [Any],
        proposedSharingServices proposed: [NSSharingService]
    ) -> [NSSharingService] {
        Task { @MainActor in
            self.onServicesCaptured?(proposed)
        }
        return proposed
    }
}
