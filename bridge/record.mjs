// record.mjs: the job `record` of mind.mjs: the recorder's spool (Sources/Record) into the mind,
// slot by slot.
//
// The app (Sources/VoiceMeetMac/DeviceRecord.swift) starts it with `{ job: "record", start: true,
// spool, maxBytes? }` and ends it with `{ job: "record", stop: true }`; it then ends the slot it is
// on. The spool holds, for each slot of 30 seconds, `slots/<t>.json` (the payload of the event
// `record/slot-stored`) and the files it names, each at its path in the mind's files. Oldest slot
// first, this puts every file of the slot into the mind's files (upload.mjs: a signed PUT that
// streams it from disk, the links of one slot asked for in one go), THEN appends the event to
// /devices/<name> with the idempotency key `record/slot-stored/<t>`, then deletes the slot from the
// spool. So an event never names a file that is not there, and a restart goes on where it stopped:
// a file that is gone from the spool went up before (it is deleted only after the append), and the
// append again is the same event. Failures wait 1 s, then twice as long each time, at most 60 s.
// Over `maxBytes` (5 GB) the oldest slots are dropped.
//
// It is on the connection of mind.mjs, as the person (the iterate CLI's own sign-in: the Mac's key
// lends and does nothing else). A failure that says the connection is gone (a session whose sign-in
// ended, 1008; 120 s with no answer and no byte) ends that connection, and the next try is on the
// next one. An attempt that is given up is aborted: its PUTs end, and it appends and deletes
// nothing after that. A PUT's own failure (it goes beside the connection) does not end it.
//
// The job reads the spool's list once at its start and keeps its slots and their bytes; then it
// hears each new slot from the app, `{ job: "record", slot: <t> }` when the recorder seals it, and
// wakes for it. Until the first such line it looks at the list every `everyMs`, as before; after
// it, once a minute (a slot whose line was lost). Each slot's manifest is read once for its size.
// A slot that fails 3 times for its own reason (not the connection, not a 5xx of the signed route,
// which waits for the route) is set aside in `slots/failed/`: the next slots go, and the cap drops
// the slots set aside first. Its event goes to the device that its files name: a slot recorded
// before this Mac's name changed goes to the old name, with the files it names.
// It says `{ uploaded, waiting }`, `{ waiting }` (a new slot), `{ failed, waiting, retryInSeconds }`,
// `{ setAside, why }`, `{ dropped, why }` and `{ fallback }`.
import { existsSync, mkdirSync, readFileSync, readdirSync, renameSync, rmdirSync, rmSync, statSync } from "node:fs";
import { dirname, join } from "node:path";
import { isConnectionError } from "./mind-connection.mjs";
import { putFile } from "./upload.mjs";

const pause = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/** Every file a slot's event names, with its content type. */
function filesOf(payload) {
  return Object.values(payload.tracks).flatMap((track) => [
    [track.file, track.kind === "audio" ? "audio/mp4" : "video/mp4"],
    ...(track.picture ? [[track.picture, "image/jpeg"]] : []),
  ]);
}

