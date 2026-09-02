import AppKit
import UniformTypeIdentifiers

@MainActor
final class DragMonitor {
    var onDragBegan: () -> Void = {}
    var onDragEnded: () -> Void = {}

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var lastChangeCount: Int
    private var isActive = false
    private var dragEndTask: Task<Void, Never>?

    init() {
        lastChangeCount = NSPasteboard(name: .drag).changeCount
        let mask: NSEvent.EventTypeMask = [.leftMouseDragged, .leftMouseUp]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handle(event)
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handle(event)
            }
            return event
        }
    }

    deinit {
        dragEndTask?.cancel()
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDragged:
            inspectDragPasteboard()
        case .leftMouseUp:
            finishDragAfterDropDelivery()
        default:
            break
        }
    }

    private func inspectDragPasteboard() {
        let pasteboard = NSPasteboard(name: .drag)
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount

        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.movie.identifier, UTType.video.identifier],
        ]
        guard pasteboard.readObjects(forClasses: [NSURL.self], options: options)?.isEmpty == false else {
            return
        }
        guard !isActive else { return }
        isActive = true
        onDragBegan()
    }

    private func finishDragAfterDropDelivery() {
        guard isActive else { return }
        dragEndTask?.cancel()
        dragEndTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            isActive = false
            onDragEnded()
        }
    }
}
