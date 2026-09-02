import Foundation

struct PartUploadFailure: Error {
    let status: Int?
    let apiError: APIError
}

final class PartUploader: NSObject, URLSessionTaskDelegate, URLSessionDataDelegate, @unchecked Sendable {
    private let configuration: URLSessionConfiguration
    private let progress: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionUploadTask?
    private var responseData = Data()
    private var continuation: CheckedContinuation<PartUploadResponse, Error>?

    init(configuration: URLSessionConfiguration, progress: @escaping @Sendable (Int64) -> Void) {
        self.configuration = configuration
        self.progress = progress
    }

    func upload(request: URLRequest, fileURL: URL) async throws -> PartUploadResponse {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                responseData = Data()
                self.continuation = continuation
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                self.session = session
                let task = session.uploadTask(with: request, fromFile: fileURL)
                self.task = task
                lock.unlock()
                task.resume()
                if Task.isCancelled {
                    task.cancel()
                }
            }
        }, onCancel: { [weak self] in
            self?.cancel()
        })
    }

    func cancel() {
        lock.lock()
        let activeTask = task
        lock.unlock()
        activeTask?.cancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        progress(totalBytesSent)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        responseData.append(data)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let data = responseData
        self.task = nil
        self.session = nil
        lock.unlock()

        defer { session.invalidateAndCancel() }
        guard let continuation else { return }
        if let error {
            if (error as? URLError)?.code == .cancelled {
                continuation.resume(throwing: CancellationError())
            } else {
                continuation.resume(throwing: PartUploadFailure(status: nil, apiError: .network(error)))
            }
            return
        }
        guard let response = task.response as? HTTPURLResponse else {
            continuation.resume(throwing: PartUploadFailure(status: nil, apiError: .network(URLError(.badServerResponse))))
            return
        }
        guard (200...299).contains(response.statusCode) else {
            continuation.resume(throwing: PartUploadFailure(status: response.statusCode, apiError: APIClient.error(status: response.statusCode, data: data)))
            return
        }
        do {
            continuation.resume(returning: try APIClient.decoder.decode(PartUploadResponse.self, from: data))
        } catch {
            continuation.resume(throwing: PartUploadFailure(status: response.statusCode, apiError: .decoding(error)))
        }
    }
}
