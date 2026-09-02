import AppKit
import SwiftUI

@MainActor
final class DropPanel: NSPanel {
    private static let panelSize = NSSize(width: 240, height: 150)
    private static let inset: CGFloat = 24
    private static let originDefaultsKey = "dropPanelOrigin"
    private var transitionID = 0
    private var savesUserMoves = false
    private var isApplyingPosition = false
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        alphaValue = 0
        contentView = NSHostingView(rootView: DropPanelView(model: model))
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(panelDidMove),
            name: NSWindow.didMoveNotification,
            object: self
        )
    }

    override var canBecomeKey: Bool { false }

    static func clearSavedOrigin() {
        UserDefaults.standard.removeObject(forKey: originDefaultsKey)
    }

    func setSavesUserMoves(_ savesUserMoves: Bool) {
        self.savesUserMoves = savesUserMoves
    }

    func showPanel() {
        transitionID += 1
        positionNearMouse()
        guard !isVisible || alphaValue < 1 else { return }
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            animator().alphaValue = 1
        }
    }

    func hidePanel() {
        guard isVisible else { return }
        transitionID += 1
        let currentTransitionID = transitionID
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, transitionID == currentTransitionID else { return }
                orderOut(nil)
            }
        }
    }

    private func positionNearMouse() {
        if let savedOrigin, isFullyVisible(origin: savedOrigin) {
            applyPosition(savedOrigin)
            return
        }

        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first {
            NSMouseInRect(mouseLocation, $0.frame, false)
        } ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else { return }
        let left = visibleFrame.minX + Self.inset
        let right = visibleFrame.maxX - Self.panelSize.width - Self.inset
        let bottom = visibleFrame.minY + Self.inset
        let top = visibleFrame.maxY - Self.panelSize.height - Self.inset
        let origin: NSPoint
        switch model.dropPanelCorner {
        case .bottomLeft: origin = NSPoint(x: left, y: bottom)
        case .bottomRight: origin = NSPoint(x: right, y: bottom)
        case .topLeft: origin = NSPoint(x: left, y: top)
        case .topRight: origin = NSPoint(x: right, y: top)
        }
        applyPosition(origin)
    }

    private var savedOrigin: NSPoint? {
        guard let coordinates = UserDefaults.standard.array(forKey: Self.originDefaultsKey) as? [NSNumber],
              coordinates.count == 2 else {
            return nil
        }
        return NSPoint(x: coordinates[0].doubleValue, y: coordinates[1].doubleValue)
    }

    private func isFullyVisible(origin: NSPoint) -> Bool {
        let proposedFrame = NSRect(origin: origin, size: Self.panelSize)
        return NSScreen.screens.contains { $0.visibleFrame.contains(proposedFrame) }
    }

    private func applyPosition(_ origin: NSPoint) {
        isApplyingPosition = true
        setFrameOrigin(origin)
        isApplyingPosition = false
    }

    @objc private func panelDidMove() {
        guard savesUserMoves, !isApplyingPosition else { return }
        UserDefaults.standard.set(
            [Double(frame.origin.x), Double(frame.origin.y)],
            forKey: Self.originDefaultsKey
        )
    }
}
