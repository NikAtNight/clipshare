import ClipShareCore
import SwiftUI

struct VideoDetailView: View {
    let model: AppModel
    let video: Video

    @State private var titleText: String
    @State private var lastSyncedTitle: String
    @State private var isSaving = false
    @State private var isConfirmingDelete = false
    @FocusState private var isTitleFocused: Bool

    init(model: AppModel, video: Video) {
        self.model = model
        self.video = video
        _titleText = State(initialValue: video.title)
        _lastSyncedTitle = State(initialValue: video.title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            titleField

            switch video.status {
            case .ready:
                linkControls
                newLinkControls
            case .uploading:
                statusCaption("Not shared yet")
            case .failed:
                statusCaption("Upload failed")
            }

            deleteControls
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                model.deselect()
            } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])

            Spacer()

            Text(metadata)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var titleField: some View {
        HStack(spacing: 8) {
            TextField("Title", text: $titleText)
                .textFieldStyle(.roundedBorder)
                .font(.headline)
                .focused($isTitleFocused)
                .onSubmit(saveTitle)
                .onChange(of: isTitleFocused) { wasFocused, isFocused in
                    if wasFocused, !isFocused {
                        saveTitle()
                    }
                }
                .onChange(of: video.title) { _, newTitle in
                    if titleText == lastSyncedTitle {
                        titleText = newTitle
                    }
                    lastSyncedTitle = newTitle
                }

            if isSaving {
                Text("Saving…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var linkControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                Text(video.shareUrl?.absoluteString ?? "Link unavailable")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(video.shareEnabled ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 8) {
                    Button {
                        model.copyLink(video)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    Button {
                        model.openLink(video)
                    } label: {
                        Label("Open", systemImage: "safari")
                    }
                }
                .controlSize(.small)
                .disabled(!video.shareEnabled || video.shareUrl == nil)
            }
            .padding(8)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

            Toggle("Link on", isOn: shareEnabledBinding)
        }
    }

    private var newLinkControls: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button("New link") {
                model.newLink(video)
            }
            .controlSize(.small)
            Text("Replaces the current link. The old one stops working right away.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var deleteControls: some View {
        if isConfirmingDelete {
            HStack(spacing: 8) {
                Text("Delete this video?")
                Spacer()
                Button("Delete") {
                    model.delete(video)
                }
                .foregroundStyle(.red)
                Button("Keep") {
                    isConfirmingDelete = false
                }
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        } else {
            Button("Delete video…") {
                isConfirmingDelete = true
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
        }
    }

    private var shareEnabledBinding: Binding<Bool> {
        Binding {
            video.shareEnabled
        } set: { enabled in
            model.setShareEnabled(video, enabled)
        }
    }

    private var metadata: String {
        var values = [
            Formatting.relativeDate(video.createdAt),
            Formatting.bytes(video.sizeBytes),
        ]
        if let width = video.width, let height = video.height {
            values.append("\(width)x\(height)")
        }
        return values.joined(separator: " · ")
    }

    private func statusCaption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func saveTitle() {
        guard !isSaving else { return }
        let trimmedTitle = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, trimmedTitle != video.title else {
            titleText = video.title
            return
        }

        titleText = trimmedTitle
        isSaving = true
        Task { @MainActor in
            await model.rename(video, to: trimmedTitle)
            titleText = model.videos.first(where: { $0.id == video.id })?.title ?? video.title
            lastSyncedTitle = titleText
            isSaving = false
        }
    }
}
