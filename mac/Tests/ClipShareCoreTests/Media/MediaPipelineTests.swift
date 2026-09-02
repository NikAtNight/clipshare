import AVFoundation
import AudioToolbox
import CoreMedia
import CoreVideo
import XCTest
@testable import ClipShareCore

final class MediaPipelineTests: XCTestCase {
    private var fixtureDirectory: URL!

    override func setUpWithError() throws {
        fixtureDirectory = FileManager.default.temporaryDirectory
            .appending(path: "ClipShareMediaTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let fixtureDirectory {
            try? FileManager.default.removeItem(at: fixtureDirectory)
        }
    }

    func testOptimizedMP4PassesThrough() async throws {
        let url = fixtureDirectory.appending(path: "optimized.mp4")
        try await writeFixture(to: url, fileType: .mp4, videoCodec: .h264, includesAudio: true, optimize: true)

        let info = try await MediaPipeline.inspect(url)
        XCTAssertEqual(info.container, .mp4)
        XCTAssertEqual(info.videoCodec, "avc1")
        XCTAssertTrue(isAAC(info.audioCodec))
        XCTAssertTrue(info.isFastStart)
        XCTAssertEqual(MediaPipeline.plan(for: info), .passThrough)

        let prepared = try await MediaPipeline.prepare(url) { _ in }
        XCTAssertEqual(prepared.fileURL, url)
        XCTAssertFalse(prepared.isTemporary)
    }

    func testMOVRemuxesToFastStartMP4() async throws {
        // AVAssetExportPresetPassthrough is never listed by allExportPresets(),
        // so don't gate on it. If the session can't be created the pipeline
        // throws and this test should fail, not skip.
        let url = fixtureDirectory.appending(path: "source.mov")
        try await writeFixture(to: url, fileType: .mov, videoCodec: .h264, includesAudio: true, optimize: false)

        let input = try await MediaPipeline.inspect(url)
        XCTAssertEqual(MediaPipeline.plan(for: input), .remux)

        let prepared = try await MediaPipeline.prepare(url) { _ in }
        defer { try? prepared.cleanup() }
        XCTAssertTrue(prepared.isTemporary)
        XCTAssertEqual(prepared.info.container, .mp4)
        XCTAssertEqual(prepared.info.videoCodec, "avc1")
        XCTAssertTrue(prepared.info.isFastStart)
        XCTAssertEqual(prepared.info.durationSeconds ?? 0, input.durationSeconds ?? 0, accuracy: 0.1)
    }

    func testHEVCMOVTranscodesAndReportsMonotonicProgress() async throws {
        try requireExportPreset(AVAssetExportPresetHighestQuality)
        let url = fixtureDirectory.appending(path: "source-hevc.mov")
        try await writeFixture(to: url, fileType: .mov, videoCodec: .hevc, includesAudio: false, optimize: false)

        let input = try await MediaPipeline.inspect(url)
        XCTAssertEqual(MediaPipeline.plan(for: input), .transcode)

        let recorder = ProgressRecorder()
        let prepared = try await MediaPipeline.prepare(url) { value in
            recorder.append(value)
        }
        defer { try? prepared.cleanup() }

        XCTAssertEqual(prepared.plan, .transcode)
        XCTAssertEqual(prepared.info.videoCodec, "avc1")
        XCTAssertTrue(prepared.info.isFastStart)
        let capturedValues = recorder.values()
        XCTAssertGreaterThanOrEqual(capturedValues.last ?? 0, 1)
        XCTAssertTrue(zip(capturedValues, capturedValues.dropFirst()).allSatisfy { $0 <= $1 })
    }

    func testUnreadableMP4NamedFileIsUnsupported() async throws {
        let url = fixtureDirectory.appending(path: "not-a-video.mp4")
        try Data("not a video".utf8).write(to: url)

        let plan = await MediaPipeline.plan(for: url)
        guard case .unsupported = plan else {
            return XCTFail("Expected an unsupported plan")
        }
    }

    func testVideoOnlyMP4PassesThrough() async throws {
        let url = fixtureDirectory.appending(path: "video-only.mp4")
        try await writeFixture(to: url, fileType: .mp4, videoCodec: .h264, includesAudio: false, optimize: true)

        let info = try await MediaPipeline.inspect(url)
        XCTAssertNil(info.audioCodec)
        XCTAssertEqual(MediaPipeline.plan(for: info), .passThrough)
        let prepared = try await MediaPipeline.prepare(url) { _ in }
        XCTAssertEqual(prepared.fileURL, url)
        XCTAssertFalse(prepared.isTemporary)
    }

