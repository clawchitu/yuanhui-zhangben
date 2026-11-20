import AVFoundation
import XCTest
@testable import YuanhuiZhangben

/// S14：提示音用 `.playback` 音频会话（静音开关下也响）；没登记过的码用另一种低音。
/// 真机上静音开关拨下时确实响、触感确实有，留到 S29 真机验收。
@MainActor
final class ScanFeedbackTests: XCTestCase {
    func testSessionIsPlaybackSoTheSilentSwitchDoesNotMuteIt() {
        XCTAssertEqual(ScanFeedback.category, .playback)
        XCTAssertTrue(ScanFeedback.options.contains(.mixWithOthers), "不打断店里放的音乐")
        _ = ScanFeedback()
        XCTAssertEqual(AVAudioSession.sharedInstance().category, .playback)
        XCTAssertTrue(AVAudioSession.sharedInstance().categoryOptions.contains(.mixWithOthers))
    }

    /// 数过零点估频率
    private func estimatedFrequency(_ s: [Float], rate: Double) -> Double {
        var crossings = 0
        for i in 1..<s.count where (s[i - 1] < 0) != (s[i] < 0) { crossings += 1 }
        return Double(crossings) / 2 / (Double(s.count) / rate)
    }

    func testUnknownToneIsLowerAndDifferentFromKnown() {
        let rate = 44_100.0
        XCTAssertNotEqual(ScanTone.known, ScanTone.unknown)
        XCTAssertLessThan(ScanTone.unknown.frequency * 3, ScanTone.known.frequency, "低音明显低")
        XCTAssertEqual(ScanTone.for(.known), .known)
        XCTAssertEqual(ScanTone.for(.unknown), .unknown)
        XCTAssertNil(ScanTone.for(.ignored))

        let known = ScanTone.known.samples(sampleRate: rate)
        XCTAssertEqual(estimatedFrequency(known, rate: rate), ScanTone.known.frequency, accuracy: 60)
        XCTAssertEqual(Double(known.count) / rate, ScanTone.known.totalDuration, accuracy: 0.002)

        // 低音两声：只取第一声估频率；中间有一段静音
        let unknown = ScanTone.unknown.samples(sampleRate: rate)
        let first = Array(unknown.prefix(Int(ScanTone.unknown.duration * rate)))
        XCTAssertEqual(estimatedFrequency(first, rate: rate), ScanTone.unknown.frequency, accuracy: 20)
        XCTAssertEqual(Double(unknown.count) / rate, ScanTone.unknown.totalDuration, accuracy: 0.002)
        let gapStart = first.count + 10
        XCTAssertTrue(unknown[gapStart..<(gapStart + 100)].allSatisfy { $0 == 0 })
        XCTAssertGreaterThan(ScanTone.unknown.totalDuration, ScanTone.known.totalDuration * 3, "低音更长，一听就不同")
    }

    func testSamplesFadeInAndOutAndStayInRange() {
        for tone in [ScanTone.known, .unknown] {
            let s = tone.samples(sampleRate: 44_100)
            XCTAssertEqual(s.first ?? 1, 0, accuracy: 0.001)
            XCTAssertEqual(s.last ?? 1, 0, accuracy: 0.05)
            XCTAssertLessThanOrEqual(s.map(abs).max() ?? 2, 1)
        }
    }

    func testBuffersAreBuiltAndPlayingDoesNotThrow() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let buf = try XCTUnwrap(ScanFeedback.buffer(.unknown, format: format))
        XCTAssertEqual(Int(buf.frameLength), ScanTone.unknown.samples(sampleRate: 44_100).count)
        let fb = ScanFeedback()
        fb.play(.known)
        fb.play(.unknown)
        fb.play(.ignored)
    }
}
