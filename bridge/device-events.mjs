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
// stdout is JSON lines for the app: { sent }, { failed, dropped? }, and { connected } from
// mind-connection.mjs: after `{ connected: true }` the app says its presence again.
import { realpathSync } from "node:fs";
import { dirname, join } from "node:path";
import { createInterface } from "node:readline";
import { fileURLToPath, pathToFileURL } from "node:url";
import { parseArgs } from "node:util";
import { isConnectionError, lastingConnection } from "./mind-connection.mjs";

/** The input events that go first when too many wait: presence and the rest are kept. */
const isInput = (event) => /^device\/(key-pressed|mouse-|scrolled)/.test(event?.type);

/** The queue and its sender: `add(event)`, `send()` (also every `everyMs`), `end()`. */
export function deviceEvents({ name, connect, say, sleep, mostWaiting = 2_000, everyMs = 200 }) {
  const link = lastingConnection({
    connect,
    say,
    sleep,
    connected: async (link) => (link.device = link.itx.cd(`/devices/${name}`)),
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
  const { addressOf, connectMind } = await import(
    pathToFileURL(join(dirname(dirname(values.iterate)), "dist/node.mjs")).href
  );
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
