import AVFoundation
import CoreMedia
import XCTest

@testable import Record

final class ClockTests: XCTestCase {
    func testTicksToNanosAndTheAnchor() {
        let silicon = MachTimebase(numer: 125, denom: 3)
        XCTAssertEqual(silicon.nanos(ticks: 24_000_000), 1_000_000_000)
        // No overflow after a long uptime (one year of 24 MHz ticks).
        let year: UInt64 = 24_000_000 * 86_400 * 365
        XCTAssertEqual(silicon.nanos(ticks: year), 86_400 * 365 * 1_000_000_000)
        let anchor = ClockAnchor(hostNanos: 5_000_000_000, wallMs: 1_700_000_000_000)
        XCTAssertEqual(anchor.wallMs(hostNanos: 5_250_000_000), 1_700_000_000_250)
        XCTAssertEqual(anchor.wallMs(hostNanos: 4_000_000_000), 1_699_999_999_000)  // before the anchor
    }
}

final class SlotTests: XCTestCase {
    func testSlotStartAndPaths() {
        // 2026-11-21T15:41:44.123Z
        let slot = Slot.start(1_795_275_704_123)
        XCTAssertEqual(slot, 1_795_275_690_000)
        XCTAssertEqual(Slot.path(device: "jonas.mac", track: "screen-1", slot: slot, ext: "mp4"), "/devices/jonas.mac/record/screen-1/2026-11-21/15/41-30.mp4")
        XCTAssertEqual(Slot.path(device: "jonas.mac", track: "camera-0", slot: slot - 30_000, ext: "jpg"), "/devices/jonas.mac/record/camera-0/2026-11-21/15/41-00.jpg")
        // The very edge of a slot, a day, a leap day and a year.
        XCTAssertEqual(Slot.start(Double(slot) + 29_999.9), slot)
        let at = { Slot.path(device: "d", track: "t", slot: $0, ext: "mp4").dropFirst("/devices/d/record/t/".count).dropLast(4) }
        XCTAssertEqual(at(0), "1970-01-01/00/00-00")
        XCTAssertEqual(at(951_782_370_000), "2000-02-28/23/59-30")
        XCTAssertEqual(at(951_782_400_000), "2000-02-29/00/00-00")
        XCTAssertEqual(at(1_798_761_570_000), "2026-12-31/23/59-30")
        XCTAssertEqual(at(1_798_761_600_000), "2027-01-01/00/00-00")
    }

