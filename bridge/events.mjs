// events.mjs: the job `events` of mind.mjs: what this Mac tells its mind about itself, as events
// on the context /devices/<name> (the same name as the lend, `itx.<name>`).
//
// The app (Sources/VoiceMeetMac/DeviceEvents.swift) sends `{ job: "events", event: { type,
// payload, ephemeral?, idempotencyKey? } }` for each event. An ephemeral event reaches whoever
// listens now and is in no log. It goes on the connection of mind.mjs (the person's own sign-in:
// the Mac's key lends and does nothing else), and what came in is appended every fifth of a
// second, in one call, in order. While the connection is down the events wait; a batch that failed
// waits again at the front.
//
// It also reads the context back, for the app's activity log: the events of `device/act-started`,
// `device/act-ended` and `device/presence-changed`, and no other. On each connection it subscribes
// to those types (the mind filters them), then reads the log backwards from its head, a page of
// 500 offsets at a time, until it has 50 acts, the start of the log, or 10 pages (5,000 offsets
// scanned). `readEvents` cannot filter by type: each event of another type (most of the log is
// keys and moves) is dropped as its page comes. It keeps no event: only the offsets of the last
// 200 it told, so that it tells each once. A connection again reads them again: the app folds an
// event it has once more into the same row.
//
// It says `{ sent }`, `{ failed, dropped? }` and `{ event: { type, payload, offset, createdAt } }`.
// After the connection's `{ connected: true }` (mind.mjs says it) the app says its presence again.
//
// THE LOG OF EVERY EVENT, for the app's Activity window, only while that window is open: the app
// says `{ job: "events", log: "start" }`, then `{ log: "older", before: <offset> }` as the person
// scrolls back, and `{ log: "stop" }` when the window closes. On "start", and again on each new
// connection while it is open, the job says `{ log: { reset: true } }`, subscribes to every kept
// type ("*": the mind sends no ephemeral event to such a row), and says the newest page. A page is
// `{ log: { page: [event, …] newest first, before, more } }`: at most 100 events, from at most
// 5,000 offsets scanned backwards; `before` is the offset to ask from next, `more` whether the log
// goes on below it. Each new event is `{ log: { event } }`. An event's strings are cut at 2,000
// characters and its lists at 100 items (a window's text is up to 20,000): the window shows them,
// and the mind keeps them whole. The job holds no event of the log: the app holds at most 500.
import { isConnectionError } from "./mind-connection.mjs";

/** The input events that go first when too many wait: presence and the rest are kept. */
const isInput = (event) => /^device\/(key-pressed|mouse-|scrolled)/.test(event?.type);

/** The types the app's activity log reads back. */
export const READ_BACK = ["device/act-started", "device/act-ended", "device/presence-changed"];
/** The backward read: offsets a page, at most this many pages, and the acts it looks for. */
const PAGE = 500;
const MOST_PAGES = 10;
const ACTS = 50;
/** How many offsets of told events it remembers, to tell each once. */
const REMEMBERED = 200;

const isReadBack = (event) => READ_BACK.includes(event?.type) && typeof event.offset === "number";

/**
 * The context's events of `READ_BACK` to `say` as `{ event }`, each once: the new ones as the
 * subscription brings them, and the last `ACTS` acts read backwards (`PAGE` × `MOST_PAGES`
 * offsets at most). The answer ends it.
 */
function readBack(device, say) {
  let ended = false;
  let subscription;
  const told = new Set();
  const tell = (event) => {
    if (ended || told.has(event.offset)) return;
    told.add(event.offset);
    // a Set iterates in the order of insertion: the first is the oldest told
    if (told.size > REMEMBERED) told.delete(told.values().next().value);
    const { type, payload, offset, createdAt } = event;
    say({ event: { type, payload, offset, createdAt } });
  };
  // every other type is dropped before anything is copied
  const plain = (batch) => JSON.parse(JSON.stringify((batch ?? []).filter(isReadBack)));

  (async () => {
    subscription = await device.subscribe({ consumes: READ_BACK, target: (batch) => plain(batch).forEach(tell) });
    if (ended) return subscription[Symbol.dispose]();
    // the head, and where the context's version starts: no read goes below it
    const probe = await device.readEvents(Number.MAX_SAFE_INTEGER, 1);
    const floor = Math.max(0, (probe.versionStartedAtOffset ?? 1) - 1);
    let to = probe.scannedThroughOffset;
    let found = [];
    let acts = 0;
    for (let pages = 0; pages < MOST_PAGES && to > floor && acts < ACTS && !ended; pages++) {
      const from = Math.max(floor, to - PAGE);
      const window = [];
      // a page is cut by count and by bytes, and ephemeral events leave gaps: read on to `to`
      for (let after = from; after < to; ) {
        const page = await device.readEvents(after, to - after);
        window.push(...plain(page.events).filter((event) => event.offset <= to));
        if (page.atHead || page.scannedThroughOffset <= after) break;
        after = page.scannedThroughOffset;
      }
      acts += window.filter((event) => event.type === READ_BACK[0]).length;
      found = [...window, ...found].slice(-REMEMBERED);
      to = from;
    }
    found.forEach(tell);
  })().catch((error) => ended || say({ failed: `read back: ${String(error?.message ?? error).slice(0, 300)}` }));

  return () => {
    ended = true;
    subscription?.[Symbol.dispose]();
  };
}

/** The log's read for the window: events a page, offsets scanned for one page at most, and the
 *  bounds of one event's strings and lists. */
export const LOG_PAGE = 100;
const LOG_MOST_SCANNED = 5_000;
const TEXT_MOST = 2_000;
const LIST_MOST = 100;

