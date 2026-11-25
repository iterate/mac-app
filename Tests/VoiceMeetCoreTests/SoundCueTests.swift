import VoiceMeetCore
import XCTest

/// The gentle sounds: short, quiet, no click, and none from a test copy.
final class SoundCueTests: XCTestCase {
    func testEachCueIsShortQuietAndHasNoClick() {
        for cue in SoundCue.allCases {
            let samples = cue.samples
            XCTAssert(Double(samples.count) / SoundCue.sampleRate < 0.15, "\(cue) is too long")
            let peak = samples.map(abs).max() ?? 0
            // with the player's volume: a tenth of full scale or less
            XCTAssert(peak * SoundCue.playerVolume <= 0.1, "\(cue) is too loud")
            // it starts and ends in silence
            XCTAssert(abs(samples.first ?? 1) < 0.001 && abs(samples.last ?? 1) < 0.001, "\(cue) clicks at an edge")
            // no step between two samples bigger than a sine of the peak can make at the top frequency
            let steps = zip(samples, samples.dropFirst()).map { abs($1 - $0) }
            XCTAssert((steps.max() ?? 1) < Float(cue.peak) * 0.12, "\(cue) has a step")
            // the soft attack: after 2 ms it is still below half its peak
            let early = samples.prefix(Int(0.002 * SoundCue.sampleRate)).map(abs).max() ?? 1
            XCTAssert(early < peak / 2, "\(cue) rises too fast")
        }
        // the written sound and the cancel are softer than the start
        XCTAssert(SoundCue.written.peak < SoundCue.start.peak && SoundCue.cancelled.peak < SoundCue.written.peak)
    }

    func testTheWAVHasItsSamples() {
        let wav = SoundCue.start.wav
        XCTAssert(wav.count == 44 + SoundCue.start.samples.count * 2)
        XCTAssert(String(decoding: wav.prefix(4), as: UTF8.self) == "RIFF")
    }

    func testATestCopyMakesNoSound() {
        var cues = SoundCues()
        for cue in SoundCue.allCases {
            XCTAssert(!cues.sounds(cue, isOn: true, mayMakeSound: false))
            XCTAssert(!cues.sounds(cue, isOn: false, mayMakeSound: false))
        }
        XCTAssert(cues.played == 0 && cues.silenced == 6 && cues.off == 0)
        XCTAssert(!cues.sounds(.start, isOn: false, mayMakeSound: true))
        XCTAssert(cues.sounds(.start, isOn: true, mayMakeSound: true))
        XCTAssert(cues.played == 1 && cues.off == 1)
    }
}