    func testTheSlotEventIsTheSameBytesEveryTime() throws {
        let tracks: [String: [String: Any]] = [
            "mic-0": ["kind": "audio", "file": "/devices/d/record/mic-0/2026-11-21/15/41-30.mp4", "bytes": 3, "levels": [-99, -10]],
            "screen-1": ["kind": "video", "file": "/devices/d/record/screen-1/2026-11-21/15/41-30.mp4", "parts": [[712, 0], [9000, 10011]], "x": 0],
        ]
        let a = Slot.event(t: 1_795_275_690_000, tracks: tracks), b = Slot.event(t: 1_795_275_690_000, tracks: tracks)
        XCTAssertEqual(a, b)
        let text = String(decoding: a, as: UTF8.self)
        // allow-high-entropy-next-line: a Unix time in milliseconds, not a secret
        XCTAssertTrue(text.hasPrefix(#"{"t":1795275690000,"tracks":{"mic-0":{"bytes":3,"file":"/devices/d/"#), text)
        let read = try XCTUnwrap(JSONSerialization.jsonObject(with: a) as? [String: Any])
        XCTAssertEqual((read["tracks"] as? [String: Any])?.keys.sorted(), ["mic-0", "screen-1"])
    }

    func testExcludeList() {
        let defaults = ExcludeList()
        XCTAssertTrue(defaults.excludes("com.1password.1password"))
        XCTAssertTrue(defaults.excludes("com.apple.Passwords"))
        XCTAssertFalse(defaults.excludes("com.apple.Safari"))
        XCTAssertFalse(defaults.excludes(nil))
        XCTAssertTrue(ExcludeList(["com.example.Bank"]).excludes("com.example.bank"))
    }

    func testHEVCCodecString() {
        // hvcC of an Apple HEVC Main stream, level 3.1 (93): profile 1, compatibility 0x60000000, constraint 0xB0.
        var c: [UInt8] = [1, 0x01, 0x60, 0, 0, 0, 0xB0, 0, 0, 0, 0, 0, 93]
        XCTAssertEqual(hevcCodecString(c), "hvc1.1.6.L93.B0")
        (c[1], c[2], c[12]) = (0x22, 0x20, 153)  // high tier, Main 10
        XCTAssertEqual(hevcCodecString(c), "hvc1.2.4.H153.B0")
    }

    func testLevels() {
        var level = Level()
        level.add(sum: 0.01 * 0.01 * 100, count: 100, peak: 0.1, half: 0)
        level.add(sum: 1, count: 1, peak: 1, half: 59)
        level.add(sum: 0, count: 100, peak: 0, half: 30)
        XCTAssertEqual(level.levels.count, 60)
        XCTAssertEqual(level.levels[0], -20)
        XCTAssertEqual(level.levels[59], 0)
        XCTAssertEqual(level.levels[30], -99, "silence")
        XCTAssertEqual(level.peakDB, 0)
        XCTAssertEqual(level.rms, round1(10 * log10(1.01 / 201)))
    }

    /// The audio follows host time by repeating or dropping single samples, at most 1 in 100.
    func testResync() {
        XCTAssertEqual(Resync.change(drift: 48, count: 1024), 0, "1 ms is inside the tolerance")
        XCTAssertEqual(Resync.change(drift: 49, count: 1024), 10)
        XCTAssertEqual(Resync.change(drift: -2496, count: 1024), -10, "a −52 ms step: 10 samples a buffer")
        let longer = Resync.indices(count: 1000, change: 10)
        XCTAssertEqual(longer.count, 1010)
        XCTAssertEqual(Set(longer), Set(0..<1000), "every sample is kept")
        XCTAssertEqual(Set(Resync.indices(count: 1000, change: -10)).count, 990, "no sample twice")
        let repeats = longer.indices.dropFirst().filter { longer[$0] == longer[$0 - 1] }
        XCTAssertTrue(zip(repeats, repeats.dropFirst()).allSatisfy { $1 - $0 >= 90 }, "spread evenly")
    }
}

final class FMP4Tests: XCTestCase {
    func u32(_ b: [UInt8], _ p: Int) -> Int { Int(b[p]) << 24 | Int(b[p + 1]) << 16 | Int(b[p + 2]) << 8 | Int(b[p + 3]) }

    /// Top-level boxes, or the children of a box, as (type, start, end).
    func boxes(_ b: [UInt8], from: Int = 0, to: Int? = nil) -> [(type: String, start: Int, end: Int)] {
        var out: [(String, Int, Int)] = [], p = from
        let end = to ?? b.count
        while p + 8 <= end {
            let size = u32(b, p)
            guard size >= 8, p + size <= end else { break }
            out.append((String(bytes: b[(p + 4)..<(p + 8)], encoding: .ascii) ?? "", p, p + size))
            p += size
        }
        return out
    }

    /// A file of fragments through `SlotFile`, with the given sample counts; sample `i` has
    /// `i % 7 + 1` bytes, each byte the sample's index, so a byte tells which sample it is. A new
    /// fragment starts at each count's first sample, 5 s after the fragment before.
    func check(_ counts: [Int]) {
        let header = FMP4.header(video: false, timescale: 48_000, entry: FMP4.aacEntry(rate: 48_000, channels: 2, bitrate: 128_000))
        let file = SlotFile(slot: 0, header: header)
        var index = 0, sizes: [[Int]] = []
        for (f, n) in counts.enumerated() {
            var t = Int64(f) * 240_000 + 1234
            sizes.append([])
            for i in 0..<n {
                let size = index % 7 + 1
                file.append(Data(repeating: UInt8(index & 0xff), count: size), at: t, duration: 1024, sync: true, newFragment: i == 0)
                sizes[f].append(size)
                t += 1024
                index += 1
            }
        }
        let data = file.close().reduce(Data(), +)
        let size = file.size
        let b = [UInt8](data)
        XCTAssertEqual(size, data.count)
        let top = boxes(b)
        XCTAssertEqual(top.map(\.type), ["ftyp", "moov"] + counts.flatMap { _ in ["moof", "mdat"] })
        XCTAssertEqual(top.last?.end, data.count, "the boxes cover the file exactly")
        // `parts`: where each fragment starts, and its first sample's time.
        XCTAssertEqual(file.fragments.map(\.offset), counts.indices.map { top[2 + 2 * $0].start })
        XCTAssertEqual(file.fragments.map(\.ticks), counts.indices.map { Int64($0) * 240_000 + 1234 })
        index = 0
        for (f, samples) in sizes.enumerated() {
            let moof = top[2 + 2 * f], mdat = top[3 + 2 * f]
            XCTAssertEqual(mdat.end - mdat.start, 8 + samples.reduce(0, +))
            let inMoof = boxes(b, from: moof.start + 8, to: moof.end)
            XCTAssertEqual(u32(b, inMoof[0].start + 12), f + 1, "mfhd sequence")
            let traf = boxes(b, from: inMoof[1].start + 8, to: inMoof[1].end)
            XCTAssertEqual(traf.map(\.type), ["tfhd", "tfdt", "trun"])
            XCTAssertEqual(u32(b, traf[1].start + 16), f * 240_000 + 1234, "tfdt")
            let trun = traf[2].start
            XCTAssertEqual(u32(b, trun + 12), samples.count)
            let offset = u32(b, trun + 16)
            XCTAssertEqual(moof.start + offset, mdat.start + 8, "the data offset points at the first sample")
            var p = moof.start + offset
            for (i, s) in samples.enumerated() {
                XCTAssertEqual(u32(b, trun + 20 + 12 * i), 1024)
                XCTAssertEqual(u32(b, trun + 24 + 12 * i), s)
                XCTAssertTrue(b[p..<p + s].allSatisfy { $0 == UInt8(index & 0xff) }, "sample \(index) is where the trun says")
                p += s
                index += 1
            }
            XCTAssertEqual(p, mdat.end)
        }
    }

    func testOneFragment() { check([5]) }
    func testThreeFragmentsOfOddCounts() { check([1, 3, 7]) }
    func testAFragmentOfAWholeAudioSlot() { check([1407]) }

    func testAGapStartsANewFragment() {
        let file = SlotFile(slot: 0, header: Data([0, 0, 0, 8, 0x66, 0x72, 0x65, 0x65]))
        file.append(Data([1]), at: 0, duration: 10, sync: true, newFragment: true)
        file.append(Data([2]), at: 10, duration: 10, sync: false, newFragment: false)
        file.append(Data([3]), at: 50, duration: 10, sync: true, newFragment: false)  // a pause from 20 to 50
        _ = file.close()
        XCTAssertEqual(file.fragments.map(\.ticks), [0, 50])
    }

    func testHeaders() {
        let audio = FMP4.header(video: false, timescale: 48_000, entry: FMP4.aacEntry(rate: 48_000, channels: 2, bitrate: 128_000))
        // AudioSpecificConfig for 48 kHz stereo AAC-LC is 0x11 0x90.
        XCTAssertNotNil(audio.range(of: Data([0x05, 0x02, 0x11, 0x90])))
        XCTAssertNotNil(audio.range(of: Data("soun".utf8)))
        let entry = FMP4.videoEntry(type: "hvc1", configType: "hvcC", config: Data([1, 2, 3]), width: 5120, height: 2880)
        let video = FMP4.header(video: true, timescale: 90_000, width: 5120, height: 2880, entry: entry)
        XCTAssertEqual(boxes([UInt8](video)).map(\.type), ["ftyp", "moov"])
        XCTAssertEqual(boxes([UInt8](video)).last?.end, video.count)
    }
}

/// The spool, with no device: a slot is sealed once every track that began it has written it, its
/// event names exactly the files that are there, and a sealed slot takes nothing more, also after
/// a restart.
final class SpoolTests: XCTestCase {
    var spool: URL!

    override func setUp() {
        spool = FileManager.default.temporaryDirectory.appendingPathComponent("record-tests-\(UUID().uuidString)")
    }

    func recorder() -> Recorder { Recorder(options: RecordOptions(spool: spool, device: "test.mac")) }
    func slots() -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: spool.appendingPathComponent("slots").path)) ?? []).sorted() }
    func entry(_ kind: String) -> [String: Any] { ["kind": kind] }

    func testASlotIsSealedWhenItsLastTrackHasWritten() throws {
        let r = recorder(), t: Int64 = 1_795_275_690_000
        XCTAssertTrue(r.opening(track: "screen-1", slot: t))
        XCTAssertTrue(r.opening(track: "mic-0", slot: t))
        r.finished(track: "mic-0", slot: t, parts: [Data([1, 2]), Data([3])], size: 3, entry: entry("audio"), picture: nil)
        XCTAssertEqual(slots(), ["\(t).open"], "one track of two has written: the slot is open")
        r.finished(track: "screen-1", slot: t, parts: [Data([9])], size: 1, entry: entry("video"), picture: Data([0xff, 0xd8]))
        XCTAssertEqual(slots(), ["\(t).json"])
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: spool.appendingPathComponent("slots/\(t).json"))) as? [String: Any])
        XCTAssertEqual(payload["t"] as? Int64, t)
        let tracks = try XCTUnwrap(payload["tracks"] as? [String: [String: Any]])
        XCTAssertEqual(tracks.keys.sorted(), ["mic-0", "screen-1"])
        // Each named file is in the spool at its path in the mind, whole.
        for (path, bytes) in [(tracks["mic-0"]?["file"], 3), (tracks["screen-1"]?["file"], 1), (tracks["screen-1"]?["picture"], 2)] {
            let path = try XCTUnwrap(path as? String)
            XCTAssertTrue(path.hasPrefix("/devices/test.mac/record/"))
            XCTAssertEqual(try Data(contentsOf: spool.appendingPathComponent(String(path.dropFirst()))).count, bytes)
        }
        XCTAssertEqual(tracks["mic-0"]?["bytes"] as? Int, 3)
        XCTAssertNil(tracks["mic-0"]?["picture"])
        // Sealed: no track begins this slot again, nor an earlier one.
        XCTAssertFalse(r.opening(track: "camera-0", slot: t))
        XCTAssertFalse(r.opening(track: "camera-0", slot: t - 30_000))
        XCTAssertTrue(r.opening(track: "camera-0", slot: t + 30_000))
    }

    func testATrackWritesASlotOnce() {
        let r = recorder(), t: Int64 = 1_795_275_690_000
        XCTAssertTrue(r.opening(track: "mic-0", slot: t))
        XCTAssertTrue(r.opening(track: "screen-1", slot: t))
        r.finished(track: "mic-0", slot: t, parts: [Data([1])], size: 1, entry: entry("audio"), picture: nil)
        XCTAssertFalse(r.opening(track: "mic-0", slot: t), "switched off and on in one slot: it begins with the next")
    }

    func testARestartSealsWhatAnEarlierRunLeftOpen() {
        let t: Int64 = 1_795_275_690_000
        let first = recorder()
        XCTAssertTrue(first.opening(track: "mic-0", slot: t))
        XCTAssertTrue(first.opening(track: "screen-1", slot: t))
        first.finished(track: "mic-0", slot: t, parts: [Data([1])], size: 1, entry: entry("audio"), picture: nil)
        // The app dies here: screen-1's file of the slot was in memory.
        let second = recorder()
        second.start()
        defer { second.stop() }
        XCTAssertEqual(slots(), ["\(t).json"], "sealed with the one file that was written")
        XCTAssertFalse(second.opening(track: "screen-1", slot: t), "a slot is written once")
        XCTAssertTrue(second.opening(track: "screen-1", slot: t + 30_000))
    }
}

