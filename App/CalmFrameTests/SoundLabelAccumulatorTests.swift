import XCTest
@testable import CalmFrame

/// C2 标签映射与累积测试（design.md §3.1）。
final class SoundLabelAccumulatorTests: XCTestCase {

    func testTypingAccumulatesOnlyTyping() {
        var acc = SoundLabelAccumulator()
        acc.ingest(identifier: "typing", confidence: 0.9, durationSeconds: 10)
        acc.ingest(identifier: "typing", confidence: 0.6, durationSeconds: 5)
        let (typing, speech) = acc.densities(windowSeconds: 30)
        XCTAssertEqual(typing, 0.5, accuracy: 0.001)
        XCTAssertEqual(speech, 0, accuracy: 0.001)
    }

    func testSpeechIncludesConversationAndLaughter() {
        var acc = SoundLabelAccumulator()
        acc.ingest(identifier: "speech", confidence: 0.9, durationSeconds: 6)
        acc.ingest(identifier: "conversation", confidence: 0.8, durationSeconds: 6)
        acc.ingest(identifier: "laughter", confidence: 0.7, durationSeconds: 3)
        let (typing, speech) = acc.densities(windowSeconds: 30)
        XCTAssertEqual(typing, 0, accuracy: 0.001)
        XCTAssertEqual(speech, 0.5, accuracy: 0.001)
    }

    func testLowConfidenceObservationsAreIgnored() {
        var acc = SoundLabelAccumulator()
        acc.ingest(identifier: "typing", confidence: 0.49, durationSeconds: 20)
        acc.ingest(identifier: "speech", confidence: 0.1, durationSeconds: 20)
        let (typing, speech) = acc.densities(windowSeconds: 30)
        XCTAssertEqual(typing, 0, accuracy: 0.001)
        XCTAssertEqual(speech, 0, accuracy: 0.001)
    }

    func testUnknownLabelsCountAsOther() {
        var acc = SoundLabelAccumulator()
        acc.ingest(identifier: "silence", confidence: 0.9, durationSeconds: 10)
        acc.ingest(identifier: "dog barking", confidence: 0.9, durationSeconds: 10)
        let (typing, speech) = acc.densities(windowSeconds: 30)
        XCTAssertEqual(typing, 0, accuracy: 0.001)
        XCTAssertEqual(speech, 0, accuracy: 0.001)
    }

    func testDensitiesAreClampedToOne() {
        var acc = SoundLabelAccumulator()
        acc.ingest(identifier: "typing", confidence: 0.9, durationSeconds: 40)
        let (typing, _) = acc.densities(windowSeconds: 30)
        XCTAssertEqual(typing, 1, accuracy: 0.001)
    }

    func testZeroWindowReturnsZero() {
        var acc = SoundLabelAccumulator()
        acc.ingest(identifier: "typing", confidence: 0.9, durationSeconds: 5)
        let (typing, speech) = acc.densities(windowSeconds: 0)
        XCTAssertEqual(typing, 0)
        XCTAssertEqual(speech, 0)
    }

    func testNonPositiveDurationIgnored() {
        var acc = SoundLabelAccumulator()
        acc.ingest(identifier: "typing", confidence: 0.9, durationSeconds: 0)
        acc.ingest(identifier: "typing", confidence: 0.9, durationSeconds: -3)
        let (typing, _) = acc.densities(windowSeconds: 30)
        XCTAssertEqual(typing, 0, accuracy: 0.001)
    }
}
