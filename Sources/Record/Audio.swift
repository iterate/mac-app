import AVFoundation
import Accelerate
import CoreMedia
import Foundation

/// An audio track: PCM in, one AAC file per slot out. Times are samples at 48 kHz from Unix time
/// zero, on one grid of packets: packet `n` holds the sound from sample `origin + n × 1024 − 2112`,
/// and that is its time. A file starts with the first packet that begins in its slot.
///
/// Sound and silence (`SoundGate`): while the gate is open an AAC encoder runs; while it is closed,
/// no encoder runs and the track writes a silent packet (`SilentPacket`) for each 1024 samples, on
/// the same grid, so the file stays continuous and plays the same. The gate opens on a 20 ms window
/// over the threshold; the new encoder starts on the grid 250 ms before that window, from the
/// samples the track keeps (`recent`), and its first packets take the place of silent packets the
/// track has held back. It closes 0.5 s after the last such window: the encoder ends (its last
/// packets cover all it was given) and silence follows. A sound that starts within the ~50 ms that
/// the ended encoder's last packets cover loses that much of its start. The levels (`rms`, `peak`,
/// `levels`) are of every sample, encoded or not.
///
/// A run begins at the first sample: the grid's origin is 960 samples before it (zeros), so that a
/// packet begins exactly at it. Input follows host time through `Resync`; a new run only when host
/// time jumps forward by more than 250 ms while the encoder runs (a wake, a clock set). In
/// silence, a gap of up to a minute is silence, on the same grid.
///
/// `quiet()`: no input comes now (the speakers' capture stopped, as nothing plays). Each tick then
/// writes silence up to 300 ms before now, until the next input.
final class AudioTrack: Track {
    static let rate = 48_000.0
    static let perSlot = Int64(rate) * Slot.ms / 1000
    static let maxStep: Int64 = 12_000  // 250 ms
    /// The encoder starts this long before the window that opened the gate: 250 ms.
    static let preroll: Int64 = 12_000
    /// In silence, a gap in the input up to this long is silence on the same grid: a minute.
    static let maxFill: Int64 = 2_880_000
    /// While no input comes, silence is written up to this long before now: 300 ms.
    static let quietLag = 300.0
    let id: String
    private let r: Recorder
    private let queue: DispatchQueue
    private let pcm: AVAudioFormat
    private let aac: AVAudioFormat
    private let bitrate: Int
    private var resampler: AVAudioConverter?
    /// The capture's format, made once for each format description it sends (not for each buffer).
    private var captured: (description: CMFormatDescription, format: AVAudioFormat)?
    private var encoder: AVAudioConverter?
    private var output: AVAudioCompressedBuffer?  // the encoder's packets, used again for each call
    private var running = false  // a run's grid is set
    private var origin: Int64 = 0  // sample of the grid's packet 0 + 2112 (the encoder's first input)
    private var firstSlot: Int64 = 0  // slot of the run's first real sample
    private var fed: Int64 = 0  // samples since `origin` taken in, encoded or not
    private var packets: Int64 = 0  // packets since `origin` written
    private var input: [AVAudioPCMBuffer] = []
    /// The newest samples, up to `fed`: buffers, or a count of zeros. A new encoder starts from them.
    private var recent: [(buffer: AVAudioPCMBuffer?, count: Int)] = []
    private var recentCount = 0
    private var gate: SoundGate
    /// The 20 ms window of the gate that is not whole yet: its sum of squares and its samples.
    private var window: (squares: Float, count: Int) = (0, 0)
    /// The gate opened and the encoder waits for input from its first sample on the grid.
    private var opening = false
    private var isQuiet = false
    private let silence: Data
    private var counts = (encoded: 0, silent: 0, opens: 0)
    private var resynced = (added: 0, dropped: 0), rewound = false
    private var file: SlotFile?
    private var closed: Int64 = -1
    private var levels: [Int64: Level] = [:]
    private let header: Data
    private let info: [String: Any]

