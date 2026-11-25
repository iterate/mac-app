import Foundation
import VoiceMeetCore

/// A MODEL THAT HEARS THE WHOLE STRETCH AT EACH PASS, paced (README, "Dictation"). Oruk Fourier has
/// no partial text of its own: the recognizer asks for the growing stretch again and again (each
/// 0.4 s), and each pass costs the model the whole stretch. So a partial pass runs at most once in
/// `interval` (1 s), and never sooner than twice the last pass's time after its start: a slow pass
/// (a long stretch, a busy GPU) gets room, and the GPU works at most half the time for the pill.
/// Between passes, a partial is the last one's text while the stretch is the same, else nothing
/// new (empty: the pill keeps what was said). A final pass always runs, at once.
///
/// Measured on 25 Nov 2026 (M4 Max, MLX 8-bit): a pass took 0.08 s for 1 s of speech, 0.15 s for
/// 4 s, 0.38 s for 10 s and 0.45 s for 12 s, so a partial each second fits.
public final class PacedEngine: SpeechEngine, @unchecked Sendable {
    public static let interval = 1.0
    /// The first samples of a stretch, which say whether a pass is of the same stretch.
    static let key = SpeechStretch.rate / 10

    private let engine: SpeechEngine
    private let interval: Double
    private let now: @Sendable () -> Double
    private let lock = NSLock()
    /// When the next partial pass may run.
    private var next = -Double.infinity
    /// The last partial pass: its stretch's first samples and its text.
    private var last: (key: [Float], heard: Heard)?
    private var passes = 0

    /// `now` is a clock in seconds, for a test.
    public init(_ engine: SpeechEngine, interval: Double = PacedEngine.interval, now: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.engine = engine
        self.interval = interval
        self.now = now
    }

    /// The passes that ran, partial and final.
    public var ranPasses: Int { lock.withLock { passes } }

    public func hear(_ samples: [Float], final: Bool) async throws -> Heard {
        let key = Array(samples.prefix(Self.key))
        if !final {
            let early: Heard? = lock.withLock {
                guard now() < next else { return nil }
                guard let last, last.key == key else { return Heard(text: "") }
                return last.heard
            }
            if let early { return early }
        }
        let started = now()
        lock.withLock {
            passes += 1
            // a second caller in the same moment waits for the next turn
            next = max(next, started + interval)
        }
        let heard = try await engine.hear(samples, final: final)
        let took = now() - started
        lock.withLock {
            next = max(next, started + max(interval, 2 * took))
            last = final ? nil : (key, heard)
        }
        return heard
    }
}
