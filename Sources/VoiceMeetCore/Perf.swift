import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// WHAT THE APP COSTS, for a test copy's `ui.state` (`perf`) and the harness's `idle` and
/// `panel-open` scenarios: the process's figures, read when asked, a watch of the main queue's
/// delay, and counters of work that should not happen while nothing changes. The installed app
/// counts nothing: `Perf.isCounting` is false there.
public enum Perf {
    /// The process's figures since it started. `cpuSeconds` is user and system time of every
    /// thread; `rss` the physical footprint (as Activity Monitor's Memory); `idleWakeups` the
    /// wake-ups of the package from idle; `interruptWakeups` every timer and interrupt wake-up.
    public struct Figures: Equatable, Sendable {
        public var cpuSeconds: Double
        public var rss: UInt64
        public var idleWakeups: UInt64
        public var interruptWakeups: UInt64
        public var openFiles: Int
        public var threads: Int

        public var dictionary: [String: Any] {
            [
                "cpuSeconds": (cpuSeconds * 1000).rounded() / 1000, "rss": rss, "idleWakeups": idleWakeups,
                "interruptWakeups": interruptWakeups, "openFiles": openFiles, "threads": threads,
            ]
        }
    }

    /// This process's figures now. Each is one system call; zero where the system gives none.
    public static func figures() -> Figures {
        var figures = Figures(cpuSeconds: 0, rss: 0, idleWakeups: 0, interruptWakeups: 0, openFiles: 0, threads: 0)
        #if canImport(Darwin)
        var usage = rusage()
        if getrusage(RUSAGE_SELF, &usage) == 0 {
            let seconds = { (time: timeval) in Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000 }
            figures.cpuSeconds = seconds(usage.ru_utime) + seconds(usage.ru_stime)
        }
        let pid = getpid()
        var info = rusage_info_v4()
        let read = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        if read == 0 {
            figures.rss = info.ri_phys_footprint
            figures.idleWakeups = info.ri_pkg_idle_wkups
            figures.interruptWakeups = info.ri_interrupt_wkups
        }
        // the size of the list of descriptors, asked with no buffer
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        if bytes > 0 {
            var list = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / MemoryLayout<proc_fdinfo>.stride)
            let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &list, Int32(list.count * MemoryLayout<proc_fdinfo>.stride))
            figures.openFiles = Int(filled) / MemoryLayout<proc_fdinfo>.stride
        }
        var task = proc_taskinfo()
        if proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, Int32(MemoryLayout<proc_taskinfo>.stride)) > 0 {
            figures.threads = Int(task.pti_threadnum)
        }
        #endif
        return figures
    }

    // MARK: - Counters

    /// Whether `count` counts: a test copy's (the control socket is open), and a test's.
    nonisolated(unsafe) public static var isCounting = false
    private static let lock = NSLock()
    nonisolated(unsafe) private static var counts: [String: Int] = [:]

    /// One more of `name`: a body of the panel drawn, a change of the app's state, a write of the mark.
    public static func count(_ name: String) {
        guard isCounting else { return }
        lock.withLock { counts[name, default: 0] += 1 }
    }

    /// Every counter since the last `reset`.
    public static var counters: [String: Int] { lock.withLock { counts } }

    public static func resetCounters() {
        lock.withLock { counts = [:] }
    }
}

/// THE MAIN QUEUE'S LONGEST DELAY since the last `reset`: a thread of its own asks the main queue
/// for a turn every `interval`, and keeps the longest wait for it. A wait that has not ended counts
/// with its time so far. It wakes the app 1/`interval` times a second, so it runs only while asked
/// (`perf.reset {watchMain: true}`), never in an idle measurement.
public final class MainStallWatch: @unchecked Sendable {
    public let interval: TimeInterval
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var maxDelay: TimeInterval = 0
    private var sentAt: TimeInterval?
    private let queue = DispatchQueue(label: "perf.main-stall", qos: .userInteractive)
    private let target: DispatchQueue

    /// `target` is the queue watched: the main queue, or a test's.
    public init(interval: TimeInterval = 0.05, target: DispatchQueue = .main) {
        self.interval = interval
        self.target = target
    }

    public var isRunning: Bool { lock.withLock { timer != nil } }

    public func start() {
        lock.withLock {
            guard timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(5))
            timer.setEventHandler { [weak self] in self?.ping() }
            timer.resume()
            self.timer = timer
        }
    }

    public func stop() {
        lock.withLock {
            timer?.cancel()
            timer = nil
            sentAt = nil
        }
    }

    /// The longest delay in milliseconds since the last reset, a wait that runs now included.
    public var maxMilliseconds: Double {
        lock.withLock {
            let running = sentAt.map { Self.now() - $0 } ?? 0
            return (max(maxDelay, running) * 1000).rounded()
        }
    }

    public func reset() {
        lock.withLock {
            maxDelay = 0
            if sentAt != nil { sentAt = Self.now() }
        }
    }

    private func ping() {
        let sent: TimeInterval? = lock.withLock {
            // one ask at a time: a long stall is one wait, measured to its end
            guard sentAt == nil else { return nil }
            let now = Self.now()
            sentAt = now
            return now
        }
        guard sent != nil else { return }
        target.async { [weak self] in
            guard let self else { return }
            self.lock.withLock {
                if let sentAt = self.sentAt { self.maxDelay = max(self.maxDelay, Self.now() - sentAt) }
                self.sentAt = nil
            }
        }
    }

    private static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
}