extension SpoolTests {
    /// Astra 10, Fable 5: a track that finishes after its slot was sealed without it does not
    /// write its file, nor a slot event over the sealed one.
    func testALateTrackLeavesTheSealedSlotAsItIs() throws {
        let r = recorder(), t: Int64 = 1_795_275_690_000
        XCTAssertTrue(r.opening(track: "mic-0", slot: t))
        XCTAssertTrue(r.opening(track: "speaker-0", slot: t))
        r.finished(track: "mic-0", slot: t, parts: [Data([1, 2])], size: 2, entry: entry("audio"), picture: nil)
        // the speakers never wrote theirs: past the stale deadline, the slot is sealed with the mic
        r.sealStale(now: Double(t + Slot.ms + 10_001))
        XCTAssertEqual(slots(), ["\(t).json"])
        let sealed = try Data(contentsOf: spool.appendingPathComponent("slots/\(t).json"))
        r.finished(track: "speaker-0", slot: t, parts: [Data([7])], size: 1, entry: entry("audio"), picture: nil)
        XCTAssertEqual(slots(), ["\(t).json"], "one slot")
        XCTAssertEqual(try Data(contentsOf: spool.appendingPathComponent("slots/\(t).json")), sealed, "byte for byte as sealed")
        let late = spool.appendingPathComponent(String(Slot.path(device: "test.mac", track: "speaker-0", slot: t, ext: "mp4").dropFirst()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: late.path), "no file that no event names")
    }

