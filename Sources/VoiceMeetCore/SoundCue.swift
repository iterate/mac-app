import Foundation

/// THE GENTLE SOUNDS OF A DICTATION (README, "Dictation"): one when the listening starts, a softer
/// one when the text is written, and a quiet low one for Esc. Pure, so that a test measures them.
///
/// Why tones made here and not a sound of macOS: measured from the files of
/// `/System/Library/Sounds` (25 November 2026), each is too long or too sharp. Tink is short (36 ms
/// that you hear) but reaches its peak in 2.6 ms, a click; Pop, Morse, Frog, Bottle and Purr ring
/// for 100 to 335 ms, and the rest longer. A sine with a soft envelope has no click: it rises in
/// `attack` along half a cosine, falls away, and is silent before 150 ms.
public enum SoundCue: String, CaseIterable, Sendable {
    /// The listening starts: a short rise, D5 to G5.
    case start
    /// The text is written: the same two notes falling, softer.
    case written
    /// Esc threw the sound away: lower, flat and quieter still.
    case cancelled

    public static let sampleRate = 44_100.0
    /// The rise from silence: long enough for no click, short enough to sound at once.
    public static let attack = 0.012
    /// A tenth of full scale or less: with the player's volume (`playerVolume`) it is well below
    /// an alert of macOS (Tink's peak is 0.36 of full scale).
    public static let playerVolume: Float = 0.5

    /// Seconds.
    public var duration: Double {
        switch self {
        case .start: 0.12
        case .written: 0.10
        case .cancelled: 0.09
        }
    }

    /// The tone's frequency at its start and at its end (Hz); between them it glides.
    var frequencies: (from: Double, to: Double) {
        switch self {
        case .start: (587.33, 783.99)
        case .written: (783.99, 587.33)
        case .cancelled: (392.0, 349.23)
        }
    }

    /// The peak of the samples, full scale being 1.
    public var peak: Double {
        switch self {
        case .start: 0.2
        case .written: 0.14
        case .cancelled: 0.12
        }
    }

    /// The tone as samples, mono, at `sampleRate`.
    public var samples: [Float] {
        let count = Int(duration * Self.sampleRate)
        let (from, to) = frequencies
        var phase = 0.0
        var samples = [Float](repeating: 0, count: count)
        for index in 0..<count {
            let time = Double(index) / Self.sampleRate
            let part = time / duration
            // half a cosine up in `attack`, then a fall to 0 at the end, steep at first
            let rise = time < Self.attack ? 0.5 - 0.5 * cos(.pi * time / Self.attack) : 1
            let fall = time < Self.attack ? 1 : pow(cos(.pi / 2 * (time - Self.attack) / (duration - Self.attack)), 3)
            phase += 2 * .pi * (from + (to - from) * part) / Self.sampleRate
            samples[index] = Float(peak * rise * fall * sin(phase))
        }
        return samples
    }

    /// The samples as a WAV file, 16-bit PCM, for `NSSound(data:)`.
    public var wav: Data {
        let pcm = samples.map { Int16(max(-1, min(1, $0)) * Float(Int16.max)) }
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(pcm.count * 2)
        data.append(contentsOf: Array("RIFF".utf8))
        append(36 + bytes)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))  // PCM
        append(UInt16(1))  // mono
        append(UInt32(Self.sampleRate))
        append(UInt32(Self.sampleRate) * 2)
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        append(bytes)
        for sample in pcm { append(sample) }
        return data
    }
}

/// WHETHER A CUE SOUNDS, and the counts that `ui.state` shows: a test copy and a drawing make no
/// sound, ever (the owner is at his Mac), and count each cue that a sound was kept from.
public struct SoundCues: Equatable, Sendable {
    /// Cues that made a sound.
    public private(set) var played = 0
    /// Cues that a home of its own, or a drawing, kept silent.
    public private(set) var silenced = 0
    /// Cues with Settings › Dictation, "Sounds", off.
    public private(set) var off = 0

    public init() {}

    /// Whether `cue` makes a sound now. `mayMakeSound`: false in a home of its own and in a drawing.
    public mutating func sounds(_ cue: SoundCue, isOn: Bool, mayMakeSound: Bool) -> Bool {
        guard mayMakeSound else {
            silenced += 1
            return false
        }
        guard isOn else {
            off += 1
            return false
        }
        played += 1
        return true
    }
}