/** The device whose files a slot names: `/devices/<name>/…`. */
const ownerOf = (payload) => filesOf(payload).map(([path]) => /^\/devices\/([^/]+)\//.exec(path)?.[1]).find(Boolean);

/** Inserts `t` into the sorted list `list`. A new slot is the newest: it goes at the end. */
function insert(list, t) {
  if (!list.length || list.at(-1) < t) return list.push(t);
  let low = 0;
  for (let high = list.length; low < high; ) {
    const middle = (low + high) >> 1;
    if (list[middle] < t) low = middle + 1;
    else high = middle;
  }
  if (list[low] !== t) list.splice(low, 0, t);
}

/** The uploads of `spool` on `link`, until `end()`. `everyMs` is the look at the spool's list
 *  before the app tells slots; `idleMs` the time with no answer and no byte that gives an attempt
 *  up. */
export function recordUploads({ link, spool, say, maxBytes = 5e9, everyMs = 2000, idleMs = 120_000, mostOwnFailures = 3, sleep = pause }) {
  const local = (path) => join(spool, path.slice(1));
  const slots = join(spool, "slots");
  const aside = join(slots, "failed");
  const slotFile = (t, folder = slots) => join(folder, `${t}.json`);

  /** The waiting slots and those set aside, oldest first, and the bytes of each. */
  const waiting = [];
  const setAside = [];
  const bytes = new Map();
  let total = 0;
  /** The failures of a slot for its own reason, by slot. */
  const failures = new Map();

  const read = (t, folder = slots) => JSON.parse(readFileSync(slotFile(t, folder), "utf8"));
  function sizeOf(t, folder) {
    try {
      return filesOf(read(t, folder)).reduce((sum, [path]) => {
        try {
          return sum + statSync(local(path)).size;
        } catch {
          return sum;
        }
      }, 0);
    } catch {
      return 0;
    }
  }
  function add(list, t, folder) {
    if (bytes.has(t) && list.includes(t)) return false;
    const size = sizeOf(t, folder);
    bytes.set(t, size);
    total += size;
    insert(list, t);
    return true;
  }
  function forget(list, t) {
    const at = list.indexOf(t);
    if (at !== -1) list.splice(at, 1);
    total -= bytes.get(t) ?? 0;
    bytes.delete(t);
    failures.delete(t);
  }
  /** The slots of a folder's list that the index does not have yet. */
  function scan(list, folder) {
    if (!existsSync(folder)) return;
    for (const file of readdirSync(folder))
      if (/^\d+\.json$/.test(file)) {
        const t = Number(file.slice(0, -5));
        if (!list.includes(t)) add(list, t, folder);
      }
  }

  /** The event first (a slot with no event is no slot to the uploader), then its files. */
  function remove(t, payload, folder = slots) {
    rmSync(slotFile(t, folder), { force: true });
    for (const [path] of payload ? filesOf(payload) : []) {
      rmSync(local(path), { force: true });
      // the empty folders of an hour, a day and a track
      for (let folder = dirname(local(path)); folder.startsWith(join(spool, "devices") + "/"); ) {
        try {
          rmdirSync(folder);
        } catch {
          break;
        }
        folder = dirname(folder);
      }
    }
  }

  /** Drops the oldest slots, those set aside first, while the spool holds more than `maxBytes`. */
  function cap() {
    while (total > maxBytes && setAside.length + waiting.length > 1) {
      const [list, folder] = setAside.length ? [setAside, aside] : [waiting, slots];
      const t = list[0];
      let payload;
      try {
        payload = read(t, folder);
      } catch {}
      // a slot whose manifest does not read goes with its manifest alone
      try {
        remove(t, payload, folder);
      } catch {}
      forget(list, t);
      say({ dropped: t, why: `the spool holds more than ${maxBytes} bytes` });
    }
  }

  let saidFallback = false;

  /** Slot `t` into the mind. Every wait races `signal`; after it, nothing is appended or deleted. */
  async function upload(t, signal, alive) {
    const aborted = new Promise((_, reject) => signal.addEventListener("abort", () => reject(signal.reason), { once: true }));
    aborted.catch(() => {});
    const within = (promise) => Promise.race([promise, aborted]);
    const connection = await within(link.now());
    const fail = (error) => Object.assign(error instanceof Error ? error : new Error(String(error)), { connection });
    try {
      const { itx } = connection;
      const files = itx.r2;
      const payload = read(t);
      const owner = ownerOf(payload);
      const device = owner ? itx.cd(`/devices/${owner}`) : connection.device;
      const present = filesOf(payload).filter(([path]) => existsSync(local(path)));
      const gone = filesOf(payload).filter(([path]) => !existsSync(local(path)));
      // the links of the slot in one go; and for a file gone from the spool (it went up before, or
      // the spool's cap dropped it) the mind says which
      const [links, heads] = await within(
        Promise.all([
          Promise.all(present.map(([path]) => files.presign({ key: path.slice(1), method: "PUT", expiresInSeconds: 600 }))),
          Promise.all(gone.map(([path]) => files.head(path.slice(1)))),
        ]),
      );
      alive();
      await within(
        Promise.all(
          present.map(([path, contentType], index) =>
            putFile({
              r2: files,
              key: path.slice(1),
              path: local(path),
              contentType,
              url: links[index].url,
              signal,
              said: alive,
              fellBack: () => {
                if (!saidFallback) say({ fallback: "signed upload failing; files go through the connection" });
                saidFallback = true;
              },
            }).catch((error) => {
              throw Object.assign(new Error(`${path}: ${error?.message ?? error}`), { cause: error, put: error?.put, status: error?.status });
            }),
          ),
        ),
      );
      signal.throwIfAborted();
      const missing = gone.filter((_, index) => !heads[index]).map(([path]) => path);
      if (missing.length) {
        remove(t, payload);
        say({ dropped: t, why: `not in the spool nor in the mind: ${missing.join(", ")}` });
        return false;
      }
      try {
        await within(device.append({ type: "record/slot-stored", payload, idempotencyKey: `record/slot-stored/${t}` }));
      } catch (error) {
        // the mind has another event for this slot: it keeps it, and the files are the newer ones
        if (error?.code !== "IDEMPOTENCY_CONFLICT") throw error;
        say({ failed: `slot ${t}: ${error.message}`, kept: "the mind's event" });
      }
      signal.throwIfAborted();
      remove(t, payload);
      return true;
    } catch (error) {
      throw fail(error);
    }
  }

  let isEnding = false;
  /** Wakes the wait now: a new slot, or the end. */
  let wake = () => {};
  /** A wait that a new slot or the end cuts short: true when it was cut. */
  const wait = (ms) =>
    new Promise((resolve) => {
      let timer;
      const done = (woken) => {
        clearTimeout(timer);
        wake = () => {};
        resolve(woken);
      };
      wake = () => done(true);
      if (sleep === pause) timer = setTimeout(() => done(false), ms);
      else sleep(ms).then(() => done(false));
    });
  /** True once the app has told a slot: the look at the list is then once a minute. */
  let isTold = false;

  const loop = (async () => {
    let backoff = 0;
    scan(waiting, slots);
    scan(setAside, aside);
    while (!isEnding) {
      cap();
      const t = waiting[0];
      if (t === undefined) {
        if (!(await wait(isTold ? 60_000 : everyMs))) scan(waiting, slots);
        continue;
      }
      const attempt = new AbortController();
      let timer;
      const alive = () => {
        clearTimeout(timer);
        timer = setTimeout(() => attempt.abort(new Error(`no answer in ${idleMs / 1000} s`)), idleMs);
      };
      alive();
      try {
        const isUploaded = await upload(t, attempt.signal, alive);
        backoff = 0;
        forget(waiting, t);
        if (isUploaded) say({ uploaded: t, waiting: waiting.length });
      } catch (error) {
        // only the wait with no answer aborts before here; the abort now ends the other PUTs
        const isStalled = attempt.signal.aborted;
        attempt.abort(error);
        const isConnection = isStalled || isConnectionError(error);
        // a PUT's reset says nothing of the connection; a 5xx of the signed route waits for it
        if (isConnection && (isStalled || !error.put)) link.broke(error.connection, error);
        const isOwn = !isConnection && !(error.status >= 500);
        const failed = isOwn ? (failures.get(t) ?? 0) + 1 : 0;
        if (isOwn) failures.set(t, failed);
        backoff = Math.min(60, Math.max(1, backoff * 2));
        say({ failed: String(error?.message ?? error).slice(0, 300), waiting: waiting.length, retryInSeconds: backoff });
        if (failed >= mostOwnFailures) {
          setSlotAside(t, error);
          continue;
        }
        await wait(backoff * 1000);
      } finally {
        clearTimeout(timer);
      }
    }
  })();

  function setSlotAside(t, error) {
    try {
      mkdirSync(aside, { recursive: true });
      renameSync(slotFile(t), slotFile(t, aside));
    } catch {}
    const size = bytes.get(t) ?? 0;
    forget(waiting, t);
    bytes.set(t, size);
    total += size;
    insert(setAside, t);
    say({ setAside: t, why: `${mostOwnFailures} failures: ${String(error?.message ?? error).slice(0, 300)}` });
  }

  return {
    /** The app sealed slot `t`: it waits now, and the job wakes for it. */
    sealed(t) {
      isTold = true;
      if (!Number.isFinite(t) || waiting.includes(t) || !existsSync(slotFile(t))) return;
      add(waiting, t, slots);
      say({ waiting: waiting.length });
      wake();
    },
    /** Ends after the slot it is on. */
    async end() {
      isEnding = true;
      wake();
      await loop;
    },
  };
}
