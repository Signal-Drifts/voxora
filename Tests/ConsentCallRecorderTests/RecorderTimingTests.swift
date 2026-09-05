import CoreMedia
import XCTest
@testable import ConsentCallRecorder

final class RecorderTimingTests: XCTestCase {
    func testPauseDurationIsRemovedFromOutputTimeline() {
        let sourceTime = CMTime(seconds: 14.5, preferredTimescale: 48_000)
        let pausedTime = CMTime(seconds: 4.25, preferredTimescale: 48_000)

        let outputTime = SystemAudioRecorder.adjustedTime(
            sourceTime,
            subtracting: pausedTime
        )

        XCTAssertEqual(outputTime.seconds, 10.25, accuracy: 0.000_001)
    }
}
