import ClipShareCore
import Foundation
import XCTest

private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [URLRequest] = []

    func append(_ request: URLRequest) { lock.lock(); values.append(request); lock.unlock() }
    func all() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return values }
    func count(method: String, path: String) -> Int { all().filter { $0.httpMethod == method && $0.url?.path == path }.count }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UploadProgress] = []
    func append(_ value: UploadProgress) { lock.lock(); values.append(value); lock.unlock() }
    func all() -> [UploadProgress] { lock.lock(); defer { lock.unlock() }; return values }
}

private final class TestURLProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var handler: ((URLRequest, Data) -> (Int, Data))?
    nonisolated(unsafe) static var recorder = RequestRecorder()
    nonisolated(unsafe) static var delayPartResponses = false
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body: Data
        if let data = request.httpBody { body = data }
        else if let stream = request.httpBodyStream {
            stream.open()
            var collected = Data()
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64 * 1024)
            defer { buffer.deallocate(); stream.close() }
            while stream.hasBytesAvailable {
                let count = stream.read(buffer, maxLength: 64 * 1024)
                if count <= 0 { break }
                collected.append(buffer, count: count)
            }
            body = collected
        } else { body = Data() }
        Self.recorder.append(request)
        Self.lock.lock()
        let result = Self.handler?(request, body) ?? (500, Data())
        Self.lock.unlock()
        let reply = { [weak self] in
            guard let self, !self.stopped, let url = self.request.url, let response = HTTPURLResponse(url: url, statusCode: result.0, httpVersion: nil, headerFields: nil) else { return }
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: result.1)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        if Self.delayPartResponses && request.httpMethod == "PUT" {
            DispatchQueue.global().asyncAfter(deadline: .now() + 1, execute: reply)
        } else { reply() }
    }
    override func stopLoading() { stopped = true }
}

final class UploadTests: XCTestCase {
    private let baseURL = URL(string: "https://example.test/") ?? URL(fileURLWithPath: "/")

    override func setUp() {
        super.setUp()
        TestURLProtocol.lock.lock()
        TestURLProtocol.recorder = RequestRecorder()
        TestURLProtocol.handler = nil
        TestURLProtocol.delayPartResponses = false
        TestURLProtocol.lock.unlock()
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TestURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func client() -> APIClient { APIClient(baseURL: baseURL, token: "test-token", session: session()) }

    private func json(_ value: Any) -> Data { (try? JSONSerialization.data(withJSONObject: value)) ?? Data() }

    private func video(id: String = "video-1", status: String = "uploading", size: Int = 12 * 1024 * 1024) -> [String: Any] {
        ["id": id, "title": "Movie", "originalFilename": "movie.mp4", "sizeBytes": size, "durationSeconds": 4.5, "width": 1920, "height": 1080, "status": status, "shareUrl": status == "ready" ? "https://example.test/v/share" : NSNull(), "createdAt": "2026-09-01T18:00:00.123Z", "readyAt": status == "ready" ? "2026-09-01T18:01:00.000Z" : NSNull()]
    }

    private func mediaInfo(size: Int64) -> MediaInfo {
        MediaInfo(container: .mp4, videoCodec: "avc1", audioCodec: "aac", durationSeconds: 4.5, width: 1920, height: 1080, sizeBytes: size, isFastStart: true, hasRotation: false)
    }

    private func temporaryFile(size: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "clipshare-test-\(UUID().uuidString)")
        let data = Data((0..<size).map { UInt8($0 % 251) })
        try data.write(to: url)
        return url
    }

