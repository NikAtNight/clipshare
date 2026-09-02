import AppKit
import ClipShareCore
import Foundation
import Observation
import UniformTypeIdentifiers

struct AppConfiguration: Sendable {
    let baseURL: URL
    let token: String
}

protocol AppServices: Sendable {
    func loadConfiguration() async throws -> AppConfiguration?
    func saveConfiguration(_ configuration: AppConfiguration) async throws
    func deleteConfiguration() async throws
    func validate(_ configuration: AppConfiguration) async throws
    func listVideos(_ configuration: AppConfiguration, limit: Int, cursor: String?, query: String?) async throws -> ListResponse
    func prepare(_ url: URL, progress: @Sendable @escaping (Double) -> Void) async throws -> PreparedMedia
    func upload(
        _ prepared: PreparedMedia,
        originalFilename: String,
        idempotencyKey: UUID,
        configuration: AppConfiguration,
        onVideoCreated: (@Sendable (String) -> Void)?,
        progress: @Sendable @escaping (UploadProgress) -> Void
    ) async throws -> Video
    func resume(videoID: String, fileURL: URL, configuration: AppConfiguration, progress: @Sendable @escaping (UploadProgress) -> Void) async throws -> Video
    func updateVideo(_ video: Video, title: String?, shareEnabled: Bool?, configuration: AppConfiguration) async throws -> Video
    func revoke(_ video: Video, configuration: AppConfiguration) async throws -> Video
    func delete(_ video: Video, configuration: AppConfiguration) async throws
    func cleanup(_ prepared: PreparedMedia) async
    func loadPendingUpload() async -> PendingUpload?
    func savePendingUpload(_ pending: PendingUpload) async throws
    func clearPendingUpload() async
    func discardPendingUpload(_ pending: PendingUpload) async
}

