import AppKit
import ClipShareCore
import SwiftUI

struct MainView: View {
    @Bindable var model: AppModel
    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let job = model.job {
                JobView(model: model, job: job)
            } else {
                dropZone
            }

            if let pending = model.pendingUpload, model.job == nil {
                pendingBanner(pending)
            }

            if let selectedVideo {
                VideoDetailView(model: model, video: selectedVideo)
            } else {
                recentVideos
            }

            footer
        }
        .padding(16)
    }

    private var selectedVideo: Video? {
        guard let selectedVideoID = model.selectedVideoID else { return nil }
        return model.videos.first { $0.id == selectedVideoID }
    }

    private var recentVideos: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent")
                .font(.headline)

            if let listError = model.listError {
                Text(listError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if model.videos.isEmpty, !model.isRefreshing {
                Text("Nothing uploaded yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 56)
            } else {
                // The menu bar window sizes itself to its content, and a
                // ScrollView needs an explicit height to display its rows.
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.videos, id: \.id) { video in
                            VideoRow(model: model, video: video)
                            if video.id != model.videos.last?.id {
                                Divider()
                            }
                        }
                    }
                }
                .frame(height: min(CGFloat(model.videos.count) * 53, 280))
            }
        }
    }

    private var dropZone: some View {
        RoundedRectangle(cornerRadius: 10)
            .stroke(
                isDropTargeted ? Color.accentColor : Color.secondary,
                style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1, dash: [5, 4])
            )
            .frame(height: 88)
            .overlay {
                VStack(spacing: 8) {
                    Label("Drop a video here", systemImage: "arrow.down.doc")
                    Button("Choose…") {
                        model.chooseFile()
                    }
                    .controlSize(.small)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .dropDestination(for: URL.self) { urls, _ in
                model.handleDrop(urls: urls)
                return !urls.isEmpty
            } isTargeted: { targeted in
                isDropTargeted = targeted
            }
    }

    private func pendingBanner(_ pending: PendingUpload) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(.secondary)
            Text("An upload didn't finish: \(pending.originalFilename)")
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if pending.videoID != nil {
                Button("Resume") {
                    model.resumePending()
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.small)
            }
            Button("Discard") {
                model.discardPending()
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private var footer: some View {
        HStack {
            Button {
                model.refresh()
            } label: {
                Label {
                    Text("Refresh")
                } icon: {
                    Image(systemName: "arrow.clockwise")
                        .symbolEffect(.rotate, options: .repeating, isActive: model.isRefreshing)
                }
            }
            .disabled(model.isRefreshing)

            Spacer()

            Button("Settings…") {
                model.showSettings()
            }
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .controlSize(.small)
    }
}
