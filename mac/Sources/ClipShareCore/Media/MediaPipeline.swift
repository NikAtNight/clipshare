import AVFoundation
import CoreMedia
import Foundation

public enum Container: Sendable, Equatable {
    case mp4
    case quickTime
    case other(String)
}

public struct MediaInfo: Sendable, Equatable {
    public var container: Container
    public var videoCodec: String?
    public var audioCodec: String?
    public var durationSeconds: Double?
    public var width: Int?
    public var height: Int?
    public var sizeBytes: Int64
    public var isFastStart: Bool
    public var hasRotation: Bool

    public init(
        container: Container,
        videoCodec: String?,
        audioCodec: String?,
        durationSeconds: Double?,
        width: Int?,
        height: Int?,
        sizeBytes: Int64,
        isFastStart: Bool,
        hasRotation: Bool
    ) {
        self.container = container
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.durationSeconds = durationSeconds
        self.width = width
        self.height = height
        self.sizeBytes = sizeBytes
        self.isFastStart = isFastStart
        self.hasRotation = hasRotation
    }
}

public enum PreparationPlan: Sendable, Equatable {
    case passThrough
    case remux
    case transcode
    case unsupported(String)
}

public struct PreparedMedia: Sendable {
    public var fileURL: URL
    public var info: MediaInfo
    public var plan: PreparationPlan
    public var isTemporary: Bool

    public init(fileURL: URL, info: MediaInfo, plan: PreparationPlan, isTemporary: Bool) {
        self.fileURL = fileURL
        self.info = info
        self.plan = plan
        self.isTemporary = isTemporary
    }

    public func cleanup() throws {
        guard isTemporary, FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }
        try FileManager.default.removeItem(at: fileURL)
    }
}

public enum MediaPipelineError: Error, LocalizedError, Sendable, Equatable {
    case unsupported(String)
    case inspectionFailed(String)
    case exportFailed(String)
    case outputNotCompatible(String)

    public var errorDescription: String? {
        switch self {
        case let .unsupported(message), let .inspectionFailed(message), let .exportFailed(message), let .outputNotCompatible(message):
            return message
        }
    }
}

public enum MediaPipeline {
    public static func inspect(_ url: URL) async throws -> MediaInfo {
        do {
            return try await inspectReadable(url)
        } catch let error as MediaPipelineError {
            throw error
        } catch {
            throw MediaPipelineError.unsupported("This file can't be read by macOS. Convert it to MP4 or MOV first.")
        }
    }

    private static func inspectReadable(_ url: URL) async throws -> MediaInfo {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let fileSize = values.fileSize else {
            throw MediaPipelineError.unsupported("This file can't be read by macOS. Convert it to MP4 or MOV first.")
        }

        let asset = AVURLAsset(url: url)
        guard try await asset.load(.isReadable) else {
            throw MediaPipelineError.unsupported("This file can't be read by macOS. Convert it to MP4 or MOV first.")
        }

        let tracks = try await asset.load(.tracks)
        guard let videoTrack = tracks.first(where: { $0.mediaType == .video }) else {
            throw MediaPipelineError.unsupported("This file can't be read by macOS. Convert it to MP4 or MOV first.")
        }

        let videoDescriptions = try await videoTrack.load(.formatDescriptions)
        let videoCodec = codecName(from: videoDescriptions.first)

        let audioTrack = tracks.first(where: { $0.mediaType == .audio })
        let audioDescriptions = try await audioTrack?.load(.formatDescriptions)
        let audioCodec = codecName(from: audioDescriptions?.first)

        let duration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(duration)
        let durationSeconds = seconds.isFinite && seconds >= 0 ? seconds : nil

        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let hasRotation = abs(transform.b) > 0.5 || abs(transform.c) > 0.5
        let naturalWidth = abs(Int(naturalSize.width.rounded(.toNearestOrAwayFromZero)))
        let naturalHeight = abs(Int(naturalSize.height.rounded(.toNearestOrAwayFromZero)))
        let width = hasRotation ? naturalHeight : naturalWidth
        let height = hasRotation ? naturalWidth : naturalHeight

        let boxInfo = try MP4Boxes.fileInfo(at: url)
        return MediaInfo(
            container: container(for: boxInfo.majorBrand),
            videoCodec: videoCodec,
            audioCodec: audioCodec,
            durationSeconds: durationSeconds,
            width: width > 0 ? width : nil,
            height: height > 0 ? height : nil,
            sizeBytes: Int64(fileSize),
            isFastStart: boxInfo.isFastStart,
            hasRotation: hasRotation
        )
    }

