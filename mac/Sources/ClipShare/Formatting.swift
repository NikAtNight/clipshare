import Foundation

enum Formatting {
    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    static func speed(_ bytesPerSecond: Double) -> String {
        "\(bytes(Int64(max(0, bytesPerSecond))))/s"
    }

    static func relativeDate(_ date: Date, relativeTo now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
