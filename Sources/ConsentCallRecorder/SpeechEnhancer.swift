import AVFoundation
import Foundation

enum SpeechEnhancerError: LocalizedError {
    case unsupportedAudioFormat
    case processingFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedAudioFormat:
            return "The recording uses an audio format that the speech-cleanup pass cannot process."
        case .processingFailed(let stage):
            return "Speech cleanup failed while \(stage)."
        }
    }
}

enum SpeechEnhancer {
    /// A deliberately conservative speech-oriented cleanup pass.
    ///
    /// It removes low rumble, softens very high-frequency hiss, and attenuates
    /// low-level sound between spoken phrases. It does not claim to separate
    /// voices from other loud sounds or repair a badly distorted source.
    static func enhance(input inputURL: URL, output outputURL: URL) throws {
        if outputURL.pathExtension.lowercased() == "m4a" {
            let intermediateURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("Voxora-Cleaned-\(UUID().uuidString)")
                .appendingPathExtension("wav")
            defer { try? FileManager.default.removeItem(at: intermediateURL) }

            try autoreleasepool {
                try enhancePCM(input: inputURL, output: intermediateURL)
            }
            try encodeM4A(input: intermediateURL, output: outputURL)
        } else {
            try enhancePCM(input: inputURL, output: outputURL)
        }
    }

    private static func enhancePCM(input inputURL: URL, output outputURL: URL) throws {
        let inputFile: AVAudioFile
        do {
            inputFile = try AVAudioFile(forReading: inputURL)
        } catch {
            throw SpeechEnhancerError.processingFailed("opening the source: \(error.localizedDescription)")
        }
        let format = inputFile.processingFormat

        guard format.commonFormat == .pcmFormatFloat32,
              !format.isInterleaved,
              format.channelCount > 0 else {
            throw SpeechEnhancerError.unsupportedAudioFormat
        }

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: Int(format.channelCount),
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let outputFile: AVAudioFile
        do {
            outputFile = try AVAudioFile(
                forWriting: outputURL,
                settings: outputSettings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            throw SpeechEnhancerError.processingFailed("creating the cleaned file: \(error.localizedDescription)")
        }

        let capacity: AVAudioFrameCount = 4_096
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw SpeechEnhancerError.unsupportedAudioFormat
        }

        let sampleRate = Float(format.sampleRate)
        let highPassCutoff: Float = 85
        let lowPassCutoff: Float = 7_800
        let highPassRC = 1 / (2 * Float.pi * highPassCutoff)
        let lowPassRC = 1 / (2 * Float.pi * lowPassCutoff)
        let dt: Float = 1 / sampleRate
        let highPassAlpha = highPassRC / (highPassRC + dt)
        let lowPassAlpha = dt / (lowPassRC + dt)
        let envelopeRelease = exp(-1 / (0.120 * sampleRate))
        let gateRelease = exp(-1 / (0.080 * sampleRate))
        let threshold: Float = 0.0065
        let quietGain: Float = 0.18

        let channelCount = Int(format.channelCount)
        var previousInput = Array(repeating: Float.zero, count: channelCount)
        var previousHighPass = Array(repeating: Float.zero, count: channelCount)
        var previousLowPass = Array(repeating: Float.zero, count: channelCount)
        var envelopes = Array(repeating: Float.zero, count: channelCount)
        var gateGains = Array(repeating: Float(1), count: channelCount)

        while inputFile.framePosition < inputFile.length {
            let remainingFrames = inputFile.length - inputFile.framePosition
            let framesToRead = AVAudioFrameCount(min(Int64(capacity), remainingFrames))
            do {
                try inputFile.read(into: buffer, frameCount: framesToRead)
            } catch {
                throw SpeechEnhancerError.processingFailed("reading source audio: \(error.localizedDescription)")
            }
            let frameCount = Int(buffer.frameLength)
            if frameCount == 0 { break }

            guard let channels = buffer.floatChannelData else {
                throw SpeechEnhancerError.unsupportedAudioFormat
            }

            for channel in 0..<channelCount {
                let samples = channels[channel]

                for frame in 0..<frameCount {
                    let inputSample = samples[frame]
                    let highPassed = highPassAlpha * (
                        previousHighPass[channel] + inputSample - previousInput[channel]
                    )
                    let lowPassed = previousLowPass[channel] + lowPassAlpha * (
                        highPassed - previousLowPass[channel]
                    )

                    previousInput[channel] = inputSample
                    previousHighPass[channel] = highPassed
                    previousLowPass[channel] = lowPassed

                    let magnitude = abs(lowPassed)
                    envelopes[channel] = max(magnitude, envelopes[channel] * envelopeRelease)
                    let targetGain: Float = envelopes[channel] >= threshold ? 1 : quietGain

                    if targetGain > gateGains[channel] {
                        gateGains[channel] += (targetGain - gateGains[channel]) * 0.35
                    } else {
                        gateGains[channel] = targetGain + (gateGains[channel] - targetGain) * gateRelease
                    }

                    let cleaned = lowPassed * gateGains[channel] * 1.08
                    samples[frame] = max(-0.98, min(0.98, cleaned))
                }
            }

            do {
                try outputFile.write(from: buffer)
            } catch {
                throw SpeechEnhancerError.processingFailed("writing cleaned audio: \(error.localizedDescription)")
            }
        }
    }

    private static func encodeM4A(input inputURL: URL, output outputURL: URL) throws {
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let asset = AVURLAsset(url: inputURL)
        guard let sourceTrack = asset.tracks(withMediaType: .audio).first else {
            throw SpeechEnhancerError.processingFailed("finding the cleaned audio track")
        }

        let reader: AVAssetReader
        let writer: AVAssetWriter
        do {
            reader = try AVAssetReader(asset: asset)
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        } catch {
            throw SpeechEnhancerError.processingFailed("creating the M4A encoder: \(error.localizedDescription)")
        }

        let readerOutput = AVAssetReaderTrackOutput(
            track: sourceTrack,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsNonInterleaved: false
            ]
        )
        let sourceFormatHint = sourceTrack.formatDescriptions.first.map { $0 as! CMFormatDescription }
        var writerInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 160_000
            ],
            sourceFormatHint: sourceFormatHint
        )

        guard reader.canAdd(readerOutput) else {
            throw SpeechEnhancerError.processingFailed("configuring the M4A encoder")
        }
        if !writer.canAdd(writerInput) {
            writerInput = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatAppleLossless,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitDepthHintKey: 16
                ],
                sourceFormatHint: sourceFormatHint
            )
        }
        guard writer.canAdd(writerInput) else {
            throw SpeechEnhancerError.processingFailed("configuring the M4A encoder")
        }
        reader.add(readerOutput)
        writer.add(writerInput)

        guard writer.startWriting(), reader.startReading() else {
            throw SpeechEnhancerError.processingFailed(
                "starting the M4A encoder: \(writer.error?.localizedDescription ?? reader.error?.localizedDescription ?? "unknown error")"
            )
        }
        writer.startSession(atSourceTime: .zero)

        while reader.status == .reading {
            if writerInput.isReadyForMoreMediaData {
                guard let sample = readerOutput.copyNextSampleBuffer() else { break }
                if !writerInput.append(sample) { break }
            } else {
                Thread.sleep(forTimeInterval: 0.002)
            }
        }
        writerInput.markAsFinished()

        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        finished.wait()

        guard reader.status == .completed, writer.status == .completed else {
            throw SpeechEnhancerError.processingFailed(
                "encoding the M4A file: \(writer.error?.localizedDescription ?? reader.error?.localizedDescription ?? "unknown error")"
            )
        }
    }
}
