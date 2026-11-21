import AVFoundation
import UIKit

/// 扫码提示音的音色：登记过的码是高而短的「嘀」；没登记过的码是另一种低音「嘟—嘟」，一听就知道要登记。
struct ScanTone: Equatable, Sendable {
    /// 频率（Hz）
    let frequency: Double
    /// 每一声多长（秒）
    let duration: TimeInterval
    /// 响几声
    let pulses: Int
    /// 两声之间停多久（秒）
    let gap: TimeInterval
    /// 音量（0…1）
    let amplitude: Float

    static let known = ScanTone(frequency: 2_700, duration: 0.09, pulses: 1, gap: 0, amplitude: 0.8)
    static let unknown = ScanTone(frequency: 440, duration: 0.16, pulses: 2, gap: 0.07, amplitude: 0.9)

    static func `for`(_ outcome: ScanOutcome) -> ScanTone? {
        switch outcome {
        case .known: .known
        case .unknown: .unknown
        case .ignored: nil
        }
    }

    var totalDuration: TimeInterval { duration * Double(pulses) + gap * Double(max(pulses - 1, 0)) }

    /// 生成单声道 PCM 采样（正弦波，每声首尾 5 ms 淡入淡出，避免「咔」声）
    func samples(sampleRate: Double) -> [Float] {
        let pulseCount = Int(duration * sampleRate)
        let gapCount = Int(gap * sampleRate)
        let fade = max(1, Int(0.005 * sampleRate))
        var out: [Float] = []
        out.reserveCapacity(pulseCount * pulses + gapCount * max(pulses - 1, 0))
        for p in 0..<pulses {
            for i in 0..<pulseCount {
                let env = Float(min(1, Double(min(i, pulseCount - 1 - i)) / Double(fade)))
                out.append(amplitude * env * Float(sin(2 * .pi * frequency * Double(i) / sampleRate)))
            }
            if p < pulses - 1 { out.append(contentsOf: repeatElement(0, count: gapCount)) }
        }
        return out
    }
}

/// 扫码后的提示音和触感。
///
/// 音频会话用 `.playback`：店里手机常开着静音开关，`.ambient` / `.soloAmbient` 会被静音开关压掉，`.playback` 不会。
/// 加 `.mixWithOthers`：店里放着的音乐不被打断。两种音事先生成好放在内存里，扫到时立刻播，打断上一声。
/// 引擎在建好时就预启动，第一声不慢。全 App 共用 `shared` 一个（一个音频引擎，§14 S14-3 ⑪），各页的 `ScanHub` 都用它。
@MainActor
final class ScanFeedback: ScanFeedbackPlaying {
    static let shared = ScanFeedback()

    static let category: AVAudioSession.Category = .playback
    static let options: AVAudioSession.CategoryOptions = [.mixWithOthers]

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var buffers: [ScanOutcome: AVAudioPCMBuffer] = [:]
    private let success = UINotificationFeedbackGenerator()

    init() {
        Self.configureSession()
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        for outcome in [ScanOutcome.known, .unknown] {
            if let tone = ScanTone.for(outcome) { buffers[outcome] = Self.buffer(tone, format: format) }
        }
        success.prepare()
        engine.prepare()
        engineStartedAtInit = (try? engine.start()) != nil
    }

    /// 建好时引擎启动成功没有（测试读）
    private(set) var engineStartedAtInit = false
    /// 调了几次 `player.play()`（测试读）
    private(set) var playCalls = 0

    /// 把共享音频会话设成 `.playback`（静音开关下也响）
    @discardableResult
    static func configureSession(_ session: AVAudioSession = .sharedInstance()) -> Bool {
        do {
            try session.setCategory(category, mode: .default, options: options)
            try session.setActive(true)
            return true
        } catch {
            return false
        }
    }

    static func buffer(_ tone: ScanTone, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let samples = tone.samples(sampleRate: format.sampleRate)
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let ch = buf.floatChannelData?[0] else { return nil }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { ch.update(from: $0.baseAddress!, count: samples.count) }
        return buf
    }

    func play(_ outcome: ScanOutcome) {
        haptic(outcome)
        guard let buf = buffers[outcome] else { return }
        // 来电、闹钟打断或换了输出设备后引擎会停：播放前发现没在跑就重新设会话、重新启动
        if !engine.isRunning {
            Self.configureSession()
            do { try engine.start() } catch { return }
        }
        player.scheduleBuffer(buf, at: nil, options: .interrupts)
        // 打断恢复后 isPlaying 可能不准：每次都 play()（已在播时是空操作）
        player.play()
        playCalls += 1
    }

    /// 触感：登记过的码是「成功」，没登记过的码是「警告」（和低音一起，手上也能分出来），不收码时没有
    static func haptic(for outcome: ScanOutcome) -> UINotificationFeedbackGenerator.FeedbackType? {
        switch outcome {
        case .known: .success
        case .unknown: .warning
        case .ignored: nil
        }
    }

    /// 最近一次出的触感（测试读）
    private(set) var lastHaptic: UINotificationFeedbackGenerator.FeedbackType?

    private func haptic(_ outcome: ScanOutcome) {
        guard let type = Self.haptic(for: outcome) else { return }
        success.notificationOccurred(type)
        lastHaptic = type
        success.prepare()
    }
}
