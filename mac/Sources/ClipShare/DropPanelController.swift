import Observation

@MainActor
final class DropPanelController {
    private let model: AppModel
    private let dragMonitor: DragMonitor
    private let panel: DropPanel
    private var isFileDragActive = false

    init(model: AppModel) {
        self.model = model
        dragMonitor = DragMonitor()
        panel = DropPanel(model: model)

        dragMonitor.onDragBegan = { [weak self] in
            guard let self else { return }
            isFileDragActive = true
            updatePanel()
        }
        dragMonitor.onDragEnded = { [weak self] in
            guard let self else { return }
            isFileDragActive = false
            updatePanel()
        }

        updatePanel()
        observePanelState()
    }

    private func observePanelState() {
        withObservationTracking {
            _ = model.job
            _ = model.isPositioningPanel
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                updatePanel()
                observePanelState()
            }
        }
    }

    private func updatePanel() {
        let hasJob = model.job != nil
        panel.setSavesUserMoves(model.isPositioningPanel || hasJob)
        if model.isPositioningPanel || hasJob || isFileDragActive {
            panel.showPanel()
        } else {
            panel.hidePanel()
        }
    }
}