    func testASlotSealedWithNothingWrittenTakesNoTrackAfter() {
        let r = recorder(), t: Int64 = 1_795_275_690_000
        XCTAssertTrue(r.opening(track: "screen-1", slot: t))
        r.sealStale(now: Double(t + Slot.ms + 10_001))
        XCTAssertEqual(slots(), [])
        XCTAssertFalse(r.opening(track: "mic-0", slot: t))
        r.finished(track: "screen-1", slot: t, parts: [Data([1])], size: 1, entry: entry("video"), picture: nil)
        XCTAssertEqual(slots(), [])
    }

    /// Astra 11: an earlier version's spool, one for the whole mind, holds slots of two names;
    /// each goes into the spool of the name it was recorded as, with its files.
    func testAnOldSpoolSplitsByTheDeviceEachSlotNames() throws {
        let mind = spool!, files = FileManager.default
        func slot(_ t: Int64, _ device: String) throws -> String {
            let file = Slot.path(device: device, track: "mic-0", slot: t, ext: "mp4")
            let url = mind.appendingPathComponent(String(file.dropFirst()))
            try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([1]).write(to: url)
            try files.createDirectory(at: mind.appendingPathComponent("slots"), withIntermediateDirectories: true)
            try Slot.event(t: t, tracks: ["mic-0": ["kind": "audio", "file": file, "bytes": 1]]).write(to: mind.appendingPathComponent("slots/\(t).json"))
            return file
        }
        let old = try slot(1_795_275_690_000, "old.mac"), new = try slot(1_795_275_720_000, "new.mac")
        try Data("1795275720000".utf8).write(to: mind.appendingPathComponent("sealed"))
        XCTAssertEqual(Spool.split(mindFolder: mind), 2)
        for (device, file, t) in [("old.mac", old, 1_795_275_690_000), ("new.mac", new, 1_795_275_720_000)] {
            let folder = Spool.folder(in: mind.deletingLastPathComponent(), mind: mind.lastPathComponent, device: device)
            XCTAssertEqual(Spool.waiting(in: folder), 1)
            XCTAssertTrue(files.fileExists(atPath: folder.appendingPathComponent("slots/\(t).json").path))
            XCTAssertTrue(files.fileExists(atPath: folder.appendingPathComponent(String(file.dropFirst())).path), "the file goes with its slot")
            XCTAssertTrue(files.fileExists(atPath: folder.appendingPathComponent("sealed").path))
        }
        XCTAssertEqual(Spool.waiting(in: mind), 0)
        XCTAssertEqual(Spool.split(mindFolder: mind), 0, "once")
    }

    func testTheDeviceOfASlot() {
        XCTAssertEqual(Spool.device(ofSlot: ["tracks": ["mic-0": ["file": "/devices/jane.mac/record/mic-0/x.mp4"]]]), "jane.mac")
        XCTAssertNil(Spool.device(ofSlot: ["tracks": ["a": ["file": "/devices/a/record/x"], "b": ["file": "/devices/b/record/x"]]]))
        XCTAssertNil(Spool.device(ofSlot: ["tracks": [:]]))
    }
}

/// Fable 12, Carbon 5: a resume during a slow open makes no second stream, and an open that a
/// display change or a stop made stale stops the stream it made.
final class OpensTests: XCTestCase {
    func testOneOpenAtATimeAndAStaleOneIsNotKept() {
        var opens = Opens()
        let first = opens.begin(again: true)!
        XCTAssertNil(opens.begin(again: false), "a resume while the start's open runs")
        XCTAssertTrue(opens.keeps(first))
        // the displays change during it: a new open, and the first one's stream goes
        let second = opens.begin(again: true)!
        XCTAssertFalse(opens.keeps(first))
        XCTAssertTrue(opens.keeps(second))
        opens.end(first)
        XCTAssertNil(opens.begin(again: false), "the second still runs")
        opens.end(second)
        let resume = opens.begin(again: false)
        XCTAssertNotNil(resume)
        opens.stop()
        XCTAssertFalse(opens.keeps(resume!), "stopped during the open: the stream stops")
    }
}

