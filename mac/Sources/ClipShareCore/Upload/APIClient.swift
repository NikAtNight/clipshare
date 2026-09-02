import Foundation

public final class APIClient: @unchecked Sendable {
    let baseURL: URL
    let token: String
    let session: URLSession

    public init(baseURL: URL, token: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    public func createVideo(_ request: CreateVideoRequest) async throws -> CreateVideoResponse {
        try await send(path: "api/videos", method: "POST", body: request)
    }

    public func videoStatus(id: String) async throws -> VideoStatusResponse {
        try await send(path: "api/videos/\(id)", method: "GET")
    }

    public func complete(id: String) async throws -> CompleteResponse {
        try await send(path: "api/videos/\(id)/complete", method: "POST")
    }

    public func abort(id: String) async throws {
        try await sendEmpty(path: "api/videos/\(id)/abort", method: "POST")
    }

    public func listVideos(limit: Int? = nil, cursor: String? = nil) async throws -> ListResponse {
        var components = URLComponents(url: endpoint("api/videos"), resolvingAgainstBaseURL: false)
        var items: [URLQueryItem] = []
        if let limit { items.append(URLQueryItem(name: "limit", value: String(limit))) }
        if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        components?.queryItems = items.isEmpty ? nil : items
        guard let url = components?.url else { throw APIError.badRequest(code: "invalid_url") }
        return try await send(url: url, method: "GET")
    }

    public func updateTitle(id: String, title: String) async throws -> Video {
        struct Body: Encodable { let title: String }
        struct Response: Decodable { let video: Video }
        let response: Response = try await send(path: "api/videos/\(id)", method: "PATCH", body: Body(title: title))
        return response.video
    }

    public func revoke(id: String) async throws -> CompleteResponse {
        try await send(path: "api/videos/\(id)/revoke", method: "POST")
    }

    public func delete(id: String) async throws {
        try await sendEmpty(path: "api/videos/\(id)", method: "DELETE")
    }

    func authorizedRequest(url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    func endpoint(_ path: String) -> URL {
        baseURL.appending(path: path)
    }

    private func send<T: Decodable>(path: String, method: String) async throws -> T {
        try await send(url: endpoint(path), method: method)
    }

    private func send<T: Decodable, Body: Encodable>(path: String, method: String, body: Body) async throws -> T {
        let data: Data
        do { data = try JSONEncoder().encode(body) } catch { throw APIError.decoding(error) }
        var request = authorizedRequest(url: endpoint(path), method: method)
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await perform(request)
    }

    private func send<T: Decodable>(url: URL, method: String) async throws -> T {
        try await perform(authorizedRequest(url: url, method: method))
    }

    private func sendEmpty(path: String, method: String) async throws {
        let request = authorizedRequest(url: endpoint(path), method: method)
        _ = try await response(for: request)
    }

    private func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
        let data = try await response(for: request)
        do { return try Self.decoder.decode(T.self, from: data) }
        catch { throw APIError.decoding(error) }
    }

    private func response(for request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw APIError.network(URLError(.badServerResponse)) }
            guard (200...299).contains(http.statusCode) else { throw Self.error(status: http.statusCode, data: data) }
            return data
        } catch let error as APIError { throw error }
        catch { throw APIError.network(error) }
    }

    static func error(status: Int, data: Data) -> APIError {
        struct ErrorBody: Decodable { let error: String; let missing: [Int]? }
        let body = try? JSONDecoder().decode(ErrorBody.self, from: data)
        switch status {
        case 401: return .unauthorized
        case 404: return .notFound
        case 409: return .conflict(code: body?.error ?? "conflict", missing: body?.missing)
        case 400...499: return .badRequest(code: body?.error ?? "bad_request")
        default: return .server(status: status)
        }
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = formatter.date(from: value) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO 8601 date")
            }
            return date
        }
        return decoder
    }()
}
