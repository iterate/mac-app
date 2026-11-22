import AVFoundation
import Foundation
import LiveKitWebRTC

/// The sound of a watch, as libwebrtc sees it: an audio device of our own that only sends.
/// libwebrtc opens no microphone and no speaker. Its model is PUSH: whoever has sound calls
/// `deliverRecordedData`, always from the same thread (RTCAudioDevice.h). The capture's buffers go
/// to one thread of ours (`put`), which turns them into 16-bit mono at 48 kHz and hands libwebrtc
/// each exact 10 ms block as soon as it is full. No timer: the capture's clock paces it.
final class SoundDevice: NSObject, LKRTCAudioDevice, @unchecked Sendable {
    static let rate = 48_000.0
    static let block = 480  // 10 ms

    private var delegate: LKRTCAudioDeviceDelegate?
    private let lock = NSLock()
    private var sending = false
    private let condition = NSCondition()
    private var waiting: [CMSampleBuffer] = []
    // Touched only by the push thread.
    private var pending = [Int16]()
    private var time = AudioTimeStamp()
    private let out = UnsafeMutablePointer<Int16>.allocate(capacity: SoundDevice.block)
    private let mono = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: SoundDevice.rate, channels: 1, interleaved: true)!
    private var converter: AVAudioConverter?

    override init() {
        super.init()
        time.mFlags = .sampleTimeValid
        let thread = Thread { [weak self] in while let self { self.next() } }
        thread.name = "live.sound"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// From the capture's callback: hand the buffer to the push thread. While nobody listens it is
    /// dropped. At most 50 wait (half a second or more): the oldest go.
    func put(_ sample: CMSampleBuffer) {
        guard lock.withLock({ sending }) else { return }
        condition.lock()
        waiting.append(sample)
        if waiting.count > 50 { waiting.removeFirst(waiting.count - 50) }
        condition.signal()
        condition.unlock()
    }

    /// On the push thread: the next buffers, as 10 ms blocks.
    private func next() {
        condition.lock()
        while waiting.isEmpty { condition.wait() }
        let samples = waiting
        waiting = []
        condition.unlock()
        for sample in samples { push(sample) }
    }

    private func push(_ sample: CMSampleBuffer) {
        guard let pcm = convert(sample), let data = pcm.int16ChannelData else { return }
        pending.append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(pcm.frameLength)))
        var used = 0
        while pending.count - used >= Self.block {
            pending.withUnsafeBufferPointer { _ = memcpy(out, $0.baseAddress! + used, Self.block * 2) }
            used += Self.block
            guard let deliver = lock.withLock({ sending ? delegate?.deliverRecordedData : nil }) else { continue }
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(Self.block * 2), mData: out))
            var flags = AudioUnitRenderActionFlags()
            _ = deliver(&flags, &time, 1, UInt32(Self.block), &list, nil, nil)
            time.mSampleTime += Double(Self.block)
        }
        pending.removeFirst(used)
    }

    /// The buffer as 16-bit mono at 48 kHz, whatever the capture gave: a microphone's own format,
    /// another rate, several channels (they are mixed).
    private func convert(_ sample: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = sample.formatDescription, sample.numSamples > 0 else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = AVAudioFrameCount(sample.numSamples)
        guard let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        source.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: source.mutableAudioBufferList) == noErr
        else { return nil }
        if converter?.inputFormat != format {
            converter = AVAudioConverter(from: format, to: mono)
            converter?.downmix = true
        }
        let capacity = AVAudioFrameCount(Double(frames) * Self.rate / format.sampleRate) + 64
        guard let converter, let result = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: capacity) else { return nil }
        var given = false
        _ = converter.convert(to: result, error: nil) { _, status in
            status.pointee = given ? .noDataNow : .haveData
            defer { given = true }
            return given ? nil : source
        }
        return result.frameLength > 0 ? result : nil
    }

    var deviceInputSampleRate: Double { Self.rate }
    var inputIOBufferDuration: TimeInterval { Double(Self.block) / Self.rate }
    var inputNumberOfChannels: Int { 1 }
    var inputLatency: TimeInterval { 0 }
    var deviceOutputSampleRate: Double { Self.rate }
    var outputIOBufferDuration: TimeInterval { Double(Self.block) / Self.rate }
    var outputNumberOfChannels: Int { 1 }
    var outputLatency: TimeInterval { 0 }
    var isInitialized: Bool { lock.withLock { delegate != nil } }
    var isPlayoutInitialized = false
    var isRecordingInitialized = false
    var isPlaying = false
    var isRecording: Bool { lock.withLock { sending } }

    func initialize(with delegate: LKRTCAudioDeviceDelegate) -> Bool {
        lock.withLock { self.delegate = delegate }
        return true
    }

    func terminateDevice() -> Bool {
        lock.withLock { (sending, delegate) = (false, nil) }
        return true
    }

    func initializePlayout() -> Bool { isPlayoutInitialized = true; return true }
    // the device only sends: nothing is pulled
    func startPlayout() -> Bool { isPlaying = true; return true }
    func stopPlayout() -> Bool { isPlaying = false; return true }
    func initializeRecording() -> Bool { isRecordingInitialized = true; return true }

    /// libwebrtc wants sound (a watcher has the sound track): from now on each block goes to it.
    func startRecording() -> Bool {
        lock.withLock { sending = delegate != nil }
        return true
    }

    func stopRecording() -> Bool {
        lock.withLock { sending = false }
        return true
    }
}
