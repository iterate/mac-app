// fluid-pro.swift: Fluid Speech Pro (FluidVoice-Labs/fluid-speech-pro-coreml, CC BY 4.0, a v3 fine-tune with one
// more encoder block) for the speech bench (engines/fluid-pro.mjs), through the FluidVoice fork of FluidAudio
// (altic-dev/FluidAudio, `.fluidParakeetPro`), which the app's FluidAudio 0.18.4 does not read right. The fork's
// own vocabulary boosting (the same Parakeet CTC 110M from FluidAudio's folder) hears the word list's terms.
// fluid-pro.mjs builds it in a throwaway package in ~/.cache/iterate-speech-bench; it is not part of the app.
//
//   fluid-pro-bench <model folder> <terms.json: [{term, wrong}]>    then one WAV path a line on stdin
//
// stdout: `{ loadSeconds, boosted }`, then `{ file, text, seconds }` for each path. Whole utterance at once.
import AVFoundation
import FluidAudio
import Foundation

struct Term: Decodable {
    let term: String
    let wrong: [String]
}

func say(_ line: [String: Any]) {
    print(String(decoding: try! JSONSerialization.data(withJSONObject: line), as: UTF8.self))
    fflush(stdout)
}

let arguments = CommandLine.arguments
let terms = try JSONDecoder().decode([Term].self, from: Data(contentsOf: URL(fileURLWithPath: arguments[2])))
let started = Date()
let models = try await AsrModels.load(from: URL(fileURLWithPath: arguments[1]), version: .fluidParakeetPro)
let manager = AsrManager(config: .default)
try await manager.initialize(models: models)
var boosted = false
if !terms.isEmpty, let ctc = try? await CtcModels.loadDirect(from: CtcModels.defaultCacheDirectory()) {
    let vocabulary = CustomVocabularyContext(terms: terms.map { CustomVocabularyTerm(text: $0.term, aliases: $0.wrong.isEmpty ? nil : $0.wrong) })
    try await manager.configureVocabularyBoosting(vocabulary: vocabulary, ctcModels: ctc)
    boosted = true
}
// a warm-up, as an app would do at its start
_ = try? await manager.transcribe([Float](repeating: 0, count: 16000))
say(["loadSeconds": Date().timeIntervalSince(started), "boosted": boosted])

while let line = readLine() {
    let path = line.trimmingCharacters(in: .whitespaces)
    guard !path.isEmpty else { continue }
    let heard = Date()
    do {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw NSError(domain: "fluid-pro", code: 1)
        }
        try file.read(into: buffer)
        let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        let result = try await manager.transcribe(samples)
        say(["file": path, "text": result.text, "seconds": Date().timeIntervalSince(heard)])
    } catch {
        say(["file": path, "error": "\(error)"])
    }
}
