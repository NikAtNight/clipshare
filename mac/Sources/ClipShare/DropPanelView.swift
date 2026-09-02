import SwiftUI

struct DropPanelView: View {
    let model: AppModel

    @State private var isTargeted = false
    @State private var notice: String?
    @State private var noticeID: UUID?

    var body: some View {
        Group {
            if model.isPositioningPanel {
                positioningCard
            } else if let job = model.job {
                jobCard(job)
            } else {
                dropCard
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .dropDestination(for: URL.self) { urls, _ in
            let wasRunning = model.isJobRunning
            model.handleDrop(urls: urls)
            if wasRunning, !urls.isEmpty {
                showRunningJobNotice()
            }
            return true
        } isTargeted: { targeted in
            isTargeted = targeted
        }
        .padding(1)
    }

    private var positioningCard: some View {
        VStack(spacing: 8) {
            Image(systemName: "hand.draw")
                .font(.system(size: 28))
            Text("Drag me anywhere")
                .font(.headline)
            Text("Then click Done")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Done") {
                model.isPositioningPanel = false
            }
            .controlSize(.small)
        }
    }

    private var dropCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    isTargeted ? Color.accentColor : Color.secondary,
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])
                )
                .padding(8)

            VStack(spacing: 8) {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 28))
                Text("Drop to upload")
                    .font(.headline)
                Text("ClipShare")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func jobCard(_ job: AppModel.Job) -> some View {
        VStack(spacing: 8) {
            JobView(model: model, job: job, compact: true)
            if let notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
            }
        }
        .padding(8)
        .animation(.easeInOut(duration: 0.15), value: notice)
    }

    private func showRunningJobNotice() {
        let message = "Wait for the current upload to finish."
        let currentNoticeID = UUID()
        notice = message
        noticeID = currentNoticeID
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if noticeID == currentNoticeID {
                notice = nil
                noticeID = nil
            }
        }
    }
}
