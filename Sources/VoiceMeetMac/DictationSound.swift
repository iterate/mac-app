import AppKit
import VoiceMeetCore

/// PLAYS THE GENTLE SOUNDS of a dictation and of the input bar's microphone (`SoundCue`), when
/// Settings › Dictation, "Sounds", is on (`Choices.sounds`).
///
/// A copy with a home of its own and a drawing make no sound, ever: they make no `NSSound` at all,
/// and count each cue in `ui.state` (`sounds.silenced`), so that a harness run proves it.
///
/// `NSSound` plays on the output device on a thread of its own: `play()` returns at once, so the
/// microphone, which the caller opens first, is not held up. The microphone does hear the start
/// tone through the speakers, at a tenth of full scale for 120 ms; with a recording that has it at
/// its start, Parakeet v3 wrote the same words (README, "Dictation").
@MainActor
final class DictationSound {
    static let shared = DictationSound()

    private(set) var cues = SoundCues()
    private let mayMakeSound = !AppEnvironment.current.hasOwnHome && !AppEnvironment.current.isRendering
    private var sounds: [SoundCue: NSSound] = [:]

    func play(_ cue: SoundCue) {
        guard cues.sounds(cue, isOn: Choices.shared.sounds, mayMakeSound: mayMakeSound) else { return }
        let sound = sounds[cue] ?? NSSound(data: cue.wav)
        guard let sound else { return }
        sounds[cue] = sound
        sound.volume = SoundCue.playerVolume
        if sound.isPlaying { sound.stop() }
        sound.play()
    }

    /// For `ui.state` on the control socket.
    func controlState() -> [String: Any] {
        ["played": cues.played, "silenced": cues.silenced, "off": cues.off]
    }
}
