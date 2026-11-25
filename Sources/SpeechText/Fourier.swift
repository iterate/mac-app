import Foundation
import VoiceMeetCore

/// ORUK FOURIER 2B, held for the app (README, "Dictation"): one Python process (`FourierSidecar`)
/// that loaded the model once and stays warm, with the files of `FourierRuntime`. Two steps, each
/// shared by its callers: the download (`prepare`, each caller hears its progress), then the
/// process's start. A process that ended is started again by the next caller. `letGo` ends the
/// process when another local model is held (one model is held at a time), but leaves a download
/// that goes on; `stopDownload` ends that.
public actor FourierModel {
    public static let shared = FourierModel(runtime: .standard)

    let runtime: FourierRuntime
    private var sidecar: FourierSidecar?
    private var downloading: Task<Void, Error>?
    private var starting: Task<FourierSidecar, Error>?
    private var listeners: [Int: @Sendable (SpeechLoad) -> Void] = [:]
    private var nextListener = 0
    private var latest = 0.0

    public init(runtime: FourierRuntime) {
        self.runtime = runtime
    }

    /// An engine for `words`: their terms go into the model's prompt.
    func engine(words: WordList, progress: @escaping @Sendable (SpeechLoad) -> Void = { _ in }) async throws -> SpeechEngine {
        FourierEngine(sidecar: try await load(progress: progress), hotwords: words.entries.map(\.term))
    }

    /// The process, ready: the files are got first when they are not on this Mac.
    @discardableResult
    func load(progress: @escaping @Sendable (SpeechLoad) -> Void = { _ in }) async throws -> FourierSidecar {
        if let sidecar, sidecar.isRunning { return sidecar }
        sidecar = nil
        try await prepare(progress: progress)
        progress(.loading)
        let runtime = runtime
        let task = starting ?? Task { try await FourierSidecar.start(runtime) }
        starting = task
        do {
            let ready = try await task.value
            // a `letGo` while it started: the caller has it, and no one holds it after
            if starting == task {
                starting = nil
                sidecar = ready
            }
            return ready
        } catch {
            if starting == task { starting = nil }
            throw error
        }
    }

    /// The files, got and checked when they are not on this Mac.
    func prepare(progress: @escaping @Sendable (SpeechLoad) -> Void = { _ in }) async throws {
        guard !runtime.isReady else { return }
        let id = nextListener
        nextListener += 1
        listeners[id] = progress
        defer { listeners[id] = nil }
        let task: Task<Void, Error>
        if let downloading {
            task = downloading
        } else {
            let runtime = runtime
            latest = 0
            task = Task { try await runtime.prepare { part in Task { await self.tell(part) } } }
            downloading = task
        }
        progress(.downloading(latest))
        do {
            try await task.value
            if downloading == task { downloading = nil }
        } catch {
            if downloading == task { downloading = nil }
            throw error
        }
    }

    /// The process ends once no engine holds it; a start that goes on is cancelled.
    public func letGo() {
        starting?.cancel()
        starting = nil
        sidecar = nil
    }

    /// A download that goes on stops; what came stays, and the next one goes on from there.
    public func stopDownload() {
        downloading?.cancel()
        downloading = nil
    }

    private func tell(_ part: Double) {
        // a share that only goes up: the reports may come out of order
        guard part >= latest else { return }
        latest = part
        for listener in listeners.values { listener(.downloading(part)) }
    }
}

/// Oruk Fourier as a `SpeechEngine`: each pass hears the whole stretch. The word list's terms go
/// into its prompt (mlx-audio's `hotwords`), at every pass alike. It gives no times of its words.
struct FourierEngine: SpeechEngine {
    let sidecar: FourierSidecar
    let hotwords: [String]

    func hear(_ samples: [Float], final: Bool) async throws -> Heard {
        Heard(text: try await sidecar.hear(samples, hotwords: hotwords))
    }
}