final class CaptureTests: XCTestCase {
    func testTheRecordKeeps10FramesASecondByTimeOutOf30() {
        // 30 frames a second for 3 s, with a millisecond of jitter
        var frames: [Double] = []
        for n in 0..<90 { frames.append(Double(n) / 30 + (n % 2 == 0 ? 0.001 : -0.001)) }
        let kept = { (fps: Int) -> [Double] in
            var last: Double?
            var kept: [Double] = []
            for t in frames where CaptureRate.keeps(last: last, now: t, fps: fps) {
                last = t
                kept.append(t)
            }
            return kept
        }
        XCTAssertEqual(kept(10).count, 30)
        XCTAssertEqual(kept(10).prefix(4).map { ($0 * 1000).rounded() }, [1, 99, 201, 299])
        // a camera of 30 at 15
        XCTAssertEqual(kept(15).count, 45)
        // a clock that went back: kept
        XCTAssertTrue(CaptureRate.keeps(last: 5, now: 4, fps: 10))
        XCTAssertEqual(CaptureRate.capture(record: 10, watched: false), 10)
        XCTAssertEqual(CaptureRate.capture(record: 10, watched: true), 30)
    }

    func testTheCaptureRunsForTheUnionOfRecordAndLive() {
        let none: Set<RecordSource> = []
        // live alone starts a source; the record and live together run it once
        XCTAssertEqual(CapturePlan.changes(running: none, record: (none, none), live: (none, [.screens, .mics])), [.start(.screens), .start(.mics)])
        XCTAssertEqual(CapturePlan.changes(running: none, record: (none, [.screens]), live: (none, [.screens])), [.start(.screens)])
        // the first watcher of a source the record has: faster; the last one leaves: as before
        XCTAssertEqual(CapturePlan.changes(running: [.screens], record: ([.screens], [.screens]), live: (none, [.screens])), [.rate(.screens)])
        XCTAssertEqual(CapturePlan.changes(running: [.screens], record: ([.screens], [.screens]), live: ([.screens], none)), [.rate(.screens)])
        // the last watcher of a source only live wanted: it stops
        XCTAssertEqual(CapturePlan.changes(running: [.cameras], record: (none, none), live: ([.cameras], none)), [.stop(.cameras)])
        // the record turned off while somebody watches: its tracks end, the capture goes on
        XCTAssertEqual(CapturePlan.changes(running: [.screens], record: ([.screens], none), live: ([.screens], [.screens])), [.stopRecording(.screens)])
        // the record turned on for a source live alone ran: it starts again, with its tracks
        XCTAssertEqual(CapturePlan.changes(running: [.mics], record: (none, [.mics]), live: ([.mics], [.mics])), [.restart(.mics)])
        // stops first
        XCTAssertEqual(
            CapturePlan.changes(running: [.screens], record: ([.screens], [.cameras]), live: (none, none)), [.stop(.screens), .start(.cameras)])
        XCTAssertEqual(CapturePlan.changes(running: [.screens], record: ([.screens], [.screens]), live: (none, none)), [])
    }

    func testTheSourceOfATrack() {
        XCTAssertEqual(RecordSource.of(track: "screen-1"), .screens)
        XCTAssertEqual(RecordSource.of(track: "camera-0"), .cameras)
        XCTAssertEqual(RecordSource.of(track: "mic-0"), .mics)
        XCTAssertEqual(RecordSource.of(track: "test-2"), .synthetic)
        XCTAssertNil(RecordSource.of(track: "nothing"))
    }
}