actor LiveAppServices: AppServices {
    private let pendingKey = "pendingUpload"

    func loadConfiguration() throws -> AppConfiguration? {
        guard let token = try TokenStore.load(), !token.isEmpty else {
            return nil
        }
        return AppConfiguration(baseURL: ServerConfig().baseURL, token: token)
    }

    func saveConfiguration(_ configuration: AppConfiguration) throws {
        try TokenStore.save(configuration.token)
        var serverConfig = ServerConfig()
        serverConfig.baseURL = configuration.baseURL
    }

    func deleteConfiguration() throws {
        try TokenStore.delete()
    }

    func validate(_ configuration: AppConfiguration) async throws {
        let client = APIClient(baseURL: configuration.baseURL, token: configuration.token)
        _ = try await client.listVideos(limit: 1)
    }

    func listVideos(_ configuration: AppConfiguration, limit: Int, cursor: String?, query: String?) async throws -> ListResponse {
        let client = APIClient(baseURL: configuration.baseURL, token: configuration.token)
        return try await client.listVideos(limit: limit, cursor: cursor, query: query)
    }

    func prepare(_ url: URL, progress: @Sendable @escaping (Double) -> Void) async throws -> PreparedMedia {
        try await MediaPipeline.prepare(url, progress: progress)
    }

    func upload(
        _ prepared: PreparedMedia,
        originalFilename: String,
        idempotencyKey: UUID,
        configuration: AppConfiguration,
        onVideoCreated: (@Sendable (String) -> Void)?,
        progress: @Sendable @escaping (UploadProgress) -> Void
    ) async throws -> Video {
        let client = APIClient(baseURL: configuration.baseURL, token: configuration.token)
        let manager = UploadManager(client: client, baseURL: configuration.baseURL)
        return try await manager.upload(
            fileURL: prepared.fileURL,
            originalFilename: originalFilename,
            info: prepared.info,
            idempotencyKey: idempotencyKey,
            onVideoCreated: onVideoCreated,
            progress: progress
        )
    }

    func resume(videoID: String, fileURL: URL, configuration: AppConfiguration, progress: @Sendable @escaping (UploadProgress) -> Void) async throws -> Video {
        let client = APIClient(baseURL: configuration.baseURL, token: configuration.token)
        return try await UploadManager(client: client, baseURL: configuration.baseURL).resume(videoID: videoID, fileURL: fileURL, progress: progress)
    }

    func updateVideo(_ video: Video, title: String?, shareEnabled: Bool?, configuration: AppConfiguration) async throws -> Video {
        let client = APIClient(baseURL: configuration.baseURL, token: configuration.token)
        return try await client.updateVideo(id: video.id, title: title, shareEnabled: shareEnabled)
    }

    func revoke(_ video: Video, configuration: AppConfiguration) async throws -> Video {
        let client = APIClient(baseURL: configuration.baseURL, token: configuration.token)
        return try await client.revoke(id: video.id).video
    }

    func delete(_ video: Video, configuration: AppConfiguration) async throws {
        let client = APIClient(baseURL: configuration.baseURL, token: configuration.token)
        try await client.delete(id: video.id)
    }

    func cleanup(_ prepared: PreparedMedia) {
        try? prepared.cleanup()
    }

    func loadPendingUpload() -> PendingUpload? {
        guard let data = UserDefaults.standard.data(forKey: pendingKey) else {
            return nil
        }
        return try? JSONDecoder().decode(PendingUpload.self, from: data)
    }

    func savePendingUpload(_ pending: PendingUpload) throws {
        UserDefaults.standard.set(try JSONEncoder().encode(pending), forKey: pendingKey)
    }

    func clearPendingUpload() {
        UserDefaults.standard.removeObject(forKey: pendingKey)
    }

    func discardPendingUpload(_ pending: PendingUpload) {
        if pending.isTemporary {
            try? FileManager.default.removeItem(at: pending.preparedFileURL)
        }
        clearPendingUpload()
    }
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    struct SetupState {
        var serverURLText = "https://clips.talix.app"
        var tokenText = ""
        var isSaving = false
        var errorMessage: String?
        var isConfigured = false
    }

    struct Job {
        let id: UUID
        let filename: String
        var stage: Stage
        var task: Task<Void, Never>?
    }

    enum Stage {
        case preparing(Double)
        case uploading(UploadProgress)
        case done(Video)
        case failed(String)
    }

    var setup = SetupState()
    var job: Job?
    var videos: [Video] = []
    var searchText = ""
    var nextCursor: String?
    var isRefreshing = false
    var isLoadingMore = false
    var listError: String?
    var pendingUpload: PendingUpload?
    var toast: String?
    var hasLoadedConfiguration = false
    var isShowingSettings = false
    var isPositioningPanel = false
    var confirmingDeleteVideoID: String?
    var selectedVideoID: String?
    var dropPanelCorner: DropPanelCorner = DropPanelCorner.stored {
        didSet { dropPanelCorner.store() }
    }

    @ObservationIgnored private let services: any AppServices
    @ObservationIgnored private var configuration: AppConfiguration?
    @ObservationIgnored private var preparedMedia: PreparedMedia?
    @ObservationIgnored private var sourceFileURL: URL?
    @ObservationIgnored private var idempotencyKey: UUID?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var listRequestGeneration = 0
    @ObservationIgnored private var listedSearchText = ""
    @ObservationIgnored private var revokingVideoIDs: Set<String> = []

    init(services: any AppServices = LiveAppServices()) {
        self.services = services
        Task { [weak self] in
            await self?.loadInitialState()
        }
    }

    var isJobRunning: Bool {
        guard let job else { return false }
        switch job.stage {
        case .preparing, .uploading:
            return true
        case .done, .failed:
            return false
        }
    }

    func saveSetup() {
        let serverText = setup.serverURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = setup.tokenText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let baseURL = Self.validServerURL(serverText) else {
            setup.errorMessage = Self.isNonLocalHTTP(serverText) ? "Use https for anything other than a local server." : "Enter a valid HTTP or HTTPS server address."
            return
        }
        guard !token.isEmpty else {
            setup.errorMessage = "Paste your owner token."
            return
        }

        setup.isSaving = true
        setup.errorMessage = nil
        let candidate = AppConfiguration(baseURL: baseURL, token: token)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await services.validate(candidate)
                try await services.saveConfiguration(candidate)
                configuration = candidate
                setup.serverURLText = baseURL.absoluteString
                setup.tokenText = ""
                setup.isConfigured = true
                setup.isSaving = false
                isShowingSettings = false
                refresh()
            } catch {
                setup.isSaving = false
                setup.errorMessage = setupErrorMessage(for: error)
            }
        }
    }

    func handleDrop(urls: [URL]) {
        guard let first = urls.first else { return }
        guard !isJobRunning else {
            showToast("Wait for the current upload to finish.")
            return
        }
        start(fileURL: first)
    }

    func chooseFile() {
        guard !isJobRunning else {
            showToast("Wait for the current upload to finish.")
            return
        }
        // An accessory app has no key window, so without activating first the
        // panel can open behind whatever app the user was in.
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        start(fileURL: url)
    }

    func start(fileURL: URL) {
        guard !isJobRunning else {
            showToast("Wait for the current upload to finish.")
            return
        }
        clearFinishedJob()
        let jobID = UUID()
        let filename = fileURL.lastPathComponent
        let key = UUID()
        sourceFileURL = fileURL
        idempotencyKey = key
        job = Job(id: jobID, filename: filename, stage: .preparing(0), task: nil)
        let task = Task { [weak self] in
            guard let self else { return }
            await self.prepareAndUpload(fileURL: fileURL, filename: filename, jobID: jobID, idempotencyKey: key)
        }
        job?.task = task
    }

    func retry() {
        guard let failedJob = job, case .failed = failedJob.stage else { return }
        let jobID = failedJob.id
        if let preparedMedia {
            let key = idempotencyKey ?? UUID()
            idempotencyKey = key
            job?.stage = .uploading(UploadProgress(bytesSent: 0, totalBytes: preparedMedia.info.sizeBytes, bytesPerSecond: 0))
            let task = Task { [weak self] in
                guard let self else { return }
                if let videoID = pendingUpload?.videoID {
                    await self.resumeUpload(videoID: videoID, prepared: preparedMedia, filename: failedJob.filename, jobID: jobID)
                } else {
                    await self.uploadPrepared(preparedMedia, filename: failedJob.filename, jobID: jobID, idempotencyKey: key)
                }
            }
            job?.task = task
        } else if let sourceFileURL {
            start(fileURL: sourceFileURL)
        }
    }

    func cancel() {
        job?.task?.cancel()
    }

    func dismissFailedJob() {
        guard let current = job, case .failed = current.stage else { return }
        let media = preparedMedia
        clearFinishedJob()
        Task { [services] in
            if let media {
                await services.cleanup(media)
            }
            await services.clearPendingUpload()
        }
    }

    func refresh() {
        confirmingDeleteVideoID = nil
        guard let configuration else { return }
        listRequestGeneration += 1
        let generation = listRequestGeneration
        let query = searchText
        isRefreshing = true
        isLoadingMore = false
        listError = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await services.listVideos(
                    configuration,
                    limit: 30,
                    cursor: nil,
                    query: query
                )
                guard generation == listRequestGeneration, query == searchText else { return }
                videos = response.videos
                nextCursor = response.nextCursor
                listedSearchText = query
                if let selectedVideoID, !videos.contains(where: { $0.id == selectedVideoID }) {
                    deselect()
                }
                isRefreshing = false
            } catch APIError.unauthorized {
                guard generation == listRequestGeneration else { return }
                isRefreshing = false
                returnToSetup(message: "Your saved token was rejected. Connect again.")
            } catch {
                guard generation == listRequestGeneration, query == searchText else { return }
                isRefreshing = false
                listError = errorMessage(for: error)
            }
        }
    }

    func loadMore() {
        guard let configuration,
              let cursor = nextCursor,
              !isRefreshing,
              !isLoadingMore,
              listedSearchText == searchText
        else { return }
        let generation = listRequestGeneration
        let query = searchText
        isLoadingMore = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await services.listVideos(
                    configuration,
                    limit: 30,
                    cursor: cursor,
                    query: query
                )
                guard generation == listRequestGeneration, query == searchText else {
                    if generation == listRequestGeneration {
                        isLoadingMore = false
                    }
                    return
                }
                videos.append(contentsOf: response.videos)
                nextCursor = response.nextCursor
                isLoadingMore = false
            } catch APIError.unauthorized {
                guard generation == listRequestGeneration else { return }
                isLoadingMore = false
                returnToSetup(message: "Your saved token was rejected. Connect again.")
            } catch {
                guard generation == listRequestGeneration, query == searchText else { return }
                isLoadingMore = false
                listError = errorMessage(for: error)
            }
        }
    }

    func searchTextChanged() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    func copyLink(_ video: Video) {
        guard let url = video.shareUrl else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.absoluteString, forType: .string)
        showToast("Link copied")
    }

    func openLink(_ video: Video) {
        guard let url = video.shareUrl else { return }
        NSWorkspace.shared.open(url)
    }

    func select(_ video: Video) {
        confirmingDeleteVideoID = nil
        selectedVideoID = video.id
    }

    func deselect() {
        selectedVideoID = nil
    }

    func rename(_ video: Video, to title: String) async {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, trimmedTitle != video.title, let configuration else { return }
        do {
            let replacement = try await services.updateVideo(
                video,
                title: trimmedTitle,
                shareEnabled: nil,
                configuration: configuration
            )
            mergeVideoUpdate(replacement, titleChanged: true, shareEnabledChanged: false)
            showToast("Title saved")
        } catch APIError.unauthorized {
            returnToSetup(message: "Your saved token was rejected. Connect again.")
        } catch {
            showToast(errorMessage(for: error))
        }
    }

    func setShareEnabled(_ video: Video, _ enabled: Bool) {
        guard enabled != video.shareEnabled, let configuration else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let replacement = try await services.updateVideo(
                    video,
                    title: nil,
                    shareEnabled: enabled,
                    configuration: configuration
                )
                mergeVideoUpdate(replacement, titleChanged: false, shareEnabledChanged: true)
                showToast(enabled ? "Link on" : "Link off")
            } catch APIError.unauthorized {
                returnToSetup(message: "Your saved token was rejected. Connect again.")
            } catch {
                showToast(errorMessage(for: error))
            }
        }
    }

    func newLink(_ video: Video) {
        guard let configuration, revokingVideoIDs.insert(video.id).inserted else { return }
        Task { [weak self] in
            guard let self else { return }
            defer { revokingVideoIDs.remove(video.id) }
            do {
                let replacement = try await services.revoke(video, configuration: configuration)
                mergeVideoUpdate(
                    replacement,
                    titleChanged: false,
                    shareEnabledChanged: false,
                    shareURLChanged: true
                )
                copyLink(replacement)
                showToast("New link copied")
            } catch APIError.unauthorized {
                returnToSetup(message: "Your saved token was rejected. Connect again.")
            } catch {
                showToast(errorMessage(for: error))
            }
        }
    }

    func delete(_ video: Video) {
        confirmingDeleteVideoID = nil
        guard let configuration else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await services.delete(video, configuration: configuration)
                videos.removeAll { $0.id == video.id }
                if selectedVideoID == video.id {
                    deselect()
                }
            } catch APIError.unauthorized {
                returnToSetup(message: "Your saved token was rejected. Connect again.")
            } catch {
                showToast(errorMessage(for: error))
            }
        }
    }

    func discardPending() {
        guard let pendingUpload else { return }
        self.pendingUpload = nil
        Task { [services] in
            await services.discardPendingUpload(pendingUpload)
        }
    }

    func resumePending() {
        guard !isJobRunning, let pending = pendingUpload, let videoID = pending.videoID else { return }
        guard FileManager.default.fileExists(atPath: pending.preparedFileURL.path) else {
            pendingUpload = nil
            Task { [services] in await services.clearPendingUpload() }
            showToast("The prepared file is gone, so that upload can't resume.")
            return
        }
        guard let configuration else {
            showToast("Connect ClipShare before uploading.")
            return
        }
        let size = (try? pending.preparedFileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let prepared = PreparedMedia(
            fileURL: pending.preparedFileURL,
            info: MediaInfo(container: .mp4, videoCodec: nil, audioCodec: nil, durationSeconds: nil, width: nil, height: nil, sizeBytes: size, isFastStart: true, hasRotation: false),
            plan: .passThrough,
            isTemporary: pending.isTemporary
        )
        let jobID = UUID()
        preparedMedia = prepared
        job = Job(id: jobID, filename: pending.originalFilename, stage: .uploading(UploadProgress(bytesSent: 0, totalBytes: size, bytesPerSecond: 0)), task: nil)
        let task = Task { [weak self] in
            guard let self else { return }
            await self.resumeUpload(videoID: videoID, prepared: prepared, filename: pending.originalFilename, jobID: jobID, configuration: configuration)
        }
        job?.task = task
    }

    func showSettings() {
        setup.serverURLText = configuration?.baseURL.absoluteString ?? "https://clips.talix.app"
        setup.tokenText = ""
        setup.errorMessage = nil
        isShowingSettings = true
    }

    func signOut() {
        job?.task?.cancel()
        Task { [weak self] in
            guard let self else { return }
            do {
                try await services.deleteConfiguration()
            } catch {
                showToast("The token could not be removed from Keychain.")
                return
            }
            configuration = nil
            videos = []
            nextCursor = nil
            listedSearchText = ""
            deselect()
            setup = SetupState()
            setup.errorMessage = nil
            isShowingSettings = false
            clearFinishedJob()
        }
    }

    private func loadInitialState() async {
        pendingUpload = await services.loadPendingUpload()
        do {
            configuration = try await services.loadConfiguration()
            if let configuration {
                setup.serverURLText = configuration.baseURL.absoluteString
                setup.isConfigured = true
            }
        } catch {
            setup.errorMessage = "ClipShare couldn't read the saved token from Keychain."
        }
        hasLoadedConfiguration = true
        if configuration != nil {
            refresh()
        }
    }

    private func prepareAndUpload(fileURL: URL, filename: String, jobID: UUID, idempotencyKey: UUID) async {
        do {
            let prepared = try await services.prepare(fileURL) { [weak self] progress in
                Task { @MainActor in
                    self?.updatePreparationProgress(progress, jobID: jobID)
                }
            }
            try Task.checkCancellation()
            preparedMedia = prepared
            let pending = PendingUpload(
                preparedFileURL: prepared.fileURL,
                isTemporary: prepared.isTemporary,
                originalFilename: filename,
                idempotencyKey: idempotencyKey,
                videoID: nil
            )
            pendingUpload = pending
            try await services.savePendingUpload(pending)
            await uploadPrepared(prepared, filename: filename, jobID: jobID, idempotencyKey: idempotencyKey)
        } catch is CancellationError {
            await cancelJob(jobID: jobID, prepared: preparedMedia)
        } catch {
            failJob(jobID: jobID, error: error)
        }
    }

    private func uploadPrepared(_ prepared: PreparedMedia, filename: String, jobID: UUID, idempotencyKey: UUID) async {
        guard let configuration else {
            failJob(jobID: jobID, message: "Connect ClipShare before uploading.")
            return
        }
        job?.stage = .uploading(UploadProgress(bytesSent: 0, totalBytes: prepared.info.sizeBytes, bytesPerSecond: 0))
        do {
            let video = try await services.upload(
                prepared,
                originalFilename: filename,
                idempotencyKey: idempotencyKey,
                configuration: configuration,
                onVideoCreated: { [weak self] videoID in
                    Task { @MainActor in
                        guard let self, let pending = self.pendingUpload else { return }
                        let updated = PendingUpload(preparedFileURL: pending.preparedFileURL, isTemporary: pending.isTemporary, originalFilename: pending.originalFilename, idempotencyKey: pending.idempotencyKey, videoID: videoID)
                        self.pendingUpload = updated
                        try? await self.services.savePendingUpload(updated)
                    }
                }
            ) { [weak self] progress in
                Task { @MainActor in
                    self?.updateUploadProgress(progress, jobID: jobID)
                }
            }
            try Task.checkCancellation()
            await completeJob(video: video, prepared: prepared, jobID: jobID)
        } catch is CancellationError {
            await cancelJob(jobID: jobID, prepared: prepared)
        } catch {
            failJob(jobID: jobID, error: error)
        }
    }

    private func resumeUpload(videoID: String, prepared: PreparedMedia, filename: String, jobID: UUID, configuration: AppConfiguration? = nil) async {
        guard let configuration = configuration ?? self.configuration else {
            failJob(jobID: jobID, message: "Connect ClipShare before uploading.")
            return
        }
        do {
            let video = try await services.resume(videoID: videoID, fileURL: prepared.fileURL, configuration: configuration) { [weak self] progress in
                Task { @MainActor in
                    self?.updateUploadProgress(progress, jobID: jobID)
                }
            }
            try Task.checkCancellation()
            await completeJob(video: video, prepared: prepared, jobID: jobID)
        } catch is CancellationError {
            await cancelJob(jobID: jobID, prepared: prepared)
        } catch {
            failJob(jobID: jobID, error: error)
        }
    }

    private func completeJob(video: Video, prepared: PreparedMedia, jobID: UUID) async {
        guard job?.id == jobID else { return }
        job?.stage = .done(video)
        copyLink(video)
        if let index = videos.firstIndex(where: { $0.id == video.id }) {
            videos[index] = video
        } else if uploadMatchesCurrentSearch(video) {
            videos.insert(video, at: 0)
        }
        pendingUpload = nil
        preparedMedia = nil
        sourceFileURL = nil
        idempotencyKey = nil
        await services.clearPendingUpload()
        await services.cleanup(prepared)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, self.job?.id == jobID, case .done = self.job?.stage else { return }
            self.job = nil
        }
    }

    private func cancelJob(jobID: UUID, prepared: PreparedMedia?) async {
        guard job?.id == jobID else { return }
        if let prepared {
            await services.cleanup(prepared)
        }
        await services.clearPendingUpload()
        pendingUpload = nil
        clearFinishedJob()
    }

    private func updatePreparationProgress(_ progress: Double, jobID: UUID) {
        guard job?.id == jobID, case .preparing = job?.stage else { return }
        job?.stage = .preparing(min(1, max(0, progress)))
    }

    private func updateUploadProgress(_ progress: UploadProgress, jobID: UUID) {
        guard job?.id == jobID, case .uploading = job?.stage else { return }
        job?.stage = .uploading(progress)
    }

    private func failJob(jobID: UUID, error: Error) {
        failJob(jobID: jobID, message: errorMessage(for: error))
    }

    private func failJob(jobID: UUID, message: String) {
        guard job?.id == jobID else { return }
        job?.stage = .failed(message)
        job?.task = nil
    }

    private func replaceVideo(_ replacement: Video) {
        guard let index = videos.firstIndex(where: { $0.id == replacement.id }) else { return }
        videos[index] = replacement
    }

    private func mergeVideoUpdate(
        _ response: Video,
        titleChanged: Bool,
        shareEnabledChanged: Bool,
        shareURLChanged: Bool = false
    ) {
        guard let index = videos.firstIndex(where: { $0.id == response.id }) else { return }
        let current = videos[index]
        videos[index] = Video(
            id: current.id,
            title: titleChanged ? response.title : current.title,
            originalFilename: current.originalFilename,
            sizeBytes: current.sizeBytes,
            durationSeconds: current.durationSeconds,
            width: current.width,
            height: current.height,
            status: current.status,
            shareEnabled: shareEnabledChanged ? response.shareEnabled : current.shareEnabled,
            shareUrl: shareURLChanged ? response.shareUrl : current.shareUrl,
            createdAt: current.createdAt,
            readyAt: current.readyAt
        )
    }

    private func returnToSetup(message: String) {
        configuration = nil
        videos = []
        nextCursor = nil
        listedSearchText = ""
        deselect()
        setup.isConfigured = false
        setup.tokenText = ""
        setup.errorMessage = message
        isShowingSettings = false
    }

    private func clearFinishedJob() {
        job?.task?.cancel()
        job = nil
        preparedMedia = nil
        sourceFileURL = nil
        idempotencyKey = nil
    }

    private func uploadMatchesCurrentSearch(_ video: Video) -> Bool {
        searchText.isEmpty
            || video.title.localizedCaseInsensitiveContains(searchText)
            || video.originalFilename.localizedCaseInsensitiveContains(searchText)
    }

    private func showToast(_ message: String) {
        toastTask?.cancel()
        toast = message
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    private func setupErrorMessage(for error: Error) -> String {
        switch error {
        case APIError.unauthorized:
            return "That token was rejected."
        case let APIError.network(underlying):
            // The system's own description says why (refused, DNS, TLS), which is
            // the one thing the user needs when the address is wrong.
            return "Couldn't reach the server. \(underlying.localizedDescription)"
        default:
            return errorMessage(for: error)
        }
    }

    private func errorMessage(for error: Error) -> String {
        if let mediaError = error as? MediaPipelineError {
            return mediaError.errorDescription ?? "The video could not be prepared."
        }
        if let apiError = error as? APIError {
            switch apiError {
            case .unauthorized:
                return "The owner token was rejected."
            case .notFound:
                return "The video was not found."
            case .conflict:
                return "The server could not complete that request. Try again."
            case .badRequest:
                return "The server rejected that request."
            case .server:
                return "The server had a problem. Try again."
            case .network:
                return "The network request failed. Check your connection."
            case .decoding:
                return "The server returned an unexpected response."
            }
        }
        if error is TokenStoreError {
            return "Keychain could not complete the request."
        }
        return "Something went wrong. Try again."
    }

    private static func validServerURL(_ value: String) -> URL? {
        guard var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            return nil
        }
        if scheme == "http", let host = components.host?.lowercased(), !isLocalHost(host) {
            return nil
        }
        while components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        return components.url
    }

    private static func isNonLocalHTTP(_ value: String) -> Bool {
        guard let components = URLComponents(string: value), components.scheme?.lowercased() == "http", let host = components.host?.lowercased() else { return false }
        return !isLocalHost(host)
    }

    private static func isLocalHost(_ host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".local")
    }
}

/// Screen corner for the floating drop target. Stored in defaults so it
/// can be moved away from other corner-dwelling apps like Clop.
enum DropPanelCorner: String, CaseIterable, Identifiable {
    case bottomLeft, bottomRight, topLeft, topRight

    private static let key = "dropPanelCorner"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .bottomLeft: return "Bottom left"
        case .bottomRight: return "Bottom right"
        case .topLeft: return "Top left"
        case .topRight: return "Top right"
        }
    }

    var shortLabel: String {
        switch self {
        case .bottomLeft: return "BL"
        case .bottomRight: return "BR"
        case .topLeft: return "TL"
        case .topRight: return "TR"
        }
    }

    static var stored: DropPanelCorner {
        UserDefaults.standard.string(forKey: key).flatMap(DropPanelCorner.init(rawValue:)) ?? .bottomLeft
    }

    func store() {
        UserDefaults.standard.set(rawValue, forKey: Self.key)
    }
}
