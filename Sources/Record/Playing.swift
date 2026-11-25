import CoreAudio
import Foundation

/// Whether another process plays sound: `kAudioProcessPropertyIsRunningOutput` of each of Core
/// Audio's process objects, read again at each change of the list of processes and of a process's
/// `kAudioProcessPropertyIsRunning` (no polling). Measured on 25 Nov 2026 (macOS 15): `IsRunning`
/// notifies when a process starts and stops its sound, `IsRunningOutput` notifies nothing. A
/// process that already runs input (a call) and then starts output changes no `IsRunning`: it is
/// read again when the default output's `kAudioDevicePropertyDeviceIsRunningSomewhere` changes,
/// which goes to 1 when a sound starts while the capture is stopped. Our own process does not
/// count: the speakers' capture leaves its sound out.
///
/// Not the output device's `kAudioDevicePropertyDeviceIsRunningSomewhere`: measured on 25 Nov 2026
/// with the speakers recorded and nothing playing, the default output (MacBook Pro Speakers) said
/// 1, held by replayd, the capture's own process (it runs input on the device); so it would never
/// say that nothing plays while the capture runs.
final class OutputWatch {
    private let queue: DispatchQueue
    private let changed: (Bool) -> Void
    /// On `queue`: the listener of each process, of each output device that was the default, and of
    /// the system object (the list of processes, the default output).
    private var listeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var devices: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var listListener: AudioObjectPropertyListenerBlock?
    private static let system = AudioObjectID(kAudioObjectSystemObject)
    private static let systemSelectors = [kAudioHardwarePropertyProcessObjectList, kAudioHardwarePropertyDefaultOutputDevice]
    private(set) var playing = false
    private let me = getpid()

    /// `changed` is called on `queue` with each change of `playing`.
    init(queue: DispatchQueue, changed: @escaping (Bool) -> Void) {
        self.queue = queue
        self.changed = changed
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    /// On `queue`: the listeners, and `playing` now (without a call to `changed`). When the list
    /// cannot be watched, `playing` is always true.
    func start() -> Bool {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.refresh(notify: true) }
        let added = OutputWatch.systemSelectors.map { selector in
            var address = OutputWatch.address(selector)
            return AudioObjectAddPropertyListenerBlock(OutputWatch.system, &address, queue, block) == noErr
        }
        guard added[0] else {
            // No way to know: as if a sound always played, so the capture always runs.
            log("speaker-0: Core Audio's list of processes cannot be watched; the capture always runs")
            playing = true
            return true
        }
        listListener = block
        refresh(notify: false)
        return playing
    }

    /// Not on `queue`: a listener's removal waits for its block, which runs there.
    func stop() {
        typealias Blocks = [AudioObjectID: AudioObjectPropertyListenerBlock]
        let (first, each, outputs) = queue.sync { () -> (AudioObjectPropertyListenerBlock?, Blocks, Blocks) in
            defer { (listListener, listeners, devices) = (nil, [:], [:]) }
            return (listListener, listeners, devices)
        }
        if let first {
            for selector in OutputWatch.systemSelectors {
                var address = OutputWatch.address(selector)
                AudioObjectRemovePropertyListenerBlock(OutputWatch.system, &address, queue, first)
            }
        }
        var running = OutputWatch.address(kAudioProcessPropertyIsRunning)
        for (process, block) in each { AudioObjectRemovePropertyListenerBlock(process, &running, queue, block) }
        var somewhere = OutputWatch.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        for (device, block) in outputs { AudioObjectRemovePropertyListenerBlock(device, &somewhere, queue, block) }
    }

    private func processes() -> [AudioObjectID] {
        var list = OutputWatch.address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &list, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &list, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private func value<T: FixedWidthInteger>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _: T.Type) -> T? {
        var address = OutputWatch.address(selector)
        var result: T = 0
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result) == noErr ? result : nil
    }

    /// On `queue`: a listener on each new process, and whether any other one runs output now.
    /// After `stop`, nothing.
    private func refresh(notify: Bool) {
        guard listListener != nil else { return }
        let now = processes()
        var running = OutputWatch.address(kAudioProcessPropertyIsRunning)
        for process in now where listeners[process] == nil {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.refresh(notify: true) }
            if AudioObjectAddPropertyListenerBlock(process, &running, queue, block) == noErr { listeners[process] = block }
        }
        for gone in Set(listeners.keys).subtracting(now) { listeners[gone] = nil }
        // The default output, which a sound starts while the capture is stopped (an old one keeps its listener).
        if let device = value(OutputWatch.system, kAudioHardwarePropertyDefaultOutputDevice, AudioObjectID.self), device != 0, devices[device] == nil {
            var somewhere = OutputWatch.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.refresh(notify: true) }
            if AudioObjectAddPropertyListenerBlock(device, &somewhere, queue, block) == noErr { devices[device] = block }
        }
        let playing = now.contains { process in
            value(process, kAudioProcessPropertyPID, pid_t.self) != me && value(process, kAudioProcessPropertyIsRunningOutput, UInt32.self) ?? 0 != 0
        }
        guard playing != self.playing else { return }
        self.playing = playing
        if notify { changed(playing) }
    }
}