    public static func plan(for info: MediaInfo) -> PreparationPlan {
        guard info.videoCodec == "avc1", isAAC(info.audioCodec) else {
            return .transcode
        }
        if info.container == .mp4, info.isFastStart {
            return .passThrough
        }
        return .remux
    }

    public static func plan(for url: URL) async -> PreparationPlan {
        do {
            return plan(for: try await inspect(url))
        } catch let error as MediaPipelineError {
            return .unsupported(error.errorDescription ?? "This file can't be read by macOS. Convert it to MP4 or MOV first.")
        } catch {
            return .unsupported("This file can't be read by macOS. Convert it to MP4 or MOV first.")
        }
    }

    public static func prepare(
        _ url: URL,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws -> PreparedMedia {
        let sourceInfo = try await inspect(url)
        let sourcePlan = plan(for: sourceInfo)

        if sourcePlan == .passThrough {
            progress(1)
            return PreparedMedia(fileURL: url, info: sourceInfo, plan: sourcePlan, isTemporary: false)
        }

        let outputURL = try temporaryOutputURL()
        do {
            if sourcePlan == .remux {
                do {
                    let info = try await export(
                        url,
                        outputURL: outputURL,
                        preset: AVAssetExportPresetPassthrough,
                        progress: progress
                    )
                    try validatePreparedOutput(info)
                    return PreparedMedia(fileURL: outputURL, info: info, plan: .remux, isTemporary: true)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    try? FileManager.default.removeItem(at: outputURL)
                }
            }

            let preset = transcodePreset(for: sourceInfo)
            let info = try await export(url, outputURL: outputURL, preset: preset, progress: progress)
            try validatePreparedOutput(info)
            return PreparedMedia(fileURL: outputURL, info: info, plan: .transcode, isTemporary: true)
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    private static func export(
        _ sourceURL: URL,
        outputURL: URL,
        preset: String,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws -> MediaInfo {
        let asset = AVURLAsset(url: sourceURL)
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw MediaPipelineError.exportFailed("macOS couldn't start video preparation.")
        }
        guard session.supportedFileTypes.contains(.mp4) else {
            throw MediaPipelineError.exportFailed("macOS can't create an MP4 from this video.")
        }

        session.shouldOptimizeForNetworkUse = true

        try Task.checkCancellation()
        async let exportOperation: Void = session.export(to: outputURL, as: .mp4)
        for await state in session.states(updateInterval: 0.25) {
            if case let .exporting(exportProgress) = state {
                progress(min(1, max(0, exportProgress.fractionCompleted)))
            }
        }
        try await exportOperation

        try Task.checkCancellation()
        progress(1)
        return try await inspect(outputURL)
    }

    private static func temporaryOutputURL() throws -> URL {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "ClipShare", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "\(UUID().uuidString).mp4", directoryHint: .notDirectory)
    }

    private static func transcodePreset(for info: MediaInfo) -> String {
        let longEdge = max(info.width ?? 0, info.height ?? 0)
        return longEdge > 1_080 ? AVAssetExportPreset1920x1080 : AVAssetExportPresetHighestQuality
    }

    private static func validatePreparedOutput(_ info: MediaInfo) throws {
        guard info.container == .mp4, info.videoCodec == "avc1", isAAC(info.audioCodec), info.isFastStart else {
            throw MediaPipelineError.outputNotCompatible("macOS created a video that browsers can't play. Try converting the original file to MP4 first.")
        }
    }

    private static func isAAC(_ codec: String?) -> Bool {
        guard let codec else {
            return true
        }
        return codec == "aac" || codec == "mp4a"
    }

    private static func codecName(from description: CMFormatDescription?) -> String? {
        guard let description else {
            return nil
        }
        let subtype = CMFormatDescriptionGetMediaSubType(description)
        let bytes: [UInt8] = [
            UInt8((subtype >> 24) & 0xff),
            UInt8((subtype >> 16) & 0xff),
            UInt8((subtype >> 8) & 0xff),
            UInt8(subtype & 0xff)
        ]
        return String(bytes: bytes, encoding: .macOSRoman)?.trimmingCharacters(in: .whitespaces)
    }

    private static func container(for majorBrand: String?) -> Container {
        guard let majorBrand else {
            return .other("unknown")
        }
        if majorBrand == "qt  " {
            return .quickTime
        }
        let mp4Brands: Set<String> = ["isom", "iso2", "iso3", "iso4", "iso5", "iso6", "iso7", "iso8", "iso9", "mp41", "mp42", "avc1", "M4V ", "MSNV", "dash"]
        if mp4Brands.contains(majorBrand) {
            return .mp4
        }
        return .other(majorBrand.trimmingCharacters(in: .whitespaces))
    }
}
