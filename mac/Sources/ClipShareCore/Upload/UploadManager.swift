import Foundation

public struct UploadProgress: Sendable, Equatable {
    public var bytesSent: Int64
    public var totalBytes: Int64
    public var bytesPerSecond: Double

    public init(bytesSent: Int64, totalBytes: Int64, bytesPerSecond: Double) {
        self.bytesSent = bytesSent
        self.totalBytes = totalBytes
        self.bytesPerSecond = bytesPerSecond
    }
}

private actor ProgressTracker {
    private let total: Int64
    private let callback: @Sendable (UploadProgress) -> Void
    private var completed: Int64 = 0
    private var inFlight: [Int: Int64] = [:]
    private var samples: [(Date, Int64)] = []
    private var lastEmission = Date.distantPast

    init(total: Int64, callback: @escaping @Sendable (UploadProgress) -> Void) {
        self.total = total
        self.callback = callback
    }

    func start(part: Int) { inFlight[part] = 0 }

    func update(part: Int, sent: Int64) {
        inFlight[part] = sent
        emitIfNeeded()
    }

    func finish(part: Int, size: Int64) {
        inFlight.removeValue(forKey: part)
        completed += size
        emit(force: false)
    }

    func emitFinal() { emit(force: true) }

    private func emitIfNeeded() {
        if Date().timeIntervalSince(lastEmission) >= 0.1 { emit(force: false) }
    }

    private func emit(force: Bool) {
        let now = Date()
        guard force || now.timeIntervalSince(lastEmission) >= 0.1 else { return }
        let sent = min(total, completed + inFlight.values.reduce(0, +))
        samples.append((now, sent))
        samples = samples.filter { now.timeIntervalSince($0.0) <= 3 }
        let rate: Double
        if let first = samples.first, now.timeIntervalSince(first.0) > 0 {
            rate = Double(sent - first.1) / now.timeIntervalSince(first.0)
        } else {
            rate = 0
        }
        lastEmission = now
        callback(UploadProgress(bytesSent: sent, totalBytes: total, bytesPerSecond: max(0, rate)))
    }
}

