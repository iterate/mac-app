#!/usr/bin/env node
// device-events.mjs: what this Mac tells its mind about itself, as events on the context
// /devices/<name> (the same name as the lend, `itx.<name>`).
//
//   node device-events.mjs <name> --iterate <iterate.js> --mind <address>
//
// The app (Sources/VoiceMeetMac/DeviceEvents.swift) starts it and writes one JSON line for each
// event on stdin: { type, payload, ephemeral? }. An ephemeral event reaches whoever listens now and
// is in no log. It connects to the mind as the person (the iterate CLI's own sign-in: the Mac's
// key lends and does nothing else), connects again when that connection ends
// (mind-connection.mjs), and appends what came in every fifth of a second, in one call, in order.
// While the connection is down the events wait; a batch that failed waits again at the front.
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
// stdout is JSON lines for the app: { sent }, { failed, dropped? }, { event: { type, payload,
// offset, createdAt } }, and { connected } from mind-connection.mjs: after `{ connected: true }`
// the app says its presence again.
import { realpathSync } from "node:fs";
import { dirname, join } from "node:path";
import { createInterface } from "node:readline";
import { fileURLToPath, pathToFileURL } from "node:url";
import { parseArgs } from "node:util";
import { isConnectionError, lastingConnection } from "./mind-connection.mjs";

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

/** The queue and its sender: `add(event)`, `send()` (also every `everyMs`), `end()`. */
export function deviceEvents({ name, connect, say, sleep, mostWaiting = 2_000, everyMs = 200 }) {
  let endRead = () => {};
  const link = lastingConnection({
    connect,
    say,
    sleep,
    async connected(link) {
      link.device = link.itx.cd(`/devices/${name}`);
      endRead();
      endRead = readBack(link.device, say);
    },
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
    /** What waits goes, for at most `ms`; then the connection ends. */
    async end(ms = 5000) {
      clearInterval(timer);
      const flushed = (async () => {
        while (waiting.length) await send();
      })();
      await Promise.race([flushed.catch(() => {}), new Promise((r) => setTimeout(r, ms).unref())]);
      endRead();
      link.stop();
    },
  };
}

if (process.argv[1] && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const { positionals, values } = parseArgs({
    allowPositionals: true,
    options: { iterate: { type: "string" }, mind: { type: "string" } },
  });
  const name = positionals[0];
  if (!name || !values.iterate || !values.mind)
    throw new Error("node device-events.mjs <name> --iterate <iterate.js> --mind <address>");
  const dist = join(dirname(dirname(values.iterate)), "dist");
  const { addressOf, connectMind } = await import(pathToFileURL(join(dist, "node.mjs")).href);
  const events = deviceEvents({
    name,
    connect: () => connectMind({ address: addressOf(values.mind), signIn: false }),
    say: (line) => process.stdout.write(`${JSON.stringify(line)}\n`),
  });
  for await (const line of createInterface({ input: process.stdin })) {
    if (line) events.add(JSON.parse(line));
  }
  // stdin closed: the app is gone, or it turned the events off
  await events.end();
  process.exit(0);
}