    func testCreateVideoSendsJSONAndDecodesDate() async throws {
        var capturedBody = Data()
        TestURLProtocol.handler = { request, body in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            capturedBody = body
            return (201, self.json(["video": self.video(), "partSizeBytes": 5_242_880, "partCount": 3]))
        }
        let key = UUID()
        let response = try await client().createVideo(CreateVideoRequest(idempotencyKey: key, originalFilename: "movie.mp4", sizeBytes: 12, durationSeconds: 1, width: 2, height: 3))
        let request = try XCTUnwrap(TestURLProtocol.recorder.all().first)
        XCTAssertEqual(request.httpMethod, "POST")
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: capturedBody) as? [String: Any])
        XCTAssertEqual(payload["idempotencyKey"] as? String, key.uuidString.lowercased())
        XCTAssertEqual(payload["originalFilename"] as? String, "movie.mp4")
        XCTAssertEqual(response.video.createdAt.timeIntervalSince1970, 1_788_285_600.123, accuracy: 0.001)
        XCTAssertTrue(response.video.shareEnabled)
    }

    func testUpdateVideoSendsOnlyProvidedFields() async throws {
        var bodies: [Data] = []
        TestURLProtocol.handler = { _, body in
            bodies.append(body)
            return (200, self.json(["video": self.video(status: "ready")]))
        }

        _ = try await client().updateVideo(id: "video-1", title: "Renamed")
        _ = try await client().updateVideo(id: "video-1", shareEnabled: false)
        _ = try await client().updateVideo(id: "video-1", title: "Another name", shareEnabled: true)

        let payloads = try bodies.map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: $0) as? [String: Any])
        }
        XCTAssertEqual(Set(payloads[0].keys), ["title"])
        XCTAssertEqual(payloads[0]["title"] as? String, "Renamed")
        XCTAssertEqual(Set(payloads[1].keys), ["shareEnabled"])
        XCTAssertEqual(payloads[1]["shareEnabled"] as? Bool, false)
        XCTAssertEqual(Set(payloads[2].keys), ["title", "shareEnabled"])
        XCTAssertEqual(payloads[2]["title"] as? String, "Another name")
        XCTAssertEqual(payloads[2]["shareEnabled"] as? Bool, true)
    }

    func testListVideosSendsPercentEncodedQuery() async throws {
        TestURLProtocol.handler = { _, _ in
            (200, self.json(["videos": [], "nextCursor": NSNull()]))
        }

        _ = try await client().listVideos(limit: 30, cursor: "next page", query: "title & café")

        let request = try XCTUnwrap(TestURLProtocol.recorder.all().first)
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "q" })?.value, "title & café")
        XCTAssertEqual(components.percentEncodedQuery, "limit=30&cursor=next%20page&q=title%20%26%20caf%C3%A9")
    }

    func testAPIClientMapsErrors() async throws {
        let cases: [(Int, Data, (APIError) -> Bool)] = [
            (401, json(["error": "unauthorized"]), { if case .unauthorized = $0 { return true }; return false }),
            (404, json(["error": "not_found"]), { if case .notFound = $0 { return true }; return false }),
            (409, json(["error": "parts_missing", "missing": [2]]), { if case let .conflict(code, missing) = $0 { return code == "parts_missing" && missing == [2] }; return false })
        ]
        for (status, body, matches) in cases {
            TestURLProtocol.handler = { _, _ in (status, body) }
            do { _ = try await client().videoStatus(id: "video-1"); XCTFail("Expected an error") }
            catch let error as APIError { XCTAssertTrue(matches(error)) }
        }
    }

    func testUploadSendsPartsAndCompletes() async throws {
        let size = 12 * 1024 * 1024
        let file = try temporaryFile(size: size)
        defer { try? FileManager.default.removeItem(at: file) }
        var partBodies: [Int: Data] = [:]
        TestURLProtocol.handler = { request, body in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/videos"):
                return (201, self.json(["video": self.video(), "partSizeBytes": 5_242_880, "partCount": 3]))
            case ("GET", "/api/videos/video-1"):
                return (200, self.json(["video": self.video(), "partSizeBytes": 5_242_880, "partCount": 3, "uploadedParts": []]))
            case ("PUT", let path?):
                let number = Int(path.split(separator: "/").last ?? "0") ?? 0
                partBodies[number] = body
                return (200, self.json(["partNumber": number, "etag": "etag", "sizeBytes": body.count]))
            case ("POST", "/api/videos/video-1/complete"):
                return (200, self.json(["video": self.video(status: "ready"), "shareUrl": "https://example.test/v/share"]))
            default: return (500, Data())
            }
        }
        let progress = ProgressRecorder()
        let result = try await UploadManager(client: client(), baseURL: baseURL).upload(fileURL: file, originalFilename: "movie.mp4", info: mediaInfo(size: Int64(size)), idempotencyKey: UUID()) { value in progress.append(value) }
        XCTAssertEqual(result.status, .ready)
        XCTAssertEqual(partBodies.keys.sorted(), [1, 2, 3])
        XCTAssertEqual(partBodies[1]?.count, 5_242_880)
        XCTAssertEqual(partBodies[2]?.count, 5_242_880)
        XCTAssertEqual(partBodies[3]?.count, 2_097_152)
        let source = try Data(contentsOf: file)
        XCTAssertEqual(partBodies[3], source.suffix(2_097_152))
        let requests = TestURLProtocol.recorder.all().filter { $0.httpMethod == "PUT" }
        XCTAssertEqual(requests.sorted { $0.url!.path < $1.url!.path }.map { $0.value(forHTTPHeaderField: "Content-Length") }, ["5242880", "5242880", "2097152"])
        XCTAssertEqual(TestURLProtocol.recorder.count(method: "POST", path: "/api/videos/video-1/complete"), 1)
        let values = progress.all()
        XCTAssertEqual(values.last?.bytesSent, Int64(size))
        XCTAssertTrue(zip(values, values.dropFirst()).allSatisfy { $0.bytesSent <= $1.bytesSent })
    }

    func testRetryAndUnauthorizedPartFailure() async throws {
        let file = try temporaryFile(size: 10)
        defer { try? FileManager.default.removeItem(at: file) }
        var attempts = 0
        TestURLProtocol.handler = { request, body in
            if request.httpMethod == "POST" && request.url?.path == "/api/videos" { return (201, self.json(["video": self.video(size: 10), "partSizeBytes": 100, "partCount": 1])) }
            if request.httpMethod == "GET" && request.url?.path == "/api/videos/video-1" { return (200, self.json(["video": self.video(size: 10), "partSizeBytes": 100, "partCount": 1, "uploadedParts": []])) }
            if request.httpMethod == "PUT" { attempts += 1; return attempts < 3 ? (503, Data()) : (200, self.json(["partNumber": 1, "etag": "etag", "sizeBytes": body.count])) }
            if request.url?.path.hasSuffix("complete") == true { return (200, self.json(["video": self.video(status: "ready"), "shareUrl": "https://example.test/v/share"])) }
            return (500, Data())
        }
        _ = try await UploadManager(client: client(), baseURL: baseURL).upload(fileURL: file, originalFilename: "movie.mp4", info: mediaInfo(size: 10), idempotencyKey: UUID()) { _ in }
        XCTAssertEqual(attempts, 3)

        TestURLProtocol.handler = { request, _ in
            if request.httpMethod == "POST" && request.url?.path == "/api/videos" { return (201, self.json(["video": self.video(size: 10), "partSizeBytes": 100, "partCount": 1])) }
            if request.httpMethod == "GET" && request.url?.path == "/api/videos/video-1" { return (200, self.json(["video": self.video(size: 10), "partSizeBytes": 100, "partCount": 1, "uploadedParts": []])) }
            if request.httpMethod == "PUT" { return (401, self.json(["error": "unauthorized"])) }
            return (500, Data())
        }
        do { _ = try await UploadManager(client: client(), baseURL: baseURL).upload(fileURL: file, originalFilename: "movie.mp4", info: mediaInfo(size: 10), idempotencyKey: UUID()) { _ in }; XCTFail("Expected unauthorized") }
        catch let error as APIError { if case .unauthorized = error {} else { XCTFail("Wrong error") } }
        XCTAssertEqual(TestURLProtocol.recorder.count(method: "POST", path: "/api/videos/video-1/complete"), 1)
    }

    func testResumeUploadsOnlyMissingPart() async throws {
        let file = try temporaryFile(size: 12)
        defer { try? FileManager.default.removeItem(at: file) }
        var parts: [Int] = []
        TestURLProtocol.handler = { request, body in
            if request.httpMethod == "GET" { return (200, self.json(["video": self.video(), "partSizeBytes": 5, "partCount": 3, "uploadedParts": [1, 3]])) }
            if request.httpMethod == "PUT" {
                let number = request.url.flatMap { Int($0.path.split(separator: "/").last ?? "") } ?? 0
                parts.append(number)
                return (200, self.json(["partNumber": number, "etag": "etag", "sizeBytes": body.count]))
            }
            if request.url?.path.hasSuffix("complete") == true { return (200, self.json(["video": self.video(status: "ready"), "shareUrl": "https://example.test/v/share"])) }
            return (500, Data())
        }
        _ = try await UploadManager(client: client(), baseURL: baseURL).resume(videoID: "video-1", fileURL: file) { _ in }
        XCTAssertEqual(parts, [2])
    }

    func testTokenStoreRoundTrip() throws {
        do {
            try TokenStore.delete()
            try TokenStore.save("first")
            XCTAssertEqual(try TokenStore.load(), "first")
            try TokenStore.save("second")
            XCTAssertEqual(try TokenStore.load(), "second")
            try TokenStore.delete()
            XCTAssertNil(try TokenStore.load())
        } catch {
            throw XCTSkip("Keychain is unavailable in this test host: \(error.localizedDescription)")
        }
    }

    func testCancellationAbortsAndCleansPartFiles() async throws {
        let file = try temporaryFile(size: 10)
        defer { try? FileManager.default.removeItem(at: file) }
        TestURLProtocol.delayPartResponses = true
        TestURLProtocol.handler = { request, body in
            if request.httpMethod == "POST" && request.url?.path == "/api/videos" { return (201, self.json(["video": self.video(size: 10), "partSizeBytes": 100, "partCount": 1])) }
            if request.httpMethod == "GET" && request.url?.path == "/api/videos/video-1" { return (200, self.json(["video": self.video(size: 10), "partSizeBytes": 100, "partCount": 1, "uploadedParts": []])) }
            if request.httpMethod == "PUT" { return (200, self.json(["partNumber": 1, "etag": "etag", "sizeBytes": body.count])) }
            if request.url?.path.hasSuffix("abort") == true { return (204, Data()) }
            return (500, Data())
        }
        let manager = UploadManager(client: client(), baseURL: baseURL)
        let task = Task { try await manager.upload(fileURL: file, originalFilename: "movie.mp4", info: self.mediaInfo(size: 10), idempotencyKey: UUID()) { _ in } }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError {}
        XCTAssertEqual(TestURLProtocol.recorder.count(method: "POST", path: "/api/videos/video-1/abort"), 1)
        let parts = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "ClipShare/parts", directoryHint: .isDirectory)
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: parts.path).count) ?? 0, 0)
    }

    func testUploadReturnsReadyIdempotentVideoWithoutPartsOrCompletion() async throws {
        let file = try temporaryFile(size: 10)
        defer { try? FileManager.default.removeItem(at: file) }
        TestURLProtocol.handler = { request, _ in
            if request.httpMethod == "POST" && request.url?.path == "/api/videos" {
                return (200, self.json(["video": self.video(status: "ready", size: 10), "partSizeBytes": 100, "partCount": 1]))
            }
            if request.httpMethod == "GET" && request.url?.path == "/api/videos/video-1" {
                return (200, self.json(["video": self.video(status: "ready", size: 10), "partSizeBytes": 100, "partCount": 1, "uploadedParts": []]))
            }
            return (500, Data())
        }
        let video = try await UploadManager(client: client(), baseURL: baseURL).upload(fileURL: file, originalFilename: "movie.mp4", info: mediaInfo(size: 10), idempotencyKey: UUID()) { _ in }
        XCTAssertEqual(video.status, .ready)
        XCTAssertEqual(TestURLProtocol.recorder.count(method: "PUT", path: "/api/videos/video-1/parts/1"), 0)
        XCTAssertEqual(TestURLProtocol.recorder.count(method: "POST", path: "/api/videos/video-1/complete"), 0)
    }
}
