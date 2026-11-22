#!/usr/bin/env node
// device-live.mjs: the signalling of live, between this Mac and the watchers' pages, through the
// context /devices/<name> of the mind (README, "Live"). Only signalling goes through the mind: the
// pictures and the sound go peer to peer.
//
//   node device-live.mjs <name> --iterate <iterate.js> --mind <address>
//
// The app (Sources/VoiceMeetMac/DeviceLive.swift, through Sources/Live/Bridge.swift) starts it
// while the Mac is lent, and closes stdin to end it. It connects to the mind as the person (the
// iterate CLI's own sign-in: the Mac's key lends and does nothing else), and connects again when
// that connection ends (mind-connection.mjs). On each connection it subscribes and asks for the ICE
// servers. A subscription can end on the mind's side with no word: once a minute the bridge
// appends an ephemeral `device/live-ping` that only its own subscription hears, and a ping not
// heard by the next one ends the connection, which connects and subscribes again. Watches that
// run go on through it: they are peer to peer.
//
// - stdout: `{ iceServers }` on each connection and again at half their lifetime: what
//   `iceServers()` of the facet `record` on /devices/<name> answers (STUN, and TURN when the mind
//   has it); without that facet the app keeps STUN alone. Then each `device/live-signal` whose
//   `to` is "device", as `{ signal: { from, want | description | candidate | bye }, who }`: `who`
//   is the event's source, as an email or a short name. `{ connected: true }` and
//   `{ connected: false, failed }` say whether the signalling is up; `{ failed }` lines are for
//   the app's log.
// - stdin: `{ signal: { to, … } }` becomes an ephemeral `device/live-signal { from: "device", to, … }`,
//   appended in order (an offer before its candidates). `{ started }` and `{ ended }` become the
//   kept events `device/live-watch-started { watcher, who, tracks }` and
//   `device/live-watch-ended { watcher, who, seconds, why }`.
import { realpathSync } from "node:fs";
import { dirname, join } from "node:path";
import { createInterface } from "node:readline";
import { fileURLToPath, pathToFileURL } from "node:url";
import { parseArgs } from "node:util";
import { isConnectionError, lastingConnection } from "./mind-connection.mjs";

const SIGNAL = "device/live-signal";
const PING = "device/live-ping";

/** Who asked: the principal's email, else its actor, else the origin. */
function whoOf(source) {
  const principal = source?.principal ?? source?.onBehalfOf?.principal;
  return String(principal?.email ?? principal?.actor ?? source?.origin ?? "someone").slice(0, 100);
}

const within = (promise, ms) =>
  Promise.race([
    promise,
    new Promise((_, reject) => setTimeout(() => reject(new Error(`no answer in ${ms / 1000} s`)), ms).unref()),
  ]);

/** The signalling: `say` hears the watchers, `append(line)` takes a line of the app. */
export function deviceLive({ name, connect, say, sleep, pingEveryMs = 60_000 }) {
  const failed = (what, error) => say({ failed: `${what}: ${String(error?.message ?? error).slice(0, 300)}` });
  const me = `device-live-${process.pid}-${Date.now().toString(36)}`;
  let iceTimer;
  let pings = 0;
  let subscriptions = 0;

  // The addresses a connection may use, before any watcher; again at half their lifetime.
  async function iceServers(device) {
    clearTimeout(iceTimer);
    let ttl = 3600;
    try {
      const answer = await within(device.facets.get("record").iceServers(), 5000);
      const servers = JSON.parse(JSON.stringify(answer?.iceServers ?? []));
      if (servers.length) say({ iceServers: servers });
      ttl = answer?.ttlSeconds ?? ttl;
    } catch (error) {
      failed("ICE servers, STUN alone", error);
    }
    iceTimer = setTimeout(
      () => link.now().then((connection) => iceServers(connection.device)),
      Math.max(60, ttl / 2) * 1000,
    );
    iceTimer.unref?.();
  }

  const link = lastingConnection({
    connect,
    say,
    sleep,
    async connected(connection) {
      const device = (connection.device = connection.itx.cd(`/devices/${name}`));
      connection.subscription = await device.subscribe({
        name: `${me}-${++subscriptions}`,
        consumes: [SIGNAL, PING],
        target: (batch) => {
          for (const event of JSON.parse(JSON.stringify(batch))) {
            const payload = event?.payload;
            if (event?.type === PING && payload?.from === me) connection.heard = payload.ping;
            if (event?.type !== SIGNAL || payload?.to !== "device" || !payload.from) continue;
            const { to, at, ...signal } = payload;
            say({ signal, who: whoOf(event.source) });
          }
        },
      });
      await iceServers(device);
    },
  });

  // A ping that its own subscription did not hear by the next one: the subscription is gone.
  async function ping() {
    const connection = link.current();
    if (!connection) return;
    if (connection.pinged !== connection.heard)
      return link.broke(connection, new Error("the subscription heard nothing in a minute"));
    connection.pinged = ++pings;
    try {
      await within(connection.device.append({ type: PING, ephemeral: true, payload: { from: me, ping: pings } }), 20_000);
    } catch (error) {
      link.broke(connection, error);
    }
  }
  const pinger = setInterval(() => ping().catch(() => {}), pingEveryMs);

  // Out: what the device says, one append at a time, in order; on up to three connections.
  let chain = Promise.resolve();
  async function appendOne(event) {
    for (let tries = 1; tries <= 3; tries++) {
      const connection = await link.now();
      try {
        return await connection.device.append(event);
      } catch (error) {
        failed(event.type, error);
        if (!isConnectionError(error)) return;
        link.broke(connection, error);
      }
    }
  }
  const append = (event) => (chain = chain.then(() => appendOne(event)).catch(() => {}));

  return {
    ping,
    /** A line of the app. */
    take(line) {
      if (line.signal) append({ type: SIGNAL, ephemeral: true, payload: { from: "device", ...line.signal } });
      for (const kind of ["started", "ended"]) {
        if (!line[kind]) continue;
        const type = `device/live-watch-${kind}`;
        append({ type, idempotencyKey: `${type}/${line[kind].watcher}`, payload: line[kind] });
      }
      return chain;
    },
    /** The last byes go out first, for at most `ms`. */
    async end(ms = 5000) {
      clearInterval(pinger);
      clearTimeout(iceTimer);
      await within(chain, ms).catch(() => {});
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
    throw new Error("node device-live.mjs <name> --iterate <iterate.js> --mind <address>");
  const { addressOf, connectMind } = await import(
    pathToFileURL(join(dirname(dirname(values.iterate)), "dist/node.mjs")).href
  );
  const live = deviceLive({
    name,
    connect: () => connectMind({ address: addressOf(values.mind), signIn: false }),
    say: (line) => process.stdout.write(`${JSON.stringify(line)}\n`),
  });
  for await (const text of createInterface({ input: process.stdin })) {
    if (text) live.take(JSON.parse(text));
  }
  // stdin closed: the app is gone, or the Mac is no longer lent
  await live.end();
  process.exit(0);
}