    private func requireExportPreset(_ preset: String) throws {
        guard AVAssetExportSession.allExportPresets().contains(preset) else {
            throw XCTSkip("This Mac does not support \(preset).")
        }
    }

    private func isAAC(_ codec: String?) -> Bool {
        codec == "aac" || codec == "mp4a"
    }

    private func writeFixture(
        to url: URL,
        fileType: AVFileType,
        videoCodec: AVVideoCodecType,
        includesAudio: Bool,
        optimize: Bool
    ) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        writer.shouldOptimizeForNetworkUse = optimize

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: videoCodec,
            AVVideoWidthKey: 320,
            AVVideoHeightKey: 240
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else {
            throw XCTSkip("This Mac does not support \(videoCodec.rawValue) encoding.")
        }
        writer.add(videoInput)

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: 320,
                kCVPixelBufferHeightKey as String: 240
            ]
        )

        var audioInput: AVAssetWriterInput?
        if includesAudio {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 64_000
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else {
                throw XCTSkip("This Mac does not support AAC encoding.")
            }
            writer.add(input)
            audioInput = input
        }

        guard writer.startWriting() else {
            throw XCTSkip("This Mac does not support the requested video fixture.")
        }
        writer.startSession(atSourceTime: .zero)

        for frame in 0 ..< 30 {
            try await waitUntilReady(videoInput)
            guard let pixelBuffer = makePixelBuffer() else {
                throw MediaPipelineError.exportFailed("The test fixture could not allocate a video frame.")
            }
            let presentationTime = CMTime(value: CMTimeValue(frame), timescale: 30)
            guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
                throw writer.error ?? MediaPipelineError.exportFailed("The test fixture could not append a video frame.")
            }
        }
        videoInput.markAsFinished()

        if let audioInput {
            for packet in 0 ..< 44 {
                try await waitUntilReady(audioInput)
                let presentationTime = CMTime(value: CMTimeValue(packet * 1_024), timescale: 44_100)
                let buffer = try makeAudioBuffer(presentationTime: presentationTime)
                guard audioInput.append(buffer) else {
                    throw writer.error ?? MediaPipelineError.exportFailed("The test fixture could not append audio.")
                }
            }
            audioInput.markAsFinished()
        }

        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }
        guard writer.status == .completed else {
            throw XCTSkip("This Mac could not encode the requested video fixture.")
        }
    }

    private func waitUntilReady(_ input: AVAssetWriterInput) async throws {
        while !input.isReadyForMoreMediaData {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    private func makePixelBuffer() -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let result = CVPixelBufferCreate(
            kCFAllocatorDefault,
            320,
            240,
            kCVPixelFormatType_32ARGB,
            nil,
            &pixelBuffer
        )
        guard result == kCVReturnSuccess, let pixelBuffer else {
            return nil
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) {
            memset(baseAddress, 0, CVPixelBufferGetDataSize(pixelBuffer))
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        return pixelBuffer
    }

    private func makeAudioBuffer(presentationTime: CMTime) throws -> CMSampleBuffer {
        var streamDescription = AudioStreamBasicDescription(
            mSampleRate: 44_100,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var formatDescription: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &streamDescription,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        ) == noErr, let formatDescription else {
            throw MediaPipelineError.exportFailed("The test fixture could not describe audio.")
        }

        let byteCount = 1_024 * 4
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == kCMBlockBufferNoErr, let blockBuffer else {
            throw MediaPipelineError.exportFailed("The test fixture could not allocate audio.")
        }
        guard CMBlockBufferFillDataBytes(with: 0, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: byteCount) == kCMBlockBufferNoErr else {
            throw MediaPipelineError.exportFailed("The test fixture could not fill audio.")
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1_024, timescale: 44_100),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        var sampleSize = 4
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1_024,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else {
            throw MediaPipelineError.exportFailed("The test fixture could not create audio samples.")
        }
        return sampleBuffer
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedValues: [Double] = []

    func append(_ value: Double) {
        lock.lock()
        recordedValues.append(value)
        lock.unlock()
    }

    func values() -> [Double] {
        lock.lock()
        defer { lock.unlock() }
        return recordedValues
    }
}
