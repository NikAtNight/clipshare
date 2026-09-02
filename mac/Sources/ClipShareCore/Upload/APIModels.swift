import Foundation

public enum VideoStatus: String, Codable, Sendable, Equatable {
    case uploading
    case ready
    case failed
}

public struct Video: Codable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let originalFilename: String
    public let sizeBytes: Int64
    public let durationSeconds: Double?
    public let width: Int?
    public let height: Int?
    public let status: VideoStatus
    public let shareEnabled: Bool
    public let shareUrl: URL?
    public let createdAt: Date
    public let readyAt: Date?

    public init(id: String, title: String, originalFilename: String, sizeBytes: Int64, durationSeconds: Double?, width: Int?, height: Int?, status: VideoStatus, shareEnabled: Bool = true, shareUrl: URL?, createdAt: Date, readyAt: Date?) {
        self.id = id
        self.title = title
        self.originalFilename = originalFilename
        self.sizeBytes = sizeBytes
        self.durationSeconds = durationSeconds
        self.width = width
        self.height = height
        self.status = status
        self.shareEnabled = shareEnabled
        self.shareUrl = shareUrl
        self.createdAt = createdAt
        self.readyAt = readyAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, originalFilename, sizeBytes, durationSeconds, width, height, status
        case shareEnabled, shareUrl, createdAt, readyAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        originalFilename = try container.decode(String.self, forKey: .originalFilename)
        sizeBytes = try container.decode(Int64.self, forKey: .sizeBytes)
        durationSeconds = try container.decodeIfPresent(Double.self, forKey: .durationSeconds)
        width = try container.decodeIfPresent(Int.self, forKey: .width)
        height = try container.decodeIfPresent(Int.self, forKey: .height)
        status = try container.decode(VideoStatus.self, forKey: .status)
        shareEnabled = try container.decodeIfPresent(Bool.self, forKey: .shareEnabled) ?? true
        shareUrl = try container.decodeIfPresent(URL.self, forKey: .shareUrl)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        readyAt = try container.decodeIfPresent(Date.self, forKey: .readyAt)
    }
}

public struct CreateVideoRequest: Codable, Sendable, Equatable {
    public let idempotencyKey: String
    public let originalFilename: String
    public let sizeBytes: Int64
    public let durationSeconds: Double?
    public let width: Int?
    public let height: Int?

    public init(idempotencyKey: UUID, originalFilename: String, sizeBytes: Int64, durationSeconds: Double?, width: Int?, height: Int?) {
        self.idempotencyKey = idempotencyKey.uuidString.lowercased()
        self.originalFilename = originalFilename
        self.sizeBytes = sizeBytes
        self.durationSeconds = durationSeconds
        self.width = width
        self.height = height
    }
}

public struct CreateVideoResponse: Codable, Sendable, Equatable {
    public let video: Video
    public let partSizeBytes: Int64
    public let partCount: Int
}

public struct VideoStatusResponse: Codable, Sendable, Equatable {
    public let video: Video
    public let partSizeBytes: Int64
    public let partCount: Int
    public let uploadedParts: [Int]
}

public struct PartUploadResponse: Codable, Sendable, Equatable {
    public let partNumber: Int
    public let etag: String
    public let sizeBytes: Int64
}

public struct CompleteResponse: Codable, Sendable, Equatable {
    public let video: Video
    public let shareUrl: URL
}

public struct ListResponse: Codable, Sendable, Equatable {
    public let videos: [Video]
    public let nextCursor: String?
}

public enum APIError: Error, LocalizedError {
    case unauthorized
    case notFound
    case conflict(code: String, missing: [Int]?)
    case badRequest(code: String)
    case server(status: Int)
    case network(Error)
    case decoding(Error)

    public var errorDescription: String? {
        switch self {
        case .unauthorized: return "The owner token was rejected."
        case .notFound: return "The video was not found."
        case let .conflict(code, _): return "The request could not be completed: \(code)."
        case let .badRequest(code): return "The request was invalid: \(code)."
        case let .server(status): return "The server returned an error (\(status))."
        case .network: return "The network request failed."
        case .decoding: return "The server returned an unexpected response."
        }
    }
}
