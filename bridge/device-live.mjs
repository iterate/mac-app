#!/usr/bin/env node
// device-live.mjs: the signalling of live, between this Mac and the watchers' pages, through the
// context /devices/<name> of the mind (README, "Live"). Only signalling goes through the mind: the
// pictures and the sound go peer to peer.
//
//   node device-live.mjs <name> --iterate <iterate.js> --mind <address>
//
// The app (Sources/VoiceMeetMac/DeviceLive.swift, through Sources/Live/Bridge.swift) starts it
// while the Mac is lent, and closes stdin to end it. It connects to the mind once, as the person
// (the iterate CLI's own sign-in: the Mac's key lends and does nothing else).
//
// - stdout: `{ iceServers }` first and again at half their lifetime: what `iceServers()` of the
//   facet `record` on /devices/<name> answers (STUN, and TURN when the mind has it); without that
//   facet the app keeps STUN alone. Then each `device/live-signal` whose `to` is "device", as
//   `{ signal: { from, want | description | candidate | bye }, who }`: `who` is the event's
//   source, as an email or a short name. `{ failed }` lines are for the app's log.
// - stdin: `{ signal: { to, … } }` becomes an ephemeral `device/live-signal { from: "device", to, … }`,
//   appended in order (an offer before its candidates). `{ started }` and `{ ended }` become the
//   kept events `device/live-watch-started { watcher, who, tracks }` and
//   `device/live-watch-ended { watcher, who, seconds, why }`.
import { dirname, join } from "node:path";
import { createInterface } from "node:readline";
import { pathToFileURL } from "node:url";
import { parseArgs } from "node:util";

const { positionals, values } = parseArgs({
  allowPositionals: true,
  options: { iterate: { type: "string" }, mind: { type: "string" } },
});
const name = positionals[0];
if (!name || !values.iterate || !values.mind)
  throw new Error("node device-live.mjs <name> --iterate <iterate.js> --mind <address>");
const say = (line) => process.stdout.write(`${JSON.stringify(line)}\n`);
const failed = (what, error) => say({ failed: `${what}: ${String(error?.message ?? error).slice(0, 300)}` });
const SIGNAL = "device/live-signal";

const { addressOf, connectMind } = await import(
  pathToFileURL(join(dirname(dirname(values.iterate)), "dist/node.mjs")).href
);
const { itx } = await connectMind({ address: addressOf(values.mind), signIn: false });
const device = itx.cd(`/devices/${name}`);

// The addresses a connection may use, before any watcher; again at half their lifetime.
async function iceServers() {
  let ttl = 3600;
  try {
    const answer = await Promise.race([
      device.facets.get("record").iceServers(),
      new Promise((_, reject) => setTimeout(() => reject(new Error("no answer in 5 s")), 5000)),
    ]);
    const servers = JSON.parse(JSON.stringify(answer?.iceServers ?? []));
    if (servers.length) say({ iceServers: servers });
    ttl = answer?.ttlSeconds ?? ttl;
  } catch (error) {
    failed("ICE servers, STUN alone", error);
  }
  setTimeout(iceServers, Math.max(60, ttl / 2) * 1000).unref();
}
await iceServers();

/** Who asked: the principal's email, else its actor, else the origin. */
function whoOf(source) {
  const principal = source?.principal ?? source?.onBehalfOf?.principal;
  return String(principal?.email ?? principal?.actor ?? source?.origin ?? "someone").slice(0, 100);
}

// In: what the watchers say to the device.
const subscription = await device.subscribe({
  name: `device-live-${process.pid}-${Date.now().toString(36)}`,
  consumes: [SIGNAL],
  target: (batch) => {
    for (const event of JSON.parse(JSON.stringify(batch))) {
      const payload = event?.payload;
      if (event?.type !== SIGNAL || payload?.to !== "device" || !payload.from) continue;
      const { to, at, ...signal } = payload;
      say({ signal, who: whoOf(event.source) });
    }
  },
});

// Out: what the device says, one append at a time, in order.
let chain = Promise.resolve();
const append = (event) => {
  chain = chain.then(() => device.append(event)).catch((error) => failed(event.type, error));
};
for await (const text of createInterface({ input: process.stdin })) {
  if (!text) continue;
  const line = JSON.parse(text);
  if (line.signal) append({ type: SIGNAL, ephemeral: true, payload: { from: "device", ...line.signal } });
  for (const kind of ["started", "ended"]) {
    if (!line[kind]) continue;
    const type = `device/live-watch-${kind}`;
    append({ type, idempotencyKey: `${type}/${line[kind].watcher}`, payload: line[kind] });
  }
}
// stdin closed: the app is gone, or the Mac is no longer lent. The last byes go out first.
await chain;
subscription?.[Symbol.dispose]?.();
process.exit(0);
