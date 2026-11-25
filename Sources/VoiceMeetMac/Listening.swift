import AVFoundation
import Foundation
import Record
import SpeechText
import VoiceMeetCore

/// THE LISTENING LAYERS in the app (README, "Listening"): the transcription stream's final segments
/// (`Transcript`), Always listen (`StretchListener`, off unless Settings › Dictation turns it on),
/// and what the features ask of what was said.
///
/// 1. The microphone stream (`MicStream.shared`) is the one owner of the input. `SpeechSession`
///    (dictation, the input bar), Always listen and the record's `mic-0` (`StreamFeed`) read it.
/// 2. Speech detection runs only for Always listen: a key says itself when speech starts.
/// 3. The transcription stream: `heard` takes each partial and segment, of the session and of Always
///    listen. A final segment is kept here and goes to the record's `transcript` track.
/// 4. The features read it: a dictation's text is the words of its stretch between its key's down
///    and up (`said`). Each stretch of Always listen goes into the history (`History`), where
///    "Paste the last transcript" (⌥⇧W) finds the newest of it and of the dictations.
@MainActor
final class Listening {
    /// False in a home of its own with no audio fixture: Always listen opens no microphone there.
    var mayOpenMicrophone = true
    /// The local model of Always listen: no sound leaves the Mac without a key.
    var localModel: () -> SpeechModel = { .default }
    /// The word list of the lent mind.
    var words: () -> WordList = { .empty }
    /// A final segment, as a line of the record's `transcript` track (`DeviceRecord.transcribed`).
    var record: (Data) -> Void = { _ in }
    /// Always listen started or stopped: the mark shows it.
    var onChange: () -> Void = {}

    private(set) var transcript = Transcript()
    private let log = AppLog("listening")
    private var listener: StretchListener?
    /// For `ui.state`: what Always listen found since its start.
    private var stretches = 0
    private var segments = 0
    private var isSpeaking = false
    private var keyListens = false
    /// The history's entry of the last stretch of Always listen: its next segment replaces it.
    private var stretchEntry: (stretch: String, entry: TranscriptEntry)?

    /// Always listen runs: the microphone is open with no key.
    var isAlwaysListening: Bool { listener != nil }

    /// One event of the transcription stream, of a key's listening or of Always listen.
    func heard(_ event: TranscriptEvent) {
        guard case .segment(let segment) = event else { return }
        transcript.add(segment)
        record(segment.line)
        if segment.origin == .listen {
            segments += 1
            keep(segment)
        }
    }

    /// A stretch of Always listen into the history: its first segment makes the entry, each next
    /// one makes it longer.
    private func keep(_ segment: TranscriptSegment) {
        var entry: TranscriptEntry
        if let last = stretchEntry, last.stretch == segment.stretch {
            entry = last.entry
            let start = entry.at - entry.seconds
            entry.text = Spoken.join(entry.text, segment.text)
            entry.at = max(entry.at, segment.end)
            entry.seconds = entry.at - start
        } else {
            entry = TranscriptEntry(kind: .stretch, outcome: .heard, at: segment.end, text: segment.text, model: segment.model, seconds: segment.end - segment.start)
        }
        guard !entry.text.isEmpty else { return }
        stretchEntry = (segment.stretch, entry)
        History.shared.add(entry)
    }

    /// The model that heard `stretch`, for the history.
    func model(of stretch: String) -> String? {
        transcript.segments.last { $0.stretch == stretch }?.model
    }

    /// The words of `stretch` said between two Unix times.
    func said(from: Double, to: Double, of stretch: String) -> String {
        transcript.words(from: from, to: to, of: stretch)
    }


    /// A key's listening started (`true`) or ended: Always listen holds meanwhile.
    func keyListening(_ isOn: Bool) {
        keyListens = isOn
        listener?.hold(isOn)
    }

    /// Always listen as Settings wants it: on only with the switch, a microphone this copy may
    /// open, and macOS's permission. The model and the word list are taken again each time.
    func apply() {
        let status = environmentFixture != nil ? .authorized : AVCaptureDevice.authorizationStatus(for: .audio)
        if Choices.shared.alwaysListen, mayOpenMicrophone, status == .notDetermined {
            // macOS asks the person now; a yes starts it
            AVCaptureDevice.requestAccess(for: .audio) { isGranted in
                if isGranted { DispatchQueue.main.async { MainActor.assumeIsolated { self.apply() } } }
            }
        }
        let wanted = Choices.shared.alwaysListen && mayOpenMicrophone && status == .authorized
        if wanted, let listener {
            return listener.use(localModel(), words: words())
        }
        guard wanted != isAlwaysListening else { return }
        if wanted { start() } else { stop() }
        onChange()
    }

    private func start() {
        let made = StretchListener(stream: .shared) { [weak self] event in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.listenerSaid(event) } }
        }
        made.use(localModel(), words: words())
        do {
            try made.start()
        } catch {
            return log.error("always listen: the microphone did not start: \(AppLog.describe(error))")
        }
        if keyListens { made.hold(true) }
        listener = made
        (stretches, segments) = (0, 0)
        log.info("always listen: on, with \(localModel().id); each stretch of speech is put into words on this Mac")
    }

    private func stop() {
        listener?.stop()
        listener = nil
        isSpeaking = false
        log.info("always listen: off")
    }

    private func listenerSaid(_ event: StretchListener.Event) {
        guard listener != nil else { return }
        switch event {
        case .started:
            isSpeaking = true
            // the stretch is put into words with the model and the word list of its end
            listener?.use(localModel(), words: words())
        case .ended:
            isSpeaking = false
            stretches += 1
        case .segment(let segment): heard(.segment(segment))
        case .note(let note): log.info("always listen: \(note)")
        }
    }

    /// For `ui.state`: counts and times, never the words, except the last stretch's text, which a
    /// test reads in its own copy.
    func controlState() -> [String: Any] {
        let last = transcript.lastStretch()
        return [
            "always": isAlwaysListening, "speaking": isSpeaking, "stretches": stretches, "listenSegments": segments,
            "segments": transcript.segments.count, "streamRunning": MicStream.shared.isRunning, "streamReaders": MicStream.shared.readers,
            "streamStarts": MicStream.shared.starts,
            "last": last.map { ["stretch": $0.stretch, "text": $0.text, "seconds": (($0.end - $0.start) * 10).rounded() / 10] as [String: Any] } ?? NSNull(),
        ]
    }
}

/// The record's `mic-0` from the microphone stream (`MicrophoneFeed`): no microphone of its own.
/// As before, a Bluetooth input is not opened for the record, and a home of its own opens none
/// unless an audio fixture is set (then the record hears the fixture).
final class StreamFeed: MicrophoneFeed, @unchecked Sendable {
    struct Refusal: LocalizedError {
        let errorDescription: String?
    }

    func open(_ take: @escaping @Sendable (AVAudioPCMBuffer, UInt64) -> Void, failed: @escaping @Sendable (String) -> Void) throws
        -> (name: String, close: @Sendable () -> Void)
    {
        var name = "the audio fixture"
        if environmentFixture == nil {
            guard !AppEnvironment.current.hasOwnHome else { throw Refusal(errorDescription: "a home of its own opens no microphone") }
            guard let input = AudioDevices.defaultInput() else { throw Refusal(errorDescription: "no input device") }
            guard !input.isBluetooth else {
                throw Refusal(errorDescription: "skipped \(input.name): Bluetooth, and opening it would move the headset to hands-free")
            }
            name = input.name
        }
        let subscription = try MicStream.shared.tapRaw(take, failed: failed)
        return (name, { subscription.cancel() })
    }
}
