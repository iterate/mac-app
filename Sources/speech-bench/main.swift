import AVFoundation
import Foundation
import SpeechText
import VoiceMeetCore

// speech-bench: one model's recognizer on sound files, as the app runs it (README, "Developing").
// Local only: `harness/speech-bench/run.mjs` runs it for each model and compares.
//
//   speech-bench --model <id> [--words <words.md>] [--fast] <file> …
//
// Each file goes through the same recognizer as a capture's pushed buffers, with their times, at the pace of the
// clock (`--fast`: at once). stdout is one JSON line for the load,
// `{ model, loadSeconds, warmSeconds, wasOnDisk }`, and one for each file:
// `{ file, seconds, segments: [{ t, to, text }], partials: [{ t, text }], finalAfterEnd }` (t and to in milliseconds),
// where `finalAfterEnd` is the seconds from the end of the sound to the last segment, and a partial's `t` is its time
// from the first sample pushed. `loadSeconds` is the first load in this process (what each start of the app costs);
// `warmSeconds` is a second engine for the held model (what each dictation costs). Nothing leaves this Mac.

var arguments = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    defer { arguments.removeSubrange(index...index + 1) }
    return arguments[index + 1]
}
let fast = arguments.contains("--fast")
arguments.removeAll { $0 == "--fast" }
let modelId = option("--model")
let words = option("--words").flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }.map(WordList.init(markdown:)) ?? .empty
guard let model = SpeechModel.local.first(where: { $0.id == modelId }) else {
    FileHandle.standardError.write(Data("speech-bench --model <\(SpeechModel.local.map(\.id).joined(separator: "|"))> [--words words.md] [--fast] <file> …\n".utf8))
    exit(2)
}

func say(_ line: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
    fflush(stdout)
}

let wasOnDisk = model.isOnDisk
let loadStarted = Date()
// the load alone, as the app's preload does: a recognizer then starts at once
let engine: SpeechEngine
do {
    engine = try await SpeechModels.shared.engine(model, words: words) { load in
        if case .downloading(let part) = load { FileHandle.standardError.write(Data("\r\(model.id): \(Int(part * 100))%".utf8)) }
    }
} catch {
    say(["model": model.id, "failed": error.localizedDescription])
    exit(1)
}
let loadSeconds = Date().timeIntervalSince(loadStarted)
// a second engine for the held model: what a dictation costs once the app has loaded it
let warmStarted = Date()
_ = try? await SpeechModels.shared.engine(model, words: words)
say(["model": model.id, "loadSeconds": loadSeconds, "warmSeconds": Date().timeIntervalSince(warmStarted), "wasOnDisk": wasOnDisk])

/// The partials of the file that is heard now, with their time from its first sample.
final class Partials: @unchecked Sendable {
    private let lock = NSLock()
    private var started = Date()
    private var list: [[String: Any]] = []
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        started = Date()
        list = []
    }
    func add(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        list.append(["t": Int(Date().timeIntervalSince(started) * 1000), "text": text])
    }
    var all: [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return list
    }
}
let partials = Partials()

for path in arguments {
    let audio = SpeechAudio()
    guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)),
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
    else {
        say(["file": path, "failed": "does not read"])
        continue
    }
    try file.read(into: buffer)
    let samples = audio.samples(of: buffer)
    let recognizer = SpeechRecognizer(model: model, words: words, engine: { engine }) { event in
        if case .partial(let said) = event, !said.text.isEmpty { partials.add(said.text) }
    }
    partials.reset()
    recognizer.start()
    // pieces of 0.1 s, at the clock's pace
    let piece = SpeechStretch.rate / 10
    var at = 0
    let started = Date()
    while at < samples.count {
        // stamped with their time, as a capture's buffers are
        recognizer.push(Array(samples[at..<min(at + piece, samples.count)]), at: Double(at) / Double(SpeechStretch.rate))
        at += piece
        if !fast {
            let due = started.addingTimeInterval(Double(at) / Double(SpeechStretch.rate))
            if due > Date() { try? await Task.sleep(nanoseconds: UInt64(due.timeIntervalSinceNow * 1e9)) }
        }
    }
    let ended = Date()
    let segments = await recognizer.finish()
    say([
        "file": path, "seconds": Double(samples.count) / Double(SpeechStretch.rate), "finalAfterEnd": Date().timeIntervalSince(ended),
        "segments": segments.map { ["t": Int($0.start * 1000), "to": Int($0.end * 1000), "text": $0.text] as [String: Any] },
        "partials": partials.all,
    ])
}
