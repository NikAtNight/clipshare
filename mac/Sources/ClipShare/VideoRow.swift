import ClipShareCore
import SwiftUI

struct VideoRow: View {
    let model: AppModel
    let video: Video

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(video.title)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(Formatting.relativeDate(video.createdAt)) · \(Formatting.bytes(video.sizeBytes))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                model.select(video)
            }
            trailingControl
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Copy link") {
                model.confirmingDeleteVideoID = nil
                model.copyLink(video)
            }
            .disabled(video.status != .ready || video.shareUrl == nil || !video.shareEnabled)
            Button("Open in browser") {
                model.confirmingDeleteVideoID = nil
                model.openLink(video)
            }
            .disabled(video.status != .ready || video.shareUrl == nil || !video.shareEnabled)
            Button("New link…") {
                model.confirmingDeleteVideoID = nil
                model.newLink(video)
            }
            .disabled(video.status != .ready)
            Divider()
            Button("Delete…", role: .destructive) {
                model.confirmingDeleteVideoID = video.id
            }
        }
    }

    @ViewBuilder
    private var trailingControl: some View {
        if model.confirmingDeleteVideoID == video.id {
            HStack(spacing: 6) {
                Button("Delete") {
                    model.delete(video)
                }
                .foregroundStyle(.red)
                Button("Keep") {
                    model.confirmingDeleteVideoID = nil
                }
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        } else {
            switch video.status {
            case .ready:
                Button {
                    model.confirmingDeleteVideoID = nil
                    model.copyLink(video)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy link")
                .disabled(video.shareUrl == nil || !video.shareEnabled)
            case .uploading:
                badge("Uploading")
            case .failed:
                badge("Failed")
            }
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.quaternary, in: Capsule())
    }
}
