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
// ended, 1008; a hang of 120 s) ends that connection, and the next try is on the next one.
// It says `{ uploaded, waiting }`, `{ failed, waiting, retryInSeconds }`, `{ dropped, why }` and
// `{ fallback }`.
import { existsSync, readFileSync, readdirSync, rmdirSync, rmSync, statSync } from "node:fs";
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

/** The uploads of `spool` on `link`, until `end()`. `everyMs` is the look at an empty spool. */
export function recordUploads({ link, spool, say, maxBytes = 5e9, everyMs = 2000, sleep = pause }) {
  const local = (path) => join(spool, path.slice(1));
  const slotFile = (t) => join(spool, "slots", `${t}.json`);

  /** The waiting slots, oldest first. */
  function waitingSlots() {
    const folder = join(spool, "slots");
    if (!existsSync(folder)) return [];
    return readdirSync(folder)
      .filter((file) => /^\d+\.json$/.test(file))
      .map((file) => Number(file.slice(0, -5)))
      .sort((a, b) => a - b);
  }

  /** The event first (a slot with no event is no slot to the uploader), then its files. */
  function remove(t, payload) {
    rmSync(slotFile(t), { force: true });
    for (const [path] of filesOf(payload)) {
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

  /** Drops the oldest slots while the spool holds more than `maxBytes`. */
  function cap(slots) {
    const sizes = slots.map((t) => {
      try {
        const payload = JSON.parse(readFileSync(slotFile(t), "utf8"));
        return filesOf(payload).reduce((sum, [path]) => sum + (existsSync(local(path)) ? statSync(local(path)).size : 0), 0);
      } catch {
        return 0;
      }
    });
    let total = sizes.reduce((a, b) => a + b, 0);
    while (total > maxBytes && slots.length > 1) {
      const t = slots.shift();
      total -= sizes.shift();
      remove(t, JSON.parse(readFileSync(slotFile(t), "utf8")));
      say({ dropped: t, why: `the spool holds more than ${maxBytes} bytes` });
    }
  }

  let saidFallback = false;
  /** The connection the slot is on: a failure of it ends it. */
  let connection;

  async function upload(t) {
    // within the try's 120 s: a wait that outlives it would upload the slot a second time
    connection = await link.now(110_000);
    const { device, itx } = connection;
    const files = itx.r2;
    const payload = JSON.parse(readFileSync(slotFile(t), "utf8"));
    const present = filesOf(payload).filter(([path]) => existsSync(local(path)));
    const gone = filesOf(payload).filter(([path]) => !existsSync(local(path)));
    // the links of the slot in one go; and for a file gone from the spool (it went up before, or
    // the spool's cap dropped it) the mind says which
    const [links, heads] = await Promise.all([
      Promise.all(present.map(([path]) => files.presign({ key: path.slice(1), method: "PUT", expiresInSeconds: 600 }))),
      Promise.all(gone.map(([path]) => files.head(path.slice(1)))),
    ]);
    await Promise.all(
      present.map(([path, contentType], index) =>
        putFile({
          r2: files,
          key: path.slice(1),
          path: local(path),
          contentType,
          url: links[index].url,
          fellBack: () => {
            if (!saidFallback) say({ fallback: "signed upload failing; files go through the connection" });
            saidFallback = true;
          },
        }).catch((error) => {
          throw Object.assign(new Error(`${path}: ${error?.message ?? error}`), { cause: error });
        }),
      ),
    );
    const missing = gone.filter((_, index) => !heads[index]).map(([path]) => path);
    if (missing.length) {
      remove(t, payload);
      say({ dropped: t, why: `not in the spool nor in the mind: ${missing.join(", ")}` });
      return false;
    }
    try {
      await device.append({ type: "record/slot-stored", payload, idempotencyKey: `record/slot-stored/${t}` });
    } catch (error) {
      // the mind has another event for this slot: it keeps it, and the files are the newer ones
      if (error?.code !== "IDEMPOTENCY_CONFLICT") throw error;
      say({ failed: `slot ${t}: ${error.message}`, kept: "the mind's event" });
    }
    remove(t, payload);
    return true;
  }

  let isEnding = false;
  let ending;
  const ended = new Promise((resolve) => (ending = resolve));
  /** A wait that the end cuts short. */
  const wait = (ms) => Promise.race([sleep(ms), ended]);

  const loop = (async () => {
    let backoff = 0;
    while (!isEnding) {
      const slots = waitingSlots();
      if (slots.length > 1) cap(slots);
      if (slots.length === 0) {
        await wait(everyMs);
        continue;
      }
      let timer;
      try {
        // a connection that hangs (no network) is given up and made again
        const isUploaded = await Promise.race([
          upload(slots[0]),
          new Promise((_, reject) => (timer = setTimeout(() => reject(new Error("no answer in 120 s")), 120_000))),
        ]).finally(() => clearTimeout(timer));
        backoff = 0;
        if (isUploaded) say({ uploaded: slots[0], waiting: slots.length - 1 });
      } catch (error) {
        if (isConnectionError(error)) link.broke(connection, error);
        backoff = Math.min(60, Math.max(1, backoff * 2));
        say({ failed: String(error?.message ?? error).slice(0, 300), waiting: slots.length, retryInSeconds: backoff });
        await wait(backoff * 1000);
      }
    }
  })();

  return {
    /** Ends after the slot it is on. */
    async end() {
      isEnding = true;
      ending();
      await loop;
    },
  };
}
