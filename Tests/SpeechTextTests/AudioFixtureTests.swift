import AVFoundation
import SpeechText
import VoiceMeetCore
import XCTest

/// The audio fixture: a sound file in place of the microphone (README, "Testing with no hand").
/// These tests need no speech model and open no audio device.
final class AudioFixtureTests: XCTestCase {
    /// Half a second of a 440 Hz tone at 44.1 kHz, mono, as a WAV file.
    private func tone() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fixture-\(UUID().uuidString).wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 22_050))
        buffer.frameLength = 22_050
        for frame in 0..<22_050 { buffer.floatChannelData![0][frame] = 0.3 * sin(2 * .pi * 440 * Float(frame) / 44_100) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    func testTheFileComesInPiecesAndThenSilence() throws {
        let url = try tone()
        defer { try? FileManager.default.removeItem(at: url) }
        let fixture = try AudioFixture(url)
        XCTAssertEqual(fixture.seconds, 0.5, accuracy: 0.001)
        var frames: AVAudioFrameCount = 0
        var loud = true
        while loud, let piece = fixture.next() {
            let samples = UnsafeBufferPointer(start: piece.floatChannelData![0], count: Int(piece.frameLength))
            loud = samples.contains { $0 != 0 }
            if loud { frames += piece.frameLength }
        }
        XCTAssertEqual(frames, 22_050)
        // the silence goes on for as long as it is asked
        let silence = try XCTUnwrap(fixture.next())
        XCTAssertEqual(silence.frameLength, AudioFixture.frames)
        XCTAssertTrue(UnsafeBufferPointer(start: silence.floatChannelData![0], count: Int(silence.frameLength)).allSatisfy { $0 == 0 })
    }

    func testAFixtureThatDoesNotReadFailsAtOnce() {
        XCTAssertThrowsError(try FixturePlayer(URL(fileURLWithPath: "/nonexistent/fixture.wav")).start { _ in }) { error in
            XCTAssertTrue(error.localizedDescription.contains("fixture.wav"))
        }
    }

    func testTheFixtureIsTheSourceWhenOneIsSet() throws {
        XCTAssertTrue(speechSource(fixture: try tone()) is FixturePlayer)
        XCTAssertTrue(speechSource(fixture: nil) is Microphone)
    }
}