/// THE PYTHON PROCESS THAT HOLDS THE MODEL: `fourier.py` (`FourierScript`) in the runtime's venv,
/// speaking JSON lines. Its first line says it is ready, after the load and a warm-up pass; then
/// each line in (`{ id, audio, hotwords }`, the samples as base64 of 32-bit floats) gets one line
/// out (`{ id, text, seconds }` or `{ id, error }`), in order. Its stdin is a pipe of this process:
/// when the app ends, the pipe closes and the script ends. The last reference to this object ends
/// it too.
final class FourierSidecar: @unchecked Sendable {
    /// The most seconds a load may take (the first one after a download reads 2.5 GB), and a pass.
    static let loadSeconds = 180.0
    static let passSeconds = 30.0

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let writes = DispatchQueue(label: "FourierSidecar.stdin")
    private let lock = NSLock()
    private var waiting: [Int: CheckedContinuation<String, Error>] = [:]
    private var ready: CheckedContinuation<Void, Error>?
    private var isReady = false
    private var hasEnded = false
    private var next = 0
    /// The end of stderr, for an error.
    private var said = ""
    let started = Date()

    var isRunning: Bool { lock.withLock { !hasEnded } }

    static func start(_ runtime: FourierRuntime) async throws -> FourierSidecar {
        if (try? String(contentsOf: runtime.script, encoding: .utf8)) != FourierScript.source {
            try FourierScript.source.write(to: runtime.script, atomically: true, encoding: .utf8)
        }
        let sidecar = FourierSidecar()
        try sidecar.run(runtime)
        try await sidecar.waitForReady()
        return sidecar
    }

    private func run(_ runtime: FourierRuntime) throws {
        process.executableURL = runtime.python
        process.arguments = ["-I", runtime.script.path, runtime.model.path]
        process.environment = [
            "HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1", "TOKENIZERS_PARALLELISM": "false", "PYTHONUNBUFFERED": "1",
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path, "PATH": "/usr/bin:/bin",
        ]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let lines = LineBuffer()
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                self?.end("its output ended")
                return
            }
            for line in lines.add(data) { self?.heard(line) }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return handle.readabilityHandler = nil }
            guard let self else { return }
            lock.withLock { self.said = String((self.said + String(decoding: data, as: UTF8.self)).suffix(2000)) }
        }
        process.terminationHandler = { [weak self] process in self?.end("it exited (\(process.terminationStatus))") }
        try process.run()
    }

    private func waitForReady() async throws {
        let timeout = Task { [weak self] in
            try await Task.sleep(nanoseconds: UInt64(Self.loadSeconds * 1e9))
            self?.end("it did not load within \(Int(Self.loadSeconds)) s")
        }
        defer { timeout.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let now: Result<Void, Error>? = lock.withLock {
                    if isReady { return .success(()) }
                    if hasEnded { return .failure(FourierError.process("it ended at its start: \(lastSaid)")) }
                    ready = continuation
                    return nil
                }
                if let now { continuation.resume(with: now) }
            }
        } onCancel: { [weak self] in
            self?.end("its start was cancelled")
        }
    }

    /// The text of `samples`, with `hotwords` in the prompt. Throws when the process fails or ends.
    func hear(_ samples: [Float], hotwords: [String]) async throws -> String {
        // the model hears at least half a second
        var samples = samples
        if samples.count < SpeechStretch.rate / 2 { samples += [Float](repeating: 0, count: SpeechStretch.rate / 2 - samples.count) }
        let audio = samples.withUnsafeBufferPointer { Data(buffer: $0) }.base64EncodedString()
        let id: Int = lock.withLock {
            next += 1
            return next
        }
        let line = try JSONSerialization.data(withJSONObject: ["id": id, "audio": audio, "hotwords": hotwords]) + Data([0x0A])
        let timeout = Task { [weak self] in
            try await Task.sleep(nanoseconds: UInt64((Self.passSeconds + Double(samples.count) / Double(SpeechStretch.rate)) * 1e9))
            // a pass that does not end: the process is stuck, and the next load starts another
            self?.end("a pass took more than \(Int(Self.passSeconds)) s")
        }
        defer { timeout.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            let failure: Error? = lock.withLock {
                if hasEnded { return FourierError.process("the process ended: \(lastSaid)") }
                waiting[id] = continuation
                return nil
            }
            if let failure { return continuation.resume(throwing: failure) }
            let handle = input.fileHandleForWriting
            writes.async { [weak self] in
                do { try handle.write(contentsOf: line) } catch { self?.end("its input closed") }
            }
        }
    }

    /// Under `lock`: the end of stderr, on one line.
    private var lastSaid: String {
        said.split(separator: "\n").suffix(3).joined(separator: " | ")
    }

    private func heard(_ line: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
        if object["ready"] as? Bool == true {
            let continuation: CheckedContinuation<Void, Error>? = lock.withLock {
                isReady = true
                defer { ready = nil }
                return ready
            }
            continuation?.resume()
            return
        }
        guard let id = object["id"] as? Int, let continuation = lock.withLock({ waiting.removeValue(forKey: id) }) else { return }
        if let text = object["text"] as? String {
            continuation.resume(returning: text.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            continuation.resume(throwing: FourierError.process(object["error"] as? String ?? "no text"))
        }
    }

    /// Ends the process; every caller that waits gets the reason.
    private func end(_ reason: String) {
        let (waiters, starting, said): ([CheckedContinuation<String, Error>], CheckedContinuation<Void, Error>?, String) = lock.withLock {
            hasEnded = true
            defer {
                waiting = [:]
                ready = nil
            }
            return (Array(waiting.values), ready, lastSaid)
        }
        let error = FourierError.process("\(reason)\(said.isEmpty ? "" : ": \(said)")")
        waiters.forEach { $0.resume(throwing: error) }
        starting?.resume(throwing: error)
        if process.isRunning { process.terminate() }
        try? input.fileHandleForWriting.close()
    }

    deinit {
        if process.isRunning { process.terminate() }
    }
}

