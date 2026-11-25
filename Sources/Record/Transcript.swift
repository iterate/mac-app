import AVFoundation
import CoreMedia
import Foundation

/// THE TRANSCRIPT TRACK (README, "Listening"): the final segments of the transcription stream, one
/// JSON line each, as `transcript/<YYYY-MM-DD>/<HH>/<MM>-<SS>.jsonl` beside the other tracks of
/// the slot. A line goes into the slot in which it came (a segment's own times are in it): a slot
/// with no line has no file. The slot's file closes a second after the slot's end.
final class TranscriptTrack: Track {
    static let name = "transcript"
    let id = TranscriptTrack.name
    private let r: Recorder
    private let queue = DispatchQueue(label: "track.transcript")
    private var slot: Int64?
    private var lines: [Data] = []

    init(recorder: Recorder) {
        r = recorder
        recorder.add(self)
    }

    func append(_ line: Data) {
        let now = nowMs()
        queue.async { [self] in
            let at = Slot.start(now)
            if slot != at {
                close()
                guard r.opening(track: id, slot: at) else { return log("transcript: slot \(at) is sealed; a line is dropped") }
                slot = at
            }
            lines.append(line)
        }
    }

    func tick() {
        let now = nowMs()
        queue.async { [self] in
            if let slot, now >= Double(slot + Slot.ms + 1000) { close() }
        }
    }

    func stop() { queue.sync { close() } }

    /// On `queue`: the slot's lines into its file, and its entry in the slot's event.
    private func close() {
        guard let slot else { return }
        let parts = lines
        self.slot = nil
        lines = []
        r.finished(
            track: id, slot: slot, parts: parts, size: parts.reduce(0) { $0 + $1.count }, entry: ["kind": "transcript", "codec": "jsonl", "segments": parts.count],
            picture: nil, ext: "jsonl")
    }
}

/// The source behind the transcript: its track, and nothing to capture. Its lines come from the app
/// (`Recorder.transcribed`).
final class TranscriptSource: Source {
    private let r: Recorder

    init(recorder: Recorder) { r = recorder }

    func start() {
        if r.track(TranscriptTrack.name) == nil { _ = TranscriptTrack(recorder: r) }
        log("transcript: on")
    }

    func stop() {}
}

/// THE MICROPHONE STREAM, for the record's `mic-0` (README, "Listening"): the app's one owner of the
/// input device gives its buffers, so the record opens no microphone of its own. Without a feed
/// (`record-run`) the record opens each microphone itself (`DeviceCapture`).
public protocol MicrophoneFeed: AnyObject, Sendable {
    /// Starts to give the input's buffers, each with the host time of its first frame, and answers
    /// the input's name and the close. Throws the reason when the record must not open it.
    func open(_ take: @escaping @Sendable (AVAudioPCMBuffer, UInt64) -> Void, failed: @escaping @Sendable (String) -> Void) throws
        -> (name: String, close: @Sendable () -> Void)
}

/// `mic-0` from the feed: each buffer as a mono sample buffer of 32-bit floats at the input's rate,
/// its channel 0, with its host time; the track encodes it as it does a capture's.
final class FeedMic: Source, @unchecked Sendable {
    static let track = "mic-0"
    private let r: Recorder
    private let feed: MicrophoneFeed
    private var close: (@Sendable () -> Void)?
    private let lock = NSLock()
    /// The format of the last rate, made once.
    private var format: (rate: Double, description: CMAudioFormatDescription)?

    init(recorder: Recorder, feed: MicrophoneFeed) {
        r = recorder
        self.feed = feed
    }

    func start() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return log("mics: off, no Microphone permission") }
        do {
            let (name, close) = try feed.open({ [weak self] buffer, host in self?.take(buffer, host: host) }, failed: { reason in
                log("\(FeedMic.track): the microphone stream failed (\(reason)); the track waits for the next start")
            })
            if r.track(Self.track) == nil { _ = AudioTrack(id: Self.track, recorder: r, channels: 1, bitrate: 64_000, name: name) }
            lock.withLock { self.close = close }
            log("\(Self.track): \(name), from the microphone stream")
        } catch {
            log("mics: \(error.localizedDescription)")
        }
    }

    func stop() {
        lock.withLock {
            defer { close = nil }
            return close
        }?()
    }

    private func take(_ buffer: AVAudioPCMBuffer, host: UInt64) {
        guard let sample = sample(of: buffer, host: host) else { return }
        r.sound(Self.track, sample, hostTime: CMClockMakeHostTimeFromSystemUnits(host))
    }

    /// Channel 0 of `buffer` as a sample buffer that owns its bytes.
    func sample(of buffer: AVAudioPCMBuffer, host: UInt64) -> CMSampleBuffer? {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let channel = buffer.floatChannelData?[0], let description = description(rate: buffer.format.sampleRate) else { return nil }
        let bytes = frames * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
            let block, CMBlockBufferReplaceDataBytes(with: channel, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) == noErr
        else { return nil }
        var sample: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: description, sampleCount: frames,
            presentationTimeStamp: CMClockMakeHostTimeFromSystemUnits(host), packetDescriptions: nil, sampleBufferOut: &sample) == noErr
        else { return nil }
        return sample
    }

    private func description(rate: Double) -> CMAudioFormatDescription? {
        if let format, format.rate == rate { return format.description }
        var asbd = AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4,
            mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var made: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &made) == noErr, let made
        else { return nil }
        format = (rate, made)
        return made
    }
}