/// The transcript track: lines of the transcription stream into the slot in which they came, as
/// one `.jsonl` file that the slot's event names (README, "Listening").
final class TranscriptTrackTests: XCTestCase {
    func testLinesGoIntoTheSlotsFileAndItsEvent() throws {
        let spool = FileManager.default.temporaryDirectory.appendingPathComponent("record-tests-\(UUID().uuidString)")
        let r = Recorder(options: RecordOptions(spool: spool, device: "test.mac"))
        r.start()
        r.set([.transcript])
        // the source starts on the recorder's queue
        for _ in 0..<100 where !r.trackIDs.contains("transcript") { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertEqual(r.trackIDs, ["transcript"])
        let lines = [Data("{\"text\":\"one\"}\n".utf8), Data("{\"text\":\"two\"}\n".utf8)]
        for line in lines { XCTAssertTrue(r.transcribed(line)) }
        r.stop()
        XCTAssertFalse(r.transcribed(lines[0]), "no track after the stop")
        let slots = try FileManager.default.contentsOfDirectory(atPath: spool.appendingPathComponent("slots").path).filter { $0.hasSuffix(".json") }
        // two lines that came in two slots (a boundary between them) are two slots; else one
        let tracks = try slots.map { name -> [String: Any] in
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: spool.appendingPathComponent("slots/\(name)"))) as? [String: Any])
            return try XCTUnwrap((payload["tracks"] as? [String: [String: Any]])?["transcript"])
        }
        XCTAssertEqual(tracks.reduce(0) { $0 + ($1["segments"] as? Int ?? 0) }, 2)
        var written = Data()
        for track in tracks {
            XCTAssertEqual(track["kind"] as? String, "transcript")
            XCTAssertEqual(track["codec"] as? String, "jsonl")
            let file = try XCTUnwrap(track["file"] as? String)
            XCTAssertTrue(file.hasPrefix("/devices/test.mac/record/transcript/") && file.hasSuffix(".jsonl"), file)
            let data = try Data(contentsOf: spool.appendingPathComponent(String(file.dropFirst())))
            XCTAssertEqual(track["bytes"] as? Int, data.count)
            written += data
        }
        XCTAssertEqual(written, lines.reduce(Data(), +))
    }

    func testTheSourceOfTheTranscriptTrack() {
        XCTAssertEqual(RecordSource.of(track: "transcript"), .transcript)
    }

    /// A buffer of the microphone stream as `mic-0`'s sample: channel 0 alone, at its rate, with its time.
    func testAStreamBufferIsAMonoSampleOfItsFirstChannel() throws {
        final class NoFeed: MicrophoneFeed {
            func open(_ take: @escaping @Sendable (AVAudioPCMBuffer, UInt64) -> Void, failed: @escaping @Sendable (String) -> Void) throws
                -> (name: String, close: @Sendable () -> Void)
            { ("none", {}) }
        }
        let r = Recorder(options: RecordOptions(spool: FileManager.default.temporaryDirectory, device: "test.mac"))
        let mic = FeedMic(recorder: r, feed: NoFeed())
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        buffer.frameLength = 480
        for index in 0..<480 {
            buffer.floatChannelData![0][index] = Float(index) / 480
            buffer.floatChannelData![1][index] = -1
        }
        let host = mach_absolute_time()
        let sample = try XCTUnwrap(mic.sample(of: buffer, host: host))
        XCTAssertEqual(sample.numSamples, 480)
        XCTAssertEqual(sample.presentationTimeStamp, CMClockMakeHostTimeFromSystemUnits(host))
        let description = try XCTUnwrap(sample.formatDescription?.audioStreamBasicDescription)
        XCTAssertEqual(description.mSampleRate, 48_000)
        XCTAssertEqual(description.mChannelsPerFrame, 1)
        let mono = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: AVAudioFormat(cmAudioFormatDescription: sample.formatDescription!), frameCapacity: 480))
        mono.frameLength = 480
        XCTAssertEqual(CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: 480, into: mono.mutableAudioBufferList), noErr)
        XCTAssertEqual(mono.floatChannelData![0][240], 0.5)
    }
}

/// The camera keeps a frame when its picture changed, and one a second (`CameraChange`).
final class CameraChangeTests: XCTestCase {
    /// A 1280×720 luma plane: a gradient, sensor noise of ±`noise` levels, and a bright square of
    /// 160 px at `square` (a hand).
    func plane(noise: Int, square: (x: Int, y: Int)? = nil, seed: UInt64) -> [UInt8] {
        var rng = seed
        var out = [UInt8](repeating: 0, count: 1280 * 720)
        for y in 0..<720 {
            for x in 0..<1280 {
                rng = rng &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let n = noise > 0 ? Int(rng >> 33) % (2 * noise + 1) - noise : 0
                var v = 40 + x / 10 + y / 20 + n
                if let square, (square.x..<square.x + 160).contains(x), (square.y..<square.y + 160).contains(y) { v = 220 }
                out[y * 1280 + x] = UInt8(max(16, min(235, v)))
            }
        }
        return out
    }

    func thumb(_ plane: [UInt8]) -> [Float] {
        plane.withUnsafeBufferPointer { CameraChange.thumbnail(luma: $0.baseAddress!, width: 1280, height: 720, bytesPerRow: 1280)! }
    }

    func testNoiseIsBelowAndAHandIsAbove() {
        let still = thumb(plane(noise: 6, seed: 1))
        XCTAssertEqual(still.count, 32 * 18)
        let noisy = thumb(plane(noise: 6, seed: 2))
        XCTAssertLessThan(CameraChange.difference(still, noisy), 0.5 * CameraChange.threshold, "sensor noise of ±6 levels")
        let hand = thumb(plane(noise: 6, square: (600, 300), seed: 3))
        XCTAssertGreaterThan(CameraChange.difference(still, hand), 2 * CameraChange.threshold, "a hand of 160 px")
    }

    func testTheRule() {
        let a: [Float] = Array(repeating: 100, count: 576), b = a.map { $0 + 1 }, c = a.map { $0 + 2 }
        XCTAssertTrue(CameraChange.keeps(last: nil, now: 5, thumb: a), "the first frame")
        XCTAssertFalse(CameraChange.keeps(last: (5, a), now: 5.5, thumb: b), "changed by 1 level: dropped")
        XCTAssertTrue(CameraChange.keeps(last: (5, a), now: 5.5, thumb: c), "changed by 2 levels: kept")
        XCTAssertTrue(CameraChange.keeps(last: (5, a), now: 5.998, thumb: a), "a second after the last kept, also unchanged")
        XCTAssertTrue(CameraChange.keeps(last: (5, a), now: 4, thumb: a), "a clock that went back")
        XCTAssertTrue(CameraChange.keeps(last: (5, a), now: 5.5, thumb: nil), "no copy (another format): kept")
    }