public actor UploadManager {
    private let client: APIClient
    private let baseURL: URL
    private let maxConcurrentParts: Int
    private var activeUploaders: [PartUploader] = []

    public init(client: APIClient, baseURL: URL, maxConcurrentParts: Int = 3) {
        self.client = client
        self.baseURL = baseURL
        self.maxConcurrentParts = max(1, maxConcurrentParts)
    }

    public func upload(fileURL: URL, originalFilename: String, info: MediaInfo, idempotencyKey: UUID, onVideoCreated: (@Sendable (String) -> Void)? = nil, progress: @Sendable @escaping (UploadProgress) -> Void) async throws -> Video {
        let created = try await client.createVideo(CreateVideoRequest(idempotencyKey: idempotencyKey, originalFilename: originalFilename, sizeBytes: info.sizeBytes, durationSeconds: info.durationSeconds, width: info.width, height: info.height))
        onVideoCreated?(created.video.id)
        return try await resume(videoID: created.video.id, fileURL: fileURL, progress: progress)
    }

    public func resume(videoID: String, fileURL: URL, progress: @Sendable @escaping (UploadProgress) -> Void) async throws -> Video {
        let status = try await client.videoStatus(id: videoID)
        return try await run(video: status.video, partSize: status.partSizeBytes, partCount: status.partCount, uploadedParts: status.uploadedParts, fileURL: fileURL, progress: progress)
    }

    private func run(video: Video, partSize: Int64, partCount: Int, uploadedParts: [Int], fileURL: URL, progress: @escaping @Sendable (UploadProgress) -> Void) async throws -> Video {
        if video.status == .ready {
            return video
        }
        let directory = try partDirectory()
        let tracker = ProgressTracker(total: video.sizeBytes, callback: progress)
        let uploaded = Set(uploadedParts)
        for number in uploaded {
            await tracker.finish(part: number, size: size(of: number, partSize: partSize, total: video.sizeBytes))
        }
        do {
            try await uploadParts(Array(1...partCount).filter { !uploaded.contains($0) }, videoID: video.id, fileURL: fileURL, partSize: partSize, total: video.sizeBytes, directory: directory, tracker: tracker)
            let complete = try await completeRetryingMissing(videoID: video.id, fileURL: fileURL, partSize: partSize, total: video.sizeBytes, directory: directory, tracker: tracker)
            await tracker.emitFinal()
            try? FileManager.default.removeItem(at: directory)
            return complete.video
        } catch is CancellationError {
            cancelActiveUploaders()
            try? FileManager.default.removeItem(at: directory)
            let client = client
            let videoID = video.id
            let abortTask = Task.detached { try? await client.abort(id: videoID) }
            _ = await abortTask.result
            throw CancellationError()
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func completeRetryingMissing(videoID: String, fileURL: URL, partSize: Int64, total: Int64, directory: URL, tracker: ProgressTracker) async throws -> CompleteResponse {
        do {
            return try await client.complete(id: videoID)
        } catch let APIError.conflict(code, missing) where code == "parts_missing" {
            guard let missing else { throw APIError.conflict(code: code, missing: missing) }
            try await uploadParts(missing, videoID: videoID, fileURL: fileURL, partSize: partSize, total: total, directory: directory, tracker: tracker)
            return try await client.complete(id: videoID)
        }
    }

    private func uploadParts(_ parts: [Int], videoID: String, fileURL: URL, partSize: Int64, total: Int64, directory: URL, tracker: ProgressTracker) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            var iterator = parts.makeIterator()
            for _ in 0..<min(maxConcurrentParts, parts.count) {
                if let part = iterator.next() { addPartTask(&group, part: part, videoID: videoID, fileURL: fileURL, partSize: partSize, total: total, directory: directory, tracker: tracker) }
            }
            while try await group.next() != nil {
                try Task.checkCancellation()
                if let part = iterator.next() { addPartTask(&group, part: part, videoID: videoID, fileURL: fileURL, partSize: partSize, total: total, directory: directory, tracker: tracker) }
            }
        }
    }

    private func addPartTask(_ group: inout ThrowingTaskGroup<Void, Error>, part: Int, videoID: String, fileURL: URL, partSize: Int64, total: Int64, directory: URL, tracker: ProgressTracker) {
        group.addTask { [weak self] in
            guard let self else { throw CancellationError() }
            try await self.uploadPart(number: part, videoID: videoID, sourceURL: fileURL, partSize: partSize, total: total, directory: directory, tracker: tracker)
        }
    }

    private func uploadPart(number: Int, videoID: String, sourceURL: URL, partSize: Int64, total: Int64, directory: URL, tracker: ProgressTracker) async throws {
        let length = size(of: number, partSize: partSize, total: total)
        let partURL = directory.appending(path: "\(number)-\(UUID().uuidString)", directoryHint: .notDirectory)
        try writePart(from: sourceURL, offset: Int64(number - 1) * partSize, length: length, to: partURL)
        defer { try? FileManager.default.removeItem(at: partURL) }
        await tracker.start(part: number)
        var lastError: Error?
        for attempt in 0..<4 {
            try Task.checkCancellation()
            let uploader = PartUploader(configuration: client.session.configuration) { sent in
                Task { await tracker.update(part: number, sent: sent) }
            }
            activeUploaders.append(uploader)
            defer { activeUploaders.removeAll { $0 === uploader } }
            var request = client.authorizedRequest(url: baseURL.appending(path: "api/videos/\(videoID)/parts/\(number)"), method: "PUT")
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            do {
                _ = try await uploader.upload(request: request, fileURL: partURL)
                await tracker.finish(part: number, size: length)
                return
            } catch is CancellationError { throw CancellationError() }
            catch let failure as PartUploadFailure {
                lastError = failure.apiError
                guard attempt < 3, failure.status == nil || failure.status == 408 || failure.status == 429 || (failure.status ?? 0) >= 500 else { throw failure.apiError }
            } catch {
                lastError = error
                guard attempt < 3 else { throw error }
            }
            try await Task.sleep(for: .seconds(1 << attempt))
        }
        throw lastError ?? APIError.network(URLError(.unknown))
    }

    private func partDirectory() throws -> URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "ClipShare/parts", directoryHint: .isDirectory)
        let directory = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writePart(from sourceURL: URL, offset: Int64, length: Int64, to destinationURL: URL) throws {
        let source = try FileHandle(forReadingFrom: sourceURL)
        defer { try? source.close() }
        FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
        let destination = try FileHandle(forWritingTo: destinationURL)
        defer { try? destination.close() }
        try source.seek(toOffset: UInt64(offset))
        var remaining = length
        while remaining > 0 {
            let data = try source.read(upToCount: Int(min(1_048_576, remaining))) ?? Data()
            guard !data.isEmpty else { throw APIError.badRequest(code: "file_changed") }
            try destination.write(contentsOf: data)
            remaining -= Int64(data.count)
        }
    }

    private func size(of number: Int, partSize: Int64, total: Int64) -> Int64 {
        min(partSize, total - Int64(number - 1) * partSize)
    }

    private func cancelActiveUploaders() {
        activeUploaders.forEach { $0.cancel() }
        activeUploaders.removeAll()
    }
}