    init(id: String, recorder: Recorder, channels: Int, bitrate: Int, name: String? = nil, thresholdDB: Float = SoundGate.microphoneDB) {
        self.id = id
        r = recorder
        self.bitrate = bitrate
        queue = DispatchQueue(label: "track.\(id)")
        pcm = AVAudioFormat(standardFormatWithSampleRate: AudioTrack.rate, channels: AVAudioChannelCount(channels))!
        aac = AVAudioFormat(settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: AudioTrack.rate, AVNumberOfChannelsKey: channels])!
        header = FMP4.header(video: false, timescale: UInt32(AudioTrack.rate), entry: FMP4.aacEntry(rate: Int(AudioTrack.rate), channels: channels, bitrate: bitrate))
        info = ["kind": "audio", "codec": "mp4a.40.2", "rate": Int(AudioTrack.rate), "channels": channels].merging(name.map { ["name": $0] } ?? [:]) { a, _ in a }
        gate = SoundGate(dB: thresholdDB)
        silence = SilentPacket.of(channels: channels, bitrate: bitrate)
        recorder.add(self)
    }

    func append(_ sample: CMSampleBuffer, hostTime: CMTime) {
        let wall = r.clock.wallMs(hostTime: hostTime)
        queue.async { self.write(sample, wall: wall) }
    }

    /// No input comes now: the track writes silence by the clock until the next input.
    func quiet() {
        queue.async {
            self.isQuiet = true
            if self.encoder != nil { self.close() }
        }
    }

    private func write(_ sample: CMSampleBuffer, wall: Double) {
        guard var buffer = convert(sample) else { return }
        isQuiet = false
        let position = Int64((wall * AudioTrack.rate / 1000).rounded())
        if !running { startRun(at: position) }
        if case let jump = position - (origin + fed), jump > AudioTrack.maxStep {
            if encoder == nil, jump <= AudioTrack.maxFill {
                fill(Int(jump))
            } else {
                log("\(id): host time jumped \(jump / 48) ms ahead; new encoder")
                endRun()
                startRun(at: position)
            }
        }
        let drift = position - (origin + fed)
        let n = Int(buffer.frameLength)
        // Host time went back (a clock set): input is dropped until it reaches the sample count.
        rewound = rewound || drift < -AudioTrack.maxStep
        if rewound || (encoder == nil && drift < -Resync.tolerance) {
            guard -drift < n else { return resynced.dropped += n }
            let skip = Int(max(0, -drift))
            (rewound, buffer) = (false, skip > 0 ? remap(buffer, count: n - skip) { skip + $0 } : buffer)
            resynced.dropped += skip
        } else if encoder == nil, drift > Resync.tolerance {
            // In silence the gap is silence: exact, and nothing to stretch.
            fill(Int(drift))
        } else if case let change = Resync.change(drift: drift, count: n), change != 0 {
            let out = max(0, n + change)
            buffer = remap(buffer, count: out) { Resync.index($0, count: n, out: out) }
            if change > 0 { resynced.added += change } else { resynced.dropped -= change }
        }
        let start = fed
        let sound = measure(buffer)
        remember(buffer, count: Int(buffer.frameLength))
        fed += Int64(buffer.frameLength)
        if encoder != nil {
            if sound {
                input.append(buffer)
                drain(end: false)
            } else {
                close()
            }
        } else if sound || opening {
            open(at: start)
        } else {
            commitSilence(upTo: fed - AudioTrack.preroll)
        }
    }

    /// A copy of `buffer` of `count` samples, sample `i` the input sample `index(i)`. (The encoder
    /// holds the buffers it is given until it took them: each is a new one.)
    private func remap(_ buffer: AVAudioPCMBuffer, count: Int, index: (Int) -> Int) -> AVAudioPCMBuffer {
        guard let out = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: AVAudioFrameCount(max(1, count))),
            let from = buffer.floatChannelData, let to = out.floatChannelData
        else { return buffer }
        out.frameLength = AVAudioFrameCount(count)
        for c in 0..<Int(pcm.channelCount) {
            for i in 0..<count { to[c][i] = from[c][index(i)] }
        }
        return out
    }

    /// The sample buffer as float PCM at 48 kHz with the track's channels.
    private func convert(_ sample: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = sample.formatDescription else { return nil }
        if let captured, !CMFormatDescriptionEqual(captured.description, otherFormatDescription: description) { self.captured = nil }
        let format = captured?.format ?? AVAudioFormat(cmAudioFormatDescription: description)
        if captured == nil { captured = (description, format) }
        let frames = AVAudioFrameCount(sample.numSamples)
        guard frames > 0, let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        source.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: source.mutableAudioBufferList) == noErr
        else { return nil }
        if format == pcm { return source }
        if resampler?.inputFormat != format {
            resampler = AVAudioConverter(from: format, to: pcm)
            resampler?.downmix = true
        }
        let capacity = AVAudioFrameCount(Double(frames) * AudioTrack.rate / format.sampleRate) + 64
        guard let resampler, let out = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: capacity) else { return nil }
        var given = false
        _ = resampler.convert(to: out, error: nil) { _, status in
            if given {
                status.pointee = .noDataNow
                return nil
            }
            given = true
            status.pointee = .haveData
            return source
        }
        return out.frameLength > 0 ? out : nil
    }

    /// Adds the buffer's samples (nil: `count` zeros) to the level of the slot and the half second
    /// each one falls in, and runs the gate over its 20 ms windows: whether the gate is open for it.
    @discardableResult
    private func measure(_ buffer: AVAudioPCMBuffer?, count zeros: Int = 0) -> Bool {
        let data = buffer?.floatChannelData
        let n = buffer.map { Int($0.frameLength) } ?? zeros, channels = Int(pcm.channelCount)
        let half = AudioTrack.perSlot / Int64(Level.halves)
        let size = Int64(SoundGate.window)
        var i = 0
        while i < n {
            let position = origin + fed + Int64(i)
            let s = position / AudioTrack.perSlot * Slot.ms
            let index = Int(position % AudioTrack.perSlot / half)
            // Up to the end of this half second (never past the end of the slot), and of the gate's window.
            let stop = min(n, i + Int(half - position % half), i + Int(size - position % size))
            var sum: Float = 0, peak: Float = 0
            if let data {
                for c in 0..<channels {
                    var square: Float = 0, most: Float = 0
                    vDSP_svesq(data[c] + i, 1, &square, vDSP_Length(stop - i))
                    vDSP_maxmgv(data[c] + i, 1, &most, vDSP_Length(stop - i))
                    sum += square
                    peak = max(peak, most)
                }
            }
            levels[s, default: Level()].add(sum: Double(sum), count: (stop - i) * channels, peak: peak, half: index)
            window.squares += sum
            window.count += (stop - i) * channels
            let end = position + Int64(stop - i)
            if end % size == 0 {
                _ = gate.take(meanSquare: window.squares / Float(max(1, window.count)), from: end - size, count: Int(size))
                window = (0, 0)
            }
            i = stop
        }
        return gate.isOpen(at: origin + fed)
    }

    /// Keeps the newest samples, enough for a new encoder's start (`open`).
    private func remember(_ buffer: AVAudioPCMBuffer?, count: Int) {
        guard count > 0 else { return }
        recent.append((buffer, count))
        recentCount += count
        let keep = Int(AudioTrack.preroll) + 4 * 1024 + count
        while recentCount - recent[0].count >= keep {
            recentCount -= recent.removeFirst().count
        }
        if recentCount > keep, recent[0].buffer == nil {
            // zeros: shorten in place
            recent[0].count -= recentCount - keep
            recentCount = keep
        }
    }

    /// `count` samples of silence: a gap in the input, or the time while no input comes.
    private func fill(_ count: Int) {
        guard count > 0 else { return }
        measure(nil, count: count)
        remember(nil, count: count)
        fed += Int64(count)
    }

    /// A new run: its grid begins 960 samples (zeros) before `position`, no encoder yet.
    private func startRun(at position: Int64) {
        origin = position - 960
        firstSlot = Slot.start(Double(position) / 48)
        fed = 960
        packets = 0
        (recent, recentCount) = ([(nil, 960)], 960)
        (opening, running) = (false, true)
        gate.reset()
        window = (0, 0)
    }

    /// The run ends: the encoder's last packets, or silence up to the last sample.
    private func endRun() {
        guard running else { return }
        if encoder != nil { drain(end: true) }
        while packets * 1024 - 2112 < fed {
            packet(silence)
            counts.silent += 1
        }
        (running, opening, recent, recentCount, input) = (false, false, [], 0, [])
    }

    /// Writes held-back silent packets while the next one begins before sample `limit` − 2112
    /// (since `origin`): its time is no longer one a new encoder could take.
    private func commitSilence(upTo limit: Int64) {
        while packets * 1024 < limit - 1024 {
            packet(silence)
            counts.silent += 1
        }
    }

    /// The gate opened for the buffer that began at `start` (since `origin`): an encoder starts on
    /// the grid at least 250 ms before it, after the last packet written, from the samples kept.
    /// When that is past the input (the last encoder's packets reach further), it waits for input.
    private func open(at start: Int64) {
        let first = fed - Int64(recentCount)
        var m = max(packets, ceilDiv(start - AudioTrack.preroll, 1024))
        m = max(m, ceilDiv(first, 1024))
        guard m * 1024 < fed else { return opening = true }
        opening = false
        while packets < m {
            packet(silence)
            counts.silent += 1
        }
        let s = m * 1024
        let encoder = AVAudioConverter(from: pcm, to: aac)!
        encoder.bitRate = bitrate
        self.encoder = encoder
        output = AVAudioCompressedBuffer(format: aac, packetCapacity: 32, maximumPacketSize: max(1, encoder.maximumOutputPacketSize))
        counts.opens += 1
        // The kept samples from `s` on, as the encoder's first input.
        var at = first
        input = []
        for (buffer, count) in recent {
            defer { at += Int64(count) }
            guard at + Int64(count) > s else { continue }
            let skip = Int(max(0, s - at))
            if let buffer {
                input.append(skip > 0 ? remap(buffer, count: count - skip) { skip + $0 } : buffer)
            } else if let zeros = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: AVAudioFrameCount(count - skip)) {
                zeros.frameLength = AVAudioFrameCount(count - skip)
                for c in 0..<Int(pcm.channelCount) { zeros.floatChannelData![c].update(repeating: 0, count: count - skip) }
                input.append(zeros)
            }
        }
        // The grid moves to the new encoder: its packet 0 is the old grid's packet m.
        origin += s
        fed -= s
        packets = 0
        drain(end: false)
    }

    /// The gate closed: the encoder ends with what it was given, and silence follows.
    private func close() {
        drain(end: true)
        input = []
    }

    private func ceilDiv(_ a: Int64, _ b: Int64) -> Int64 { a >= 0 ? (a + b - 1) / b : -((-a) / b) }

    /// Takes every packet the encoder has ready (all of them at the end of an encoder).
    private func drain(end: Bool) {
        guard let encoder, let out = output else { return }
        while true {
            let status = encoder.convert(to: out, error: nil) { _, status in
                guard !self.input.isEmpty else {
                    status.pointee = end ? .endOfStream : .noDataNow
                    return nil
                }
                status.pointee = .haveData
                return self.input.removeFirst()
            }
            for i in 0..<Int(out.packetCount) {
                guard let d = out.packetDescriptions?[i] else { continue }
                packet(Data(bytes: out.data + Int(d.mStartOffset), count: Int(d.mDataByteSize)))
                counts.encoded += 1
            }
            if out.packetCount == 0 || status == .error || status == .endOfStream { break }
        }
        if end { self.encoder = nil }
    }

    private func packet(_ bytes: Data) {
        let begin = origin + packets * 1024 - 2112
        packets += 1
        let s = begin / AudioTrack.perSlot * Slot.ms
        // Priming that falls before the slot of the first sample, or a slot already written: dropped.
        guard s >= firstSlot, s > closed else { return }
        if let file, file.slot != s { finish() }
        if file == nil {
            guard r.opening(track: id, slot: s) else { return closed = s }
            file = SlotFile(slot: s, header: header)
        }
        guard let file else { return }
        let t = begin - s * AudioTrack.perSlot / Slot.ms
        guard t >= file.end else { return }
        file.append(bytes, at: t, duration: 1024, sync: true, newFragment: false)
    }

    private func finish() {
        guard let file else { return }
        self.file = nil
        closed = file.slot
        var entry = info
        if let level = levels[file.slot], level.count > 0 {
            entry["rms"] = level.rms
            entry["peak"] = level.peakDB
            entry["levels"] = level.levels
        }
        levels = levels.filter { $0.key > file.slot }
        let parts = file.close()
        r.finished(track: id, slot: file.slot, parts: parts, size: file.size, entry: entry, picture: nil)
    }

    func tick() {
        queue.async {
            if self.isQuiet, self.encoder == nil {
                let position = Int64(((nowMs() - AudioTrack.quietLag) * AudioTrack.rate / 1000).rounded())
                if !self.running { self.startRun(at: position) }
                let gap = position - (self.origin + self.fed)
                if gap > AudioTrack.maxFill {
                    self.endRun()
                    self.startRun(at: position)
                } else if gap > 0 {
                    self.fill(Int(gap))
                }
                self.commitSilence(upTo: self.fed - AudioTrack.preroll)
            }
            // Late enough for the encoder's delay and the capture's buffers.
            if let file = self.file, nowMs() >= Double(file.slot + Slot.ms) + 2000 { self.finish() }
        }
    }

    /// Packets written so far: by the encoder, as silence, and how often the encoder started.
    var written: (encoded: Int, silent: Int, opens: Int) { queue.sync { counts } }

    func stop() {
        queue.sync {
            endRun()
            finish()
            if resynced != (0, 0) { log("\(id): followed the clock by \(resynced.added) samples added, \(resynced.dropped) dropped") }
            let all = max(1, counts.encoded + counts.silent)
            log("\(id): \(counts.encoded) packets encoded, \(counts.silent) silent (\(100 * counts.silent / all)%), the encoder started \(counts.opens) times")
        }
    }
}