    /// A camera frame as it comes (420v), through the sink's copy.
    func testTheCopyOfAPixelBuffer() throws {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 1280, 720, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &buffer)
        let frame = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(frame, [])
        let luma = CVPixelBufferGetBaseAddressOfPlane(frame, 0)!.assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRowOfPlane(frame, 0)
        for y in 0..<720 { for x in 0..<1280 { luma[y * row + x] = x < 640 ? 50 : 200 } }
        CVPixelBufferUnlockBaseAddress(frame, [])
        let copy = try XCTUnwrap(CameraChange.thumbnail(frame))
        XCTAssertEqual(copy[0], 50)
        XCTAssertEqual(copy[31], 200)
    }
}

/// The audio gate (`SoundGate`): open for a window at or above the threshold and 0.5 s after it.
final class SoundGateTests: XCTestCase {
    func testThresholdAndHold() {
        var gate = SoundGate(dB: -50)
        let below = Float(pow(10, -51.0 / 10)), above = Float(pow(10, -49.0 / 10))
        XCTAssertFalse(gate.take(meanSquare: below, from: 0, count: 960), "room noise")
        XCTAssertTrue(gate.take(meanSquare: above, from: 960, count: 960), "quiet speech")
        XCTAssertEqual(gate.openUntil, 1920 + 24_000)
        XCTAssertTrue(gate.take(meanSquare: 0, from: 1920 + 24_000 - 960, count: 960), "the hold: the end of a word")
        XCTAssertFalse(gate.take(meanSquare: 0, from: 1920 + 24_000, count: 960), "0.5 s after the last sound")
        XCTAssertFalse(gate.isOpen(at: 1920 + 24_000))
        gate.reset()
        XCTAssertFalse(gate.isOpen(at: 0))
        XCTAssertEqual(SoundGate(dB: SoundGate.microphoneDB).threshold, 1e-5, accuracy: 1e-9)
    }
}