/// The script of `FourierSidecar`, written beside the venv at each start when it changed.
enum FourierScript {
    static let source = #"""
        # fourier.py: Oruk Fourier 2B for the iterate Mac app (Sources/SpeechText/Fourier.swift), in the venv of
        # FourierRuntime. Written by the app: a change here is a change of FourierScript.source.
        #
        #   python -I fourier.py <model folder>        then one JSON line a request on stdin
        #
        # stdout is JSON lines only: `{"ready": true, "loadSeconds"}` after the load and a warm-up, then for each
        # `{"id", "audio", "hotwords"}` (audio: base64 of little-endian float32 at 16 kHz) one `{"id", "text", "seconds"}`
        # or `{"id", "error"}`. What the libraries print goes to stderr. It ends when stdin ends.
        import base64
        import json
        import sys
        import time

        out = sys.stdout
        sys.stdout = sys.stderr

        import numpy as np
        from mlx_audio.stt.utils import load_model


        def say(line):
            out.write(json.dumps(line) + "\n")
            out.flush()


        started = time.time()
        model = load_model(sys.argv[1])
        model.generate(np.zeros(16000, dtype=np.float32), language="English", max_tokens=8)
        say({"ready": True, "loadSeconds": time.time() - started})
        for line in sys.stdin:
            if not line.strip():
                continue
            ask = {}
            try:
                ask = json.loads(line)
                started = time.time()
                audio = np.frombuffer(base64.b64decode(ask["audio"]), dtype="<f4")
                options = {"language": "English", "max_tokens": int(16 * len(audio) / 16000) + 32}
                if ask.get("hotwords"):
                    options["hotwords"] = ask["hotwords"]
                text = model.generate(audio, **options).text.strip()
                say({"id": ask["id"], "text": text, "seconds": time.time() - started})
            except Exception as error:
                say({"id": ask.get("id"), "error": f"{type(error).__name__}: {error}"})
        """#
}
