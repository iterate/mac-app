import AVFoundation
import CoreVideo
import Foundation

/// The camera's change rule: a frame is kept when the picture changed since the last frame kept,
/// and at least once a second. "Changed" is the mean absolute difference of a 32×18 copy of the
/// luma, in 8-bit levels.
///
/// The threshold was measured on 25 Nov 2026 on four camera slots of the owner's Mac (720p, decoded
/// from the record's HEVC, so with less sensor noise than a raw frame): a still room gave 0.00–0.5
/// between frames (p99 0.34), the owner sitting and talking 0.5 (median), a head turn or a hand
/// 2–44. Not measured: raw frames in a dark room, where noise is highest.
public enum CameraChange {
    public static let columns = 32, rows = 18
    /// Mean absolute luma difference, in levels of 0–255, at which a frame counts as changed.
    public static let threshold: Float = 1.5
    /// At most this long between kept frames, also of a still picture.
    public static let maxGap = 1.0
    /// A frame comes up to 4 ms early (`CaptureRate.slack`): the 15th frame after a kept one is kept.
    static let slack = 0.004

    /// Whether a frame at `now` (seconds) with the copy `thumb` is kept, after the last kept one.
    /// A frame from before the last one (a clock that went back) is kept.
    public static func keeps(last: (time: Double, thumb: [Float]?)?, now: Double, thumb: [Float]?) -> Bool {
        guard let last, now >= last.time, now - last.time < maxGap - slack else { return true }
        guard let thumb, let before = last.thumb, thumb.count == before.count else { return true }
        return difference(thumb, before) >= threshold
    }

    /// The mean absolute difference of two copies.
    public static func difference(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return .infinity }
        var sum: Float = 0
        for i in a.indices { sum += abs(a[i] - b[i]) }
        return sum / Float(a.count)
    }

    /// The 32×18 copy of a luma plane: in each cell, the mean of every 4th pixel each way. Nil for
    /// a plane smaller than the grid.
    public static func thumbnail(luma: UnsafePointer<UInt8>, width: Int, height: Int, bytesPerRow: Int) -> [Float]? {
        guard width >= columns * 4, height >= rows * 4 else { return nil }
        var out = [Float](repeating: 0, count: columns * rows)
        for row in 0..<rows {
            let y0 = row * height / rows, y1 = (row + 1) * height / rows
            for column in 0..<columns {
                let x0 = column * width / columns, x1 = (column + 1) * width / columns
                var sum = 0, count = 0
                var y = y0 + 2
                while y < y1 {
                    let line = luma + y * bytesPerRow
                    var x = x0 + 2
                    while x < x1 {
                        sum += Int(line[x])
                        count += 1
                        x += 4
                    }
                    y += 4
                }
                out[row * columns + column] = Float(sum) / Float(max(1, count))
            }
        }
        return out
    }

    /// The copy of a camera frame's luma (plane 0 of a bi-planar 4:2:0 buffer). Nil for another
    /// format: such a frame is kept by the frame rate alone.
    static func thumbnail(_ frame: CVPixelBuffer) -> [Float]? {
        guard CVPixelBufferIsPlanar(frame), CVPixelBufferGetPlaneCount(frame) == 2 else { return nil }
        guard CVPixelBufferLockBaseAddress(frame, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(frame, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(frame, 0) else { return nil }
        return thumbnail(
            luma: base.assumingMemoryBound(to: UInt8.self), width: CVPixelBufferGetWidthOfPlane(frame, 0),
            height: CVPixelBufferGetHeightOfPlane(frame, 0), bytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(frame, 0))
    }
}

/// When an audio track records sound and when it writes silence that costs nothing (`AudioTrack`).
/// The gate opens for a window of 20 ms whose RMS is at or above the threshold, and stays open
/// `hold` samples after the end of the last such window, so that the ends of words are kept. (The
/// track also starts its encoder 250 ms before the window that opened the gate, from what it keeps.)
///
/// The microphone's threshold, −50 dBFS, was measured on 25 Nov 2026 on five 30 s slots of the
/// owner's microphone (`mic-0`): speech had a 20 ms RMS of −46 dBFS (median) and −39 (p75), and the
/// gate was open for 93% of that slot; a quiet room had −68 (median) and −56 (p99), open 4% (single
/// sounds); typing had −60 (median) and −47 (p99), open 24%. The speakers' threshold is −70 dBFS:
/// what the Mac plays is digital, and its silence is zeros (−120 in every speaker slot measured).
public struct SoundGate: Equatable {
    public static let microphoneDB: Float = -50
    public static let speakersDB: Float = -70
    /// 20 ms at 48 kHz.
    public static let window = 960
    /// 0.5 s at 48 kHz.
    public static let hold: Int64 = 24_000

    /// The threshold as a mean square.
    public let threshold: Float
    /// The gate is open for samples before this one.
    public private(set) var openUntil: Int64 = .min

    public init(dB: Float) { threshold = pow(10, dB / 10) }

    /// A window of `count` samples from sample `from`, with the mean square of its samples: whether
    /// the gate is open for it.
    public mutating func take(meanSquare: Float, from: Int64, count: Int) -> Bool {
        if meanSquare >= threshold { openUntil = from + Int64(count) + SoundGate.hold }
        return from < openUntil
    }

    /// Whether the gate is open for sample `position`.
    public func isOpen(at position: Int64) -> Bool { position < openUntil }

    /// Closed: a new run of the track.
    public mutating func reset() { openUntil = .min }
}

/// One AAC packet of silence in the track's format, made by the same encoder from zeros. A track
/// writes it for each 1024 samples of silence; the decoder makes zeros of it.
enum SilentPacket {
    private static let lock = NSLock()
    private static var made: [String: Data] = [:]

    static func of(channels: Int, bitrate: Int) -> Data {
        let key = "\(channels)/\(bitrate)"
        return lock.withLock {
            if let data = made[key] { return data }
            let data = encode(channels: channels, bitrate: bitrate)
            made[key] = data
            return data
        }
    }

    /// The packets of 16 × 1024 zeros; the 8th, which the encoder's priming does not touch.
    private static func encode(channels: Int, bitrate: Int) -> Data {
        let pcm = AVAudioFormat(standardFormatWithSampleRate: AudioTrack.rate, channels: AVAudioChannelCount(channels))!
        let aac = AVAudioFormat(settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: AudioTrack.rate, AVNumberOfChannelsKey: channels])!
        let encoder = AVAudioConverter(from: pcm, to: aac)!
        encoder.bitRate = bitrate
        let zeros = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: 16 * 1024)!
        zeros.frameLength = 16 * 1024
        let out = AVAudioCompressedBuffer(format: aac, packetCapacity: 32, maximumPacketSize: max(1, encoder.maximumOutputPacketSize))
        var given = false, packets: [Data] = []
        while true {
            let status = encoder.convert(to: out, error: nil) { _, status in
                if given {
                    status.pointee = .endOfStream
                    return nil
                }
                given = true
                status.pointee = .haveData
                return zeros
            }
            for i in 0..<Int(out.packetCount) {
                guard let d = out.packetDescriptions?[i] else { continue }
                packets.append(Data(bytes: out.data + Int(d.mStartOffset), count: Int(d.mDataByteSize)))
            }
            if out.packetCount == 0 || status == .error || status == .endOfStream { break }
        }
        return packets.count > 8 ? packets[8] : packets.last ?? Data()
    }
}