/// An audio track writes silence without its encoder, and the file still plays the whole slot on
/// time: a beep at each second, except seconds 10 to 19 of the slot, which are silent, with 3 s of
/// them not even given (a capture that stopped).
final class SilentAudioTests: XCTestCase {
    func sample(_ samples: [Float], channels: Int, host: CMTime) -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * channels), mFramesPerPacket: 1, mBytesPerFrame: UInt32(4 * channels), mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000), presentationTimeStamp: host, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreate(
            allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil, formatDescription: format,
            sampleCount: samples.count / channels, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
            sampleBufferOut: &sample)
        var copy = samples
        copy.withUnsafeMutableBytes { raw in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: UInt32(channels), mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
            _ = CMSampleBufferSetDataBufferFromAudioBufferList(sample!, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, bufferList: &list)
        }
        return sample!
    }

    /// The host time of a wall time, through the recorder's anchor.
    func host(_ wallMs: Double) -> CMTime {
        let anchor = HostClock.shared.current
        return CMTime(value: Int64(anchor.hostNanos) + Int64(((wallMs - anchor.wallMs) * 1_000_000).rounded()), timescale: 1_000_000_000)
    }

    /// Records `seconds` of `sound(second, sample in second)` from 2 s before a slot, in buffers of
    /// 512 samples, leaving out the seconds in `missing`; answers the slot's decoded samples (mono),
    /// its event entry and the track's counts.
    func record(id: String, channels: Int, bitrate: Int, dB: Float, missing: Range<Int> = 0..<0, sound: (Int, Int) -> Float) throws
        -> (decoded: [Float], start: Double, entry: [String: Any], counts: (encoded: Int, silent: Int, opens: Int))
    {
        let spool = FileManager.default.temporaryDirectory.appendingPathComponent("record-tests-\(UUID().uuidString)")
        let r = Recorder(options: RecordOptions(spool: spool, device: "test.mac"))
        r.records([.mics, .speakers])
        let track = AudioTrack(id: id, recorder: r, channels: channels, bitrate: bitrate, thresholdDB: dB)
        let slot = Slot.start(nowMs()) - 5 * Slot.ms
        let first = Double(slot) - 2000
        var n = 0
        while n < 34 * 48_000 {
            let second = Int((Double(n) / 48_000 - 2).rounded(.down))
            if !missing.contains(second) {
                var samples = [Float](repeating: 0, count: 512 * channels)
                for i in 0..<512 {
                    let at = n + i - 2 * 48_000
                    let v = sound(Int((Double(at) / 48_000).rounded(.down)), (at % 48_000 + 48_000) % 48_000)
                    for c in 0..<channels { samples[i * channels + c] = v }
                }
                track.append(sample(samples, channels: channels, host: host(first + Double(n) / 48)), hostTime: host(first + Double(n) / 48))
            }
            n += 512
        }
        let counts = track.written
        track.stop()
        let event = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: spool.appendingPathComponent("slots/\(slot).json"))) as? [String: Any])
        let entry = try XCTUnwrap((event["tracks"] as? [String: [String: Any]])?[id])
        let file = spool.appendingPathComponent(String(try XCTUnwrap(entry["file"] as? String).dropFirst()))
        // Decoded by AVFoundation, as a player would.
        let asset = AVURLAsset(url: file)
        let audio = try XCTUnwrap(asset.tracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: audio, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: channels,
        ])
        reader.add(out)
        XCTAssertTrue(reader.startReading())
        var decoded: [Float] = [], start: Double?
        while let buffer = out.copyNextSampleBuffer() {
            if start == nil { start = CMTimeGetSeconds(buffer.presentationTimeStamp) }
            guard let block = buffer.dataBuffer else { continue }
            var floats = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / 4)
            _ = floats.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
            for i in stride(from: 0, to: floats.count, by: channels) { decoded.append(floats[i]) }
        }
        XCTAssertEqual(reader.status, .completed)
        return (decoded, try XCTUnwrap(start), entry, counts)
    }

    func rms(_ samples: ArraySlice<Float>) -> Double {
        10 * log10(samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(max(1, samples.count)) + 1e-12)
    }

    /// Where the beep of each second begins in the decoded samples, from the slot's start. (Not
    /// second 0: the decoder leaves out the first samples of a file, its own delay.)
    func onsets(_ decoded: [Float], start: Double) -> [Int: Int] {
        var out: [Int: Int] = [:]
        for second in 1..<30 {
            let from = max(0, Int((Double(second) - 0.3 - start) * 48_000)), to = min(decoded.count, from + 48_000)
            guard from < to, let i = decoded[from..<to].firstIndex(where: { abs($0) > 0.05 }) else { continue }
            out[second] = i + Int((start * 48_000).rounded()) - second * 48_000
        }
        return out
    }

    func testBeepsAndSilenceDecodeToTheSlotsLengthOnTime() throws {
        let beep = { (second: Int, i: Int) -> Float in
            (10..<20).contains(second) || i >= 4800 ? 0 : Float(sin(2 * Double.pi * 880 * Double(i) / 48_000) * 0.3)
        }
        let (decoded, start, entry, counts) = try record(id: "mic-0", channels: 1, bitrate: 64_000, dB: SoundGate.microphoneDB, missing: 12..<15, sound: beep)
        // The reference: a gate that never closes, so one encoder runs, as before silence was written.
        let always = try record(id: "mic-0", channels: 1, bitrate: 64_000, dB: -.infinity, sound: beep)
        XCTAssertEqual(always.counts.opens, 1)
        XCTAssertEqual(always.counts.silent, 0)
        // The same length, from the same first packet (within one packet of the slot's start).
        XCTAssertEqual(start, always.start)
        XCTAssertLessThan(start, 1024.0 / 48_000)
        XCTAssertEqual(decoded.count, always.decoded.count)
        XCTAssertEqual(Double(decoded.count) / 48_000 + start, 30, accuracy: 0.06, "the slot, less the decoder's own delay")
        // Each beep at the same sample as in the reference: the timeline stays whole across the
        // silences, the encoder's restarts and the 3 s with no input.
        let reference = onsets(always.decoded, start: always.start)
        XCTAssertEqual(reference.keys.sorted(), Array(1..<10) + Array(20..<30))
        XCTAssertEqual(Set(reference.values).count, 1, "the reference's beeps are all at one offset: \(reference)")
        XCTAssertEqual(onsets(decoded, start: start), reference)
        let shift = Double(reference[1] ?? 0) / 48_000
        let at = { (seconds: Double) in max(0, Int(((seconds + shift - start) * 48_000).rounded())) }
        for second in 1..<30 {
            let beepRange = at(Double(second) + 0.01)..<at(Double(second) + 0.09)
            let between = rms(decoded[at(Double(second) + 0.3)..<at(Double(second) + 0.95)])
            if (10..<20).contains(second) {
                XCTAssertLessThan(rms(decoded[beepRange]), -90, "second \(second) is silent")
            } else {
                XCTAssertEqual(rms(decoded[beepRange]), rms(always.decoded[beepRange]), accuracy: 0.5, "the beep of second \(second)")
                XCTAssertEqual(rms(decoded[beepRange]), -13.5, accuracy: 0.5)
            }
            XCTAssertLessThan(between, -70, "between the beeps of second \(second)")
        }
        // The levels are of the sound, not of what was encoded.
        let levels = try XCTUnwrap(entry["levels"] as? [Int])
        XCTAssertEqual(levels, always.entry["levels"] as? [Int])
        XCTAssertEqual(levels[0], -10)
        XCTAssertEqual(levels[1], -99)
        XCTAssertEqual(levels[22], -99, "second 11: silent")
        XCTAssertEqual(entry["peak"] as? Double, -10.5)
        // 20 beeps in the slot and 4 more around it, each opening the encoder; ten silent seconds.
        XCTAssertEqual(counts.opens, 24)
        XCTAssertGreaterThan(counts.silent, 10 * 47)
    }

    func testASilentSlotNeverStartsTheEncoder() throws {
        let (decoded, start, entry, counts) = try record(id: "speaker-0", channels: 2, bitrate: 128_000, dB: SoundGate.speakersDB) { _, _ in 0 }
        XCTAssertEqual(Double(decoded.count) / 48_000 + start, 30, accuracy: 0.06, "the slot, less the decoder's own delay")
        XCTAssertTrue(decoded.allSatisfy { $0 == 0 }, "zeros")
        XCTAssertEqual(counts.opens, 0)
        XCTAssertEqual(counts.encoded, 0)
        XCTAssertEqual(entry["rms"] as? Double, -120)
        XCTAssertEqual(entry["levels"] as? [Int], Array(repeating: -99, count: 60))
        XCTAssertLessThan(try XCTUnwrap(entry["bytes"] as? Int), 30_000)
    }
}
