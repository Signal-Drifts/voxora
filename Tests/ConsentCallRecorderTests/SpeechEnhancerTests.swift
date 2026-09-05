import AVFoundation
import XCTest
@testable import ConsentCallRecorder

final class SpeechEnhancerTests: XCTestCase {
    func testCleanupAttenuatesQuietNoiseAndPreservesSpeechBand() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConsentCallRecorderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let inputURL = directory.appendingPathComponent("input.wav")
        let outputURL = directory.appendingPathComponent("output.wav")
        let sampleRate = 48_000.0
        let frameCount = Int(sampleRate * 3)

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ), let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ), let samples = inputBuffer.floatChannelData?[0] else {
            XCTFail("Could not create the synthetic input buffer")
            return
        }

        inputBuffer.frameLength = AVAudioFrameCount(frameCount)
        var seed: UInt64 = 0x1234_5678

        for frame in 0..<frameCount {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1
            let normalizedNoise = Float(Int32(truncatingIfNeeded: seed >> 32)) / Float(Int32.max)
            let noise = normalizedNoise * 0.002
            let time = Double(frame) / sampleRate
            let speechTone: Float = (time >= 1 && time < 2)
                ? Float(sin(2 * Double.pi * 440 * time)) * 0.10
                : 0
            samples[frame] = speechTone + noise
        }

        let fileSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        try writeAndClose(inputBuffer, to: inputURL, settings: fileSettings)

        try SpeechEnhancer.enhance(input: inputURL, output: outputURL)

        let outputFile = try AVAudioFile(forReading: outputURL)
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFile.processingFormat,
            frameCapacity: AVAudioFrameCount(outputFile.length)
        ) else {
            XCTFail("Could not create the output buffer")
            return
        }
        try outputFile.read(into: outputBuffer)

        XCTAssertEqual(Int(outputBuffer.frameLength), frameCount, accuracy: 1)

        guard let outputSamples = outputBuffer.floatChannelData?[0] else {
            XCTFail("The cleaned file was not readable as Float32 audio")
            return
        }

        let quietRange = Int(sampleRate * 2.60)..<Int(sampleRate * 2.95)
        let voiceRange = Int(sampleRate * 1.20)..<Int(sampleRate * 1.80)
        let inputNoiseRMS = rms(samples, in: quietRange)
        let outputNoiseRMS = rms(outputSamples, in: quietRange)
        let inputVoiceRMS = rms(samples, in: voiceRange)
        let outputVoiceRMS = rms(outputSamples, in: voiceRange)

        XCTAssertLessThan(outputNoiseRMS, inputNoiseRMS * 0.45)
        XCTAssertGreaterThan(outputVoiceRMS, inputVoiceRMS * 0.70)
        XCTAssertLessThan(outputVoiceRMS, inputVoiceRMS * 1.25)
    }

    private func rms(_ samples: UnsafeMutablePointer<Float>, in range: Range<Int>) -> Float {
        var sum: Float = 0
        for index in range {
            let value = samples[index]
            sum += value * value
        }
        return sqrt(sum / Float(range.count))
    }

    private func writeAndClose(
        _ buffer: AVAudioPCMBuffer,
        to url: URL,
        settings: [String: Any]
    ) throws {
        try autoreleasepool {
            let file = try AVAudioFile(
                forWriting: url,
                settings: settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            try file.write(from: buffer)
        }
    }
}
