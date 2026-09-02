import Foundation

struct PendingUpload: Codable, Sendable, Equatable {
    let preparedFileURL: URL
    let isTemporary: Bool
    let originalFilename: String
    let idempotencyKey: UUID
    let videoID: String?
}
