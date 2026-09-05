import AVFoundation
import CoreMedia
import CoreGraphics
import Foundation
import ScreenCaptureKit

enum RecorderError: LocalizedError {
    case capturePermissionDenied
    case noDisplay
    case cannotCreateWriter
    case noAudioReceived
    case writerFailed(String)
    case missingDestination

    var errorDescription: String? {
        switch self {
        case .capturePermissionDenied:
            return "Screen & System Audio Recording access is not active. Enable Voxora in System Settings, then quit and reopen Voxora."
        case .noDisplay:
            return "No active Mac display was found."
        case .cannotCreateWriter:
            return "The audio file could not be created."
        case .noAudioReceived:
            return "No system audio was received."
        case .writerFailed(let message):
            return "The audio writer failed: \(message)"
        case .missingDestination:
            return "The recording destination is missing."
        }
    }
}

final class SystemAudioRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    var onUnexpectedStop: ((Error) -> Void)?
    var onLevel: ((Float) -> Void)?

    private let sampleQueue = DispatchQueue(label: "app.consentcallrecorder.audio-samples")
    private let lock = NSLock()

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var audioInput: AVAssetWriterInput?
    private var sessionStarted = false
    private var isStopping = false
    private var isPaused = false
    private var adjustAfterResume = false
    private var accumulatedPauseDuration = CMTime.zero
    private var lastSourceEndTime = CMTime.invalid

    func start(writingTo outputURL: URL) async throws {
        guard CGPreflightScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()
            throw RecorderError.capturePermissionDenied
        }

        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )

        guard let display = content.displays.first else {
            throw RecorderError.noDisplay
        }

        let ownBundleID = Bundle.main.bundleIdentifier
        let ownApplication = content.applications.first { application in
            application.bundleIdentifier == ownBundleID
        }
        let excludedApplications = ownApplication.map { [$0] } ?? []
        let filter = SCContentFilter(
            display: display,
            excludingApplications: excludedApplications,
            exceptingWindows: []
        )

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 160_000
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = true

        guard writer.canAdd(input) else {
            throw RecorderError.cannotCreateWriter
        }
        writer.add(input)

        guard writer.startWriting() else {
            throw RecorderError.writerFailed(writer.error?.localizedDescription ?? "unknown error")
        }

        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.width = 2
        configuration.height = 2

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)

        lock.withLock {
            self.writer = writer
            self.audioInput = input
            self.stream = stream
            sessionStarted = false
            isStopping = false
            isPaused = false
            adjustAfterResume = false
            accumulatedPauseDuration = .zero
            lastSourceEndTime = .invalid
        }

        do {
            try await stream.startCapture()
        } catch {
            lock.withLock {
                writer.cancelWriting()
                clearLockedState()
            }
            throw error
        }
    }

    func stop() async throws {
        let activeStream = lock.withLock {
            isStopping = true
            return stream
        }

        if let activeStream {
            try? await activeStream.stopCapture()
            try? activeStream.removeStreamOutput(self, type: .audio)
        }

        try await finishWriting()
    }

    func pause() async throws {
        lock.withLock {
            isPaused = true
        }
    }

    func resume() async throws {
        lock.withLock {
            guard isPaused else { return }
            isPaused = false
            adjustAfterResume = true
        }
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .audio, sampleBuffer.isValid, sampleBuffer.numSamples > 0 else { return }

        lock.lock()
        defer { lock.unlock() }

        guard let writer, let audioInput, writer.status == .writing else { return }
        guard !isPaused else { return }

        let sourceStartTime = sampleBuffer.presentationTimeStamp
        if adjustAfterResume, lastSourceEndTime.isValid {
            let gap = sourceStartTime - lastSourceEndTime
            if gap.isValid, gap > .zero {
                accumulatedPauseDuration = accumulatedPauseDuration + gap
            }
            adjustAfterResume = false
        }

        guard let outputBuffer = Self.copy(
            sampleBuffer,
            subtracting: accumulatedPauseDuration
        ) else {
            let error = RecorderError.writerFailed("Could not adjust audio timing after pause.")
            writer.cancelWriting()
            clearLockedState()
            onUnexpectedStop?(error)
            return
        }

        if !sessionStarted {
            writer.startSession(atSourceTime: outputBuffer.presentationTimeStamp)
            sessionStarted = true
        }

        guard audioInput.isReadyForMoreMediaData else { return }
        if !audioInput.append(outputBuffer) {
            let error = writer.error ?? RecorderError.writerFailed("Could not append audio samples.")
            writer.cancelWriting()
            clearLockedState()
            onUnexpectedStop?(error)
        } else {
            let sourceDuration = Self.duration(of: sampleBuffer)
            lastSourceEndTime = sourceStartTime + sourceDuration
            onLevel?(Self.level(from: sampleBuffer))
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock()
        let expected = isStopping
        lock.unlock()
        let paused = lock.withLock { isPaused }
        if !expected && !paused {
            onUnexpectedStop?(error)
        }
    }

    private func finishWriting() async throws {
        let writer: AVAssetWriter
        let input: AVAssetWriterInput
        let receivedAudio: Bool

        let snapshot: (AVAssetWriter, AVAssetWriterInput, Bool)? = lock.withLock {
            guard let currentWriter = self.writer, let currentInput = audioInput else {
                return nil
            }
            stream = nil
            return (currentWriter, currentInput, sessionStarted)
        }

        guard let snapshot else {
            throw RecorderError.cannotCreateWriter
        }
        writer = snapshot.0
        input = snapshot.1
        receivedAudio = snapshot.2

        guard receivedAudio else {
            writer.cancelWriting()
            lock.withLock {
                clearLockedState()
            }
            throw RecorderError.noAudioReceived
        }

        input.markAsFinished()

        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }

        lock.withLock {
            clearLockedState()
        }

        guard writer.status == .completed else {
            throw RecorderError.writerFailed(writer.error?.localizedDescription ?? "unknown error")
        }
    }

    private func clearLockedState() {
        stream = nil
        writer = nil
        audioInput = nil
        sessionStarted = false
        isStopping = false
        isPaused = false
        adjustAfterResume = false
        accumulatedPauseDuration = .zero
        lastSourceEndTime = .invalid
    }

    private static func duration(of sampleBuffer: CMSampleBuffer) -> CMTime {
        let duration = sampleBuffer.duration
        if duration.isValid, duration > .zero { return duration }
        guard let format = sampleBuffer.formatDescription,
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(format),
              description.pointee.mSampleRate > 0 else {
            return .zero
        }
        return CMTime(
            value: CMTimeValue(sampleBuffer.numSamples),
            timescale: CMTimeScale(description.pointee.mSampleRate.rounded())
        )
    }

    private static func copy(
        _ sampleBuffer: CMSampleBuffer,
        subtracting offset: CMTime
    ) -> CMSampleBuffer? {
        guard offset > .zero else { return sampleBuffer }

        var count = 0
        guard CMSampleBufferGetSampleTimingInfoArray(
            sampleBuffer,
            entryCount: 0,
            arrayToFill: nil,
            entriesNeededOut: &count
        ) == noErr, count > 0 else { return nil }

        var timing = Array(repeating: CMSampleTimingInfo(), count: count)
        let readStatus = timing.withUnsafeMutableBufferPointer { pointer in
            CMSampleBufferGetSampleTimingInfoArray(
                sampleBuffer,
                entryCount: count,
                arrayToFill: pointer.baseAddress,
                entriesNeededOut: nil
            )
        }
        guard readStatus == noErr else { return nil }

        for index in timing.indices {
            if timing[index].presentationTimeStamp.isValid {
                timing[index].presentationTimeStamp = adjustedTime(
                    timing[index].presentationTimeStamp,
                    subtracting: offset
                )
            }
            if timing[index].decodeTimeStamp.isValid {
                timing[index].decodeTimeStamp = adjustedTime(
                    timing[index].decodeTimeStamp,
                    subtracting: offset
                )
            }
        }

        var adjusted: CMSampleBuffer?
        let copyStatus = timing.withUnsafeBufferPointer { pointer in
            CMSampleBufferCreateCopyWithNewTiming(
                allocator: kCFAllocatorDefault,
                sampleBuffer: sampleBuffer,
                sampleTimingEntryCount: count,
                sampleTimingArray: pointer.baseAddress!,
                sampleBufferOut: &adjusted
            )
        }
        return copyStatus == noErr ? adjusted : nil
    }

    static func adjustedTime(_ sourceTime: CMTime, subtracting pausedTime: CMTime) -> CMTime {
        sourceTime - pausedTime
    }

    private static func level(from sampleBuffer: CMSampleBuffer) -> Float {
        var measured: Float = 0

        try? sampleBuffer.withAudioBufferList { audioBufferList, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList.unsafeMutablePointer)
            var sum: Float = 0
            var sampleCount = 0

            for buffer in buffers {
                guard let data = buffer.mData else { continue }
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                let samples = data.assumingMemoryBound(to: Float.self)
                for index in 0..<count {
                    let value = samples[index]
                    sum += value * value
                }
                sampleCount += count
            }

            guard sampleCount > 0 else { return }
            let rms = sqrt(sum / Float(sampleCount))
            measured = min(1, max(0.08, rms * 6.5))
        }

        return measured
    }
}