/** A copy of a payload with its long strings and lists cut. */
function bounded(value, depth = 0) {
  if (typeof value === "string") return value.length > TEXT_MOST ? `${value.slice(0, TEXT_MOST)}…` : value;
  if (value === null || typeof value !== "object") return value;
  if (depth > 6) return "…";
  if (Array.isArray(value)) return value.slice(0, LIST_MOST).map((item) => bounded(item, depth + 1));
  return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, bounded(item, depth + 1)]));
}

const logged = ({ type, payload, offset, createdAt }) => ({ type, payload: bounded(JSON.parse(JSON.stringify(payload ?? {}))), offset, createdAt });

/**
 * Every kept event of the context, for the window: the subscription's new ones as `{ log: { event }
 * }`, and pages read backwards on request. `older(before)` says the page below `before`; the
 * answer's `end()` ends it.
 */
function readLog(device, say) {
  let ended = false;
  let subscription;
  let floor = 0;
  const ready = (async () => {
    subscription = await device.subscribe({
      consumes: ["*"],
      target: (batch) => {
        if (ended) return;
        for (const event of batch ?? []) if (typeof event?.offset === "number" && !event.ephemeral) say({ log: { event: logged(event) } });
      },
    });
    if (ended) return subscription[Symbol.dispose]();
    const probe = await device.readEvents(Number.MAX_SAFE_INTEGER, 1);
    floor = Math.max(0, (probe.versionStartedAtOffset ?? 1) - 1);
    return probe.scannedThroughOffset;
  })();

  async function older(before) {
    const head = await ready;
    if (ended) return;
    let to = Math.min((before ?? head + 1) - 1, head);
    let found = [];
    let scanned = 0;
    while (to > floor && found.length < LOG_PAGE && scanned < LOG_MOST_SCANNED && !ended) {
      const from = Math.max(floor, to - PAGE);
      const window = [];
      // a page is cut by count and by bytes, and ephemeral events leave gaps: read on to `to`
      for (let after = from; after < to; ) {
        const page = await device.readEvents(after, to - after);
        for (const event of page.events ?? []) if (typeof event?.offset === "number" && event.offset <= to && !event.ephemeral) window.push(logged(event));
        if (page.atHead || page.scannedThroughOffset <= after) break;
        after = page.scannedThroughOffset;
      }
      scanned += to - from;
      found = [...window, ...found];
      to = from;
    }
    if (ended) return;
    const page = found.slice(-LOG_PAGE).reverse();
    const next = found.length > LOG_PAGE ? page.at(-1).offset : to + 1;
    say({ log: { page, before: next, more: next - 1 > floor } });
  }

  return {
    older: (before) => older(before).catch((error) => ended || say({ log: { failed: String(error?.message ?? error).slice(0, 300) } })),
    end() {
      ended = true;
      subscription?.[Symbol.dispose]();
    },
  };
}

/** The queue and its sender on `link` (mind.mjs): `add(event)`, `send()` (also every `everyMs`),
 *  `log(line)` (the window's read: `{ log: "start" | "older" | "stop", before? }`), `end()`. */
export function deviceEvents({ link, say, mostWaiting = 2_000, everyMs = 200 }) {
  let endRead = () => {};
  /** The window's read while it is open, on the connection now. */
  let logOpen = false;
  let logRead;
  let device;
  const openLog = () => {
    logRead?.end();
    say({ log: { reset: true } });
    logRead = readLog(device, say);
    logRead.older();
  };
  const unhook = link.each(async (connection) => {
    endRead();
    endRead = readBack(connection.device, say);
    device = connection.device;
    if (logOpen) openLog();
  });
  let waiting = [];
  let sent = 0;
  let refusals = 0;
  let sending;

  // At most `mostWaiting` wait: a Mac with no network drops its oldest moves and keys, it does
  // not grow.
  function bound() {
    while (waiting.length > mostWaiting) {
      const input = waiting.findIndex(isInput);
      waiting.splice(input === -1 ? 0 : input, 1);
    }
  }

  async function sendOnce() {
    if (waiting.length === 0) return;
    const connection = await link.now();
    if (waiting.length === 0) return;
    const batch = waiting;
    waiting = [];
    try {
      await connection.device.append(...batch);
      sent += batch.length;
      refusals = 0;
      say({ sent });
    } catch (error) {
      const failed = String(error?.message ?? error).slice(0, 300);
      const isBroken = isConnectionError(error);
      // the mind refused the batch three times: it is dropped, so it holds back nothing
      if (!isBroken && ++refusals >= 3) {
        refusals = 0;
        return say({ failed, dropped: batch.length });
      }
      waiting = [...batch, ...waiting];
      bound();
      if (isBroken) link.broke(connection, error);
      else say({ failed });
    }
  }
  const send = () => (sending ??= sendOnce().finally(() => (sending = undefined)));
  const timer = setInterval(() => send().catch(() => {}), everyMs);

  return {
    add(event) {
      waiting.push(event);
      bound();
    },
    send,
    waiting: () => waiting,
    log(line) {
      if (line.log === "start") {
        logOpen = true;
        if (device) openLog();
      } else if (line.log === "older") {
        logRead?.older(Number(line.before));
      } else if (line.log === "stop") {
        logOpen = false;
        logRead?.end();
        logRead = undefined;
      }
    },
    /** What waits goes, for at most `ms`; then the read back ends. */
    async end(ms = 5000) {
      clearInterval(timer);
      const flushed = (async () => {
        while (waiting.length) await send();
      })();
      await Promise.race([flushed.catch(() => {}), new Promise((r) => setTimeout(r, ms).unref())]);
      // what did not go in time goes nowhere: the process may go on for other jobs
      waiting = [];
      unhook();
      endRead();
      logRead?.end();
    },
  };
}
