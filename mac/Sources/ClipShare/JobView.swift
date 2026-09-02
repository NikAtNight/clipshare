import ClipShareCore
import SwiftUI

struct JobView: View {
    let model: AppModel
    let job: AppModel.Job
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(job.filename)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if isRunning {
                    Button {
                        model.cancel()
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.plain)
                    .help("Cancel upload")
                }
            }

            switch job.stage {
            case let .preparing(progress):
                ProgressView(value: progress)
                Text("Preparing… \(Int((progress * 100).rounded()))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)

            case let .uploading(progress):
                ProgressView(value: uploadFraction(progress))
                Text("\(Formatting.bytes(progress.bytesSent)) of \(Formatting.bytes(progress.totalBytes)) · \(Formatting.speed(progress.bytesPerSecond))")
                    .font(.caption)
                    .foregroundStyle(.secondary)

            case let .done(video):
                ProgressView(value: 1)
                HStack {
                    Label("Link copied", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Copy again") {
                        model.copyLink(video)
                    }
                    .controlSize(.small)
                }

            case let .failed(message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Dismiss") {
                        model.dismissFailedJob()
                    }
                    Button("Retry") {
                        model.retry()
                    }
                    .keyboardShortcut(.defaultAction)
                }
                .controlSize(.small)
            }
        }
        .padding(compact ? 0 : 12)
        .background {
            if !compact {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.quaternary)
            }
        }
    }

    private var isRunning: Bool {
        switch job.stage {
        case .preparing, .uploading:
            return true
        case .done, .failed:
            return false
        }
    }

    private func uploadFraction(_ progress: UploadProgress) -> Double {
        guard progress.totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(progress.bytesSent) / Double(progress.totalBytes)))
    }
}
