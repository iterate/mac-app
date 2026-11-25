import CryptoKit
import Foundation

/// THE FILES THAT RUN ORUK FOURIER 2B on this Mac (README, "Dictation"): the model, Oruk's MLX
/// 8-bit form at one pinned revision of `oruk/oruk-fourier-2b`, and its runtime, Python 3.12 with
/// mlx-audio in a venv of its own, made by a pinned uv. MLX Swift is not the runtime: the app builds
/// with the Command Line Tools, which have no Metal compiler for MLX's kernels; mlx's wheel brings
/// them built.
///
/// Every file is checked: uv's archive and each model file against its SHA-256 here, each Python
/// package against the hashes of `FourierLock` (`--require-hashes`), and uv checks the Python it
/// downloads. A download that stops (a quit, the network) goes on from where it was at the next
/// `prepare`. `ready.json` says that all of it is in place, for this revision, lock and script.
///
/// The folder is shared by every copy of the app on this Mac, as FluidAudio's is:
/// `~/Library/Application Support/iterate-speech/oruk-fourier-2b`, or the environment's
/// `ITERATE_MAC_FOURIER_FOLDER`.
public struct FourierRuntime: Sendable {
    /// The revision of `oruk/oruk-fourier-2b` (25 November 2026). Its `mlx/8bit/model.safetensors`
    /// is the one the bench measured at `f1efa792` (same SHA-256).
    public static let revision = "d058401c8cd932daac47c0b1de549875547504c2"
    static let repository = "https://huggingface.co/oruk/oruk-fourier-2b/resolve"

    struct File: Sendable {
        let name: String
        let bytes: Int64
        let sha256: String
    }

    /// The model's files, in `mlx/8bit/` of the revision.
    static let modelFiles = [
        File(name: "model.safetensors", bytes: 2_463_307_581, sha256: "ab25802465c25acb787979c56e1907dd6bec1c9f592c1e9cb03e11d060b2d0f7"),
        File(name: "tokenizer.json", bytes: 11_429_377, sha256: "bd2a97b55c8f7f9c328c73ee9b9178771037e9f566dfca8e238a063d41cbac92"),
        File(name: "vocab.json", bytes: 3_080_118, sha256: "97dfe4fe392c23cda68fe01c60babe50a57c894fc0cf44d02c4048ad283499c3"),
        File(name: "merges.txt", bytes: 1_671_853, sha256: "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5"),
        File(name: "generation_config.json", bytes: 836_102, sha256: "c2952d2787ee983a289d8f921b0a67c4dfb4e75c4246479f5b1e0ff3be8af236"),
        File(name: "model.safetensors.index.json", bytes: 78_928, sha256: "b62daee0e37a7bedb8675f69c733eef18a398235ea513f0999f3805d5ac4dedf"),
        File(name: "config.json", bytes: 3_164, sha256: "93aaa3c41ef7c289e8ca123827188049508ef7246425eb3ef0f56f1195877c6d"),
        File(name: "chat_template.jinja", bytes: 1_434, sha256: "f50e6b694fbf4a683206e37869990d68333fe95d285730f084c838a34b0d98c2"),
        File(name: "tokenizer_config.json", bytes: 1_446, sha256: "940657ec4b19a2486cd8f95d2967a7a2acbeb6064663ece8ab3833ec455530b3"),
        File(name: "processor_config.json", bytes: 487, sha256: "bc0b230081b44e629dd5b9045b78495615c1831b4b9f4cffe97bd37e82a6156a"),
        File(name: "fourier-conversion.json", bytes: 328, sha256: "41888a182e2693d954052190e399fb146a865f062a00c81eeda396bf565f7909"),
    ]

    /// uv, which makes the venv and installs the packages: its release for Apple silicon.
    static let uv = File(name: "uv-aarch64-apple-darwin.tar.gz", bytes: 22_568_053, sha256: "33540eb7c883ab857eff79bd5ac2aa31fe27b595abecb4a9c003a2c998447232")
    static let uvVersion = "0.11.28"
    static let pythonVersion = "3.12"

    /// The parts of a whole `prepare`: uv, then Python, then the packages (155 MB), then the model.
    static let shares = (uv: 0.01, python: 0.02, packages: 0.07)

    public let folder: URL

