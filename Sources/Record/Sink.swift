import CoreMedia
import CoreVideo
import Foundation

/// A receiver of what the sources capture: every frame and every sound buffer, as captured, with
/// its host time. The record's own tracks are one sink (`RecordSink`); live (`Sources/Live`) is
/// another. A sink is called on the capture's own queue and must not block it.
public protocol CaptureSink: AnyObject {
    /// `track` is the record's track id: `screen-<display>`, `camera-<n>`, `test-1`.
    func video(_ track: String, _ frame: CVPixelBuffer, hostTime: CMTime)
    /// PCM in the capture's own format: `mic-<n>`, `speaker-0`, `test-2`.
    func sound(_ track: String, _ sample: CMSampleBuffer, hostTime: CMTime)
    /// The source of `track` is gone: an unplugged screen or camera.
    func ended(_ track: String)
}

/// How many frames a second a screen captures, and which of them the record keeps.
public enum CaptureRate {
    /// While somebody watches: a screen captures 30 frames a second.
    public static let live = 30
    /// A frame is dropped when it comes less than this before its time (`keeps`): 4 ms, so that
    /// every third frame of 30 passes for 10, and every second of 30 for 15.
    static let slack = 0.004

    public static func capture(record fps: Int, watched: Bool) -> Int { watched ? max(fps, live) : fps }

    /// Whether the record keeps a frame at `now` (seconds), when it kept the last one at `last`:
    /// at most `fps` a second, by time. A frame from before the last one (a clock that went back)
    /// is kept.
    public static func keeps(last: Double?, now: Double, fps: Int) -> Bool {
        guard let last, now >= last else { return true }
        return now - last >= 1 / Double(fps) - slack
    }
}

/// What the recorder does when what the record wants or what live wants changes. A source runs
/// while either wants it. Pure: the recorder applies it (`Recorder.apply`).
public enum CapturePlan {
    public enum Change: Equatable {
        /// Start the source (its tracks record when the record wants it).
        case start(RecordSource)
        /// Stop the source and its tracks.
        case stop(RecordSource)
        /// The record no longer wants a source that live still watches: its tracks end, the source runs on.
        case stopRecording(RecordSource)
        /// The record wants a source that ran for live alone: it starts again, with its tracks.
        case restart(RecordSource)
        /// Live began or ended watching a source the record has: its frames a second change.
        case rate(RecordSource)
    }

    /// Stops first, then the rest, each in the order of `RecordSource.allCases`.
    public static func changes(
        running: Set<RecordSource>, record: (before: Set<RecordSource>, now: Set<RecordSource>), live: (before: Set<RecordSource>, now: Set<RecordSource>)
    ) -> [Change] {
        var stops: [Change] = [], others: [Change] = []
        for kind in RecordSource.allCases {
            let wanted = record.now.contains(kind) || live.now.contains(kind)
            let recordedBefore = record.before.contains(kind), records = record.now.contains(kind)
            if running.contains(kind) {
                if !wanted {
                    stops.append(.stop(kind))
                } else if records && !recordedBefore {
                    others.append(.restart(kind))
                } else if !records && recordedBefore {
                    others.append(.stopRecording(kind))
                } else if live.before.contains(kind) != live.now.contains(kind) {
                    others.append(.rate(kind))
                }
            } else if wanted {
                others.append(.start(kind))
            }
        }
        return stops + others
    }
}

/// The record's own sink: each frame and buffer to its track, when the record has that track. A
/// screen that captures faster for live is kept at the record's `fps` by time; a camera at most at
/// `cameraFps` (a camera's format belongs to the whole Mac: another program can set it to 30), and
/// only when its picture changed, at least once a second (`CameraChange`): every frame of a camera
/// differs a little from the last, so without this a still room cost as much as a moving one.
final class RecordSink: CaptureSink {
    private unowned let r: Recorder
    private let lock = NSLock()
    /// The time of the last frame kept, per track.
    private var kept: [String: Double] = [:]
    /// A camera's last frame kept: its time and its small copy (`CameraChange`).
    private var cameraKept: [String: (time: Double, thumb: [Float]?)] = [:]

    init(recorder: Recorder) { r = recorder }

    func video(_ id: String, _ frame: CVPixelBuffer, hostTime: CMTime) {
        guard let track = r.track(id) as? VideoTrack else { return }
        let fps: Int?
        if id.hasPrefix(RecordSource.cameras.prefix) {
            guard keepsCamera(id, frame, now: CMTimeGetSeconds(hostTime)) else { return }
            fps = nil
        } else {
            let kind: RecordSource = id.hasPrefix(RecordSource.synthetic.prefix) ? .synthetic : .screens
            fps = r.captureFps(kind) > r.options.fps ? r.options.fps : nil
        }
        if let fps {
            let now = CMTimeGetSeconds(hostTime)
            let keep = lock.withLock { () -> Bool in
                guard CaptureRate.keeps(last: kept[id], now: now, fps: fps) else { return false }
                kept[id] = now
                return true
            }
            guard keep else { return }
        }
        track.append(frame, hostTime: hostTime)
    }

    /// At most `cameraFps` frames a second; of those, the ones whose picture changed, and one a second.
    private func keepsCamera(_ id: String, _ frame: CVPixelBuffer, now: Double) -> Bool {
        let last = lock.withLock { cameraKept[id] }
        guard CaptureRate.keeps(last: last?.time, now: now, fps: r.options.cameraFps) else { return false }
        let thumb = CameraChange.thumbnail(frame)
        guard CameraChange.keeps(last: last, now: now, thumb: thumb) else { return false }
        lock.withLock { cameraKept[id] = (now, thumb) }
        return true
    }

    func sound(_ id: String, _ sample: CMSampleBuffer, hostTime: CMTime) {
        (r.track(id) as? AudioTrack)?.append(sample, hostTime: hostTime)
    }

    func ended(_ id: String) { (r.track(id) as? VideoTrack)?.end() }
}