    public init(folder: URL) {
        self.folder = folder
    }

    public static let standard = FourierRuntime(
        folder: ProcessInfo.processInfo.environment["ITERATE_MAC_FOURIER_FOLDER"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/iterate-speech/oruk-fourier-2b"))

    var model: URL { folder.appendingPathComponent("model-\(Self.revision.prefix(12))") }
    var venv: URL { folder.appendingPathComponent("venv") }
    var python: URL { venv.appendingPathComponent("bin/python") }
    var script: URL { folder.appendingPathComponent("fourier.py") }
    var log: URL { folder.appendingPathComponent("setup.log") }
    private var marker: URL { folder.appendingPathComponent("ready.json") }
    private var downloads: URL { folder.appendingPathComponent("downloads") }
    private var uvBinary: URL { folder.appendingPathComponent("uv-\(Self.uvVersion)/uv-aarch64-apple-darwin/uv") }

    /// What a ready folder holds: a new revision, lock or script makes it not ready.
    static let fingerprint: String = digest(Data([revision, FourierLock.requirements, uvVersion, pythonVersion, FourierScript.source].joined(separator: "\n").utf8))

    /// Whether everything is in place: `prepare` then does nothing. It reads no large file.
    public var isReady: Bool {
        guard let data = try? Data(contentsOf: marker), String(decoding: data, as: UTF8.self) == Self.fingerprint else { return false }
        let files = FileManager.default
        return files.isExecutableFile(atPath: python.path) && Self.modelFiles.allSatisfy { file in
            ((try? files.attributesOfItem(atPath: model.appendingPathComponent(file.name).path))?[.size] as? NSNumber)?.int64Value == file.bytes
        }
    }

    /// Gets what is missing, and checks it. `progress` hears 0 to 1 of the whole.
    public func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        if isReady { return progress(1) }
        let files = FileManager.default
        try files.createDirectory(at: downloads, withIntermediateDirectories: true)
        try files.createDirectory(at: model, withIntermediateDirectories: true)
        try? files.removeItem(at: marker)
        note("prepare \(Self.fingerprint): revision \(Self.revision), uv \(Self.uvVersion), Python \(Self.pythonVersion)")

        if !files.isExecutableFile(atPath: uvBinary.path) {
            let archive = try await download(URL(string: "https://github.com/astral-sh/uv/releases/download/\(Self.uvVersion)/\(Self.uv.name)")!, Self.uv) {
                progress($0 * Self.shares.uv)
            }
            let into = uvBinary.deletingLastPathComponent().deletingLastPathComponent()
            try files.createDirectory(at: into, withIntermediateDirectories: true)
            try await run(URL(fileURLWithPath: "/usr/bin/tar"), ["-xzf", archive.path, "-C", into.path])
            guard files.isExecutableFile(atPath: uvBinary.path) else { throw FourierError.setup("uv's archive held no uv") }
            try? files.removeItem(at: archive)
        }
        progress(Self.shares.uv)

        // The packages, when the venv has not got this lock: a new venv, then the locked set.
        let lock = venv.appendingPathComponent("iterate-lock.txt")
        if (try? String(contentsOf: lock, encoding: .utf8)) != FourierLock.requirements {
            let uv: [String: String] = [
                "UV_PYTHON_INSTALL_DIR": folder.appendingPathComponent("python").path, "UV_NO_CONFIG": "1", "UV_PYTHON_PREFERENCE": "only-managed",
                "UV_NO_PROGRESS": "1", "HOME": FileManager.default.homeDirectoryForCurrentUser.path, "PATH": "/usr/bin:/bin",
            ]
            try await run(uvBinary, ["venv", "--clear", "--python", Self.pythonVersion, venv.path], environment: uv)
            progress(Self.shares.python)
            let requirements = folder.appendingPathComponent("requirements.txt")
            try FourierLock.requirements.write(to: requirements, atomically: true, encoding: .utf8)
            try await run(
                uvBinary,
                [
                    "pip", "install", "--python", python.path, "--require-hashes", "--no-deps", "--only-binary", ":all:", "--no-cache",
                    "--index-url", "https://pypi.org/simple", "-r", requirements.path,
                ], environment: uv)
            try FourierLock.requirements.write(to: lock, atomically: true, encoding: .utf8)
        }
        progress(Self.shares.packages)

        // The model, file by file, with their part of the whole by their size.
        let total = Self.modelFiles.reduce(0) { $0 + $1.bytes }
        var done: Int64 = 0
        for file in Self.modelFiles {
            let target = model.appendingPathComponent(file.name)
            let size = ((try? files.attributesOfItem(atPath: target.path))?[.size] as? NSNumber)?.int64Value
            if size != file.bytes {
                let base = done
                let got = try await download(URL(string: "\(Self.repository)/\(Self.revision)/mlx/8bit/\(file.name)")!, file) { part in
                    progress(Self.shares.packages + (1 - Self.shares.packages) * (Double(base) + part * Double(file.bytes)) / Double(total))
                }
                try? files.removeItem(at: target)
                try files.moveItem(at: got, to: target)
            }
            done += file.bytes
            progress(Self.shares.packages + (1 - Self.shares.packages) * Double(done) / Double(total))
        }
        try Data(Self.fingerprint.utf8).write(to: marker, options: .atomic)
        note("ready")
    }

    /// `file` from `url`, checked: its path in `downloads`. curl goes on from a part that a stop
    /// left; a part with the wrong hash goes, and the download fails.
    private func download(_ url: URL, _ file: File, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let files = FileManager.default
        let part = downloads.appendingPathComponent(file.name + ".part")
        let size = { ((try? files.attributesOfItem(atPath: part.path))?[.size] as? NSNumber)?.int64Value ?? 0 }
        if size() > file.bytes { try? files.removeItem(at: part) }
        if size() < file.bytes {
            note("download \(file.name): \(file.bytes) bytes, \(size()) here")
            let watch = Task {
                while !Task.isCancelled {
                    progress(min(1, Double(size()) / Double(file.bytes)))
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            }
            defer { watch.cancel() }
            try await run(
                URL(fileURLWithPath: "/usr/bin/curl"),
                ["-fsSL", "--retry", "3", "--retry-delay", "2", "--connect-timeout", "20", "-C", "-", "-o", part.path, url.absoluteString])
        }
        progress(1)
        let hash = try Self.sha256(of: part)
        guard hash == file.sha256 else {
            try? files.removeItem(at: part)
            throw FourierError.setup("\(file.name) has the wrong SHA-256 (\(hash.prefix(12))…): it was removed, try again")
        }
        return part
    }

    /// Runs a program to its end, its output in `setup.log`. A cancel ends it.
    private func run(_ program: URL, _ arguments: [String], environment: [String: String]? = nil) async throws {
        note("run \(program.lastPathComponent) \(arguments.prefix(3).joined(separator: " "))")
        let process = Process()
        process.executableURL = program
        process.arguments = arguments
        if let environment { process.environment = environment }
        let output = try FileHandle(forWritingTo: log)
        output.seekToEndOfFile()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                do { try process.run() } catch { continuation.resume(throwing: error) }
            }
        } onCancel: {
            process.terminate()
        }
        try? output.close()
        try Task.checkCancellation()
        guard status == 0 else {
            throw FourierError.setup("\(program.lastPathComponent) \(arguments.first ?? "") failed (\(status)): \(lastLines(of: log))")
        }
    }

    /// A line in `setup.log`, with the time.
    private func note(_ line: String) {
        let files = FileManager.default
        try? files.createDirectory(at: folder, withIntermediateDirectories: true)
        if !files.fileExists(atPath: log.path) { files.createFile(atPath: log.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: log) else { return }
        handle.seekToEndOfFile()
        handle.write(Data("\(ISO8601DateFormatter().string(from: Date())) \(line)\n".utf8))
        try? handle.close()
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 8 << 20), !data.isEmpty { hasher.update(data: data) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func digest(_ data: Data) -> String {
        String(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(16))
    }
}

/// The last lines of a log, on one line, for an error.
func lastLines(of url: URL, count: Int = 3) -> String {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "no log" }
    return text.split(separator: "\n").suffix(count).joined(separator: " | ")
}

public enum FourierError: Error, LocalizedError {
    case setup(String)
    case process(String)

    public var errorDescription: String? {
        switch self {
        case .setup(let reason): "Oruk Fourier's files: \(reason)"
        case .process(let reason): "Oruk Fourier: \(reason)"
        }
    }
}
