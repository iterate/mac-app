import assert from "node:assert/strict";
import { test } from "node:test";
import { deviceEvents } from "./events.mjs";
import { SIGN_IN_ENDED, fakeMind, until } from "./fake-mind.test-helper.mjs";
import { mindLink } from "./mind.mjs";

/** The job on a connection of its own; its end ends the connection too. */
const start = (mind, more = {}) => {
  const said = [];
  const say = (line) => said.push(line);
  const link = mindLink({ name: "test", connect: mind.connect, sleep: mind.sleep, say });
  const events = deviceEvents({ link, say, everyMs: 3_600_000, ...more });
  const end = events.end;
  events.end = async (ms) => {
    await end(ms);
    link.stop();
  };
  return { events, said };
};
const presence = (n) => ({ type: "device/presence-changed", payload: { n } });
const move = (n) => ({ type: "device/mouse-moved", ephemeral: true, payload: { n } });

test("events wait while the connection is down and go up after it, in order, none lost", async () => {
  const mind = fakeMind();
  const { events, said } = start(mind);
  events.add(presence(1));
  await events.send();
  assert.deepEqual(mind.appended.map((e) => e.payload.n), [1]);

  // the mind ends the session; events come in meanwhile, and the first batch fails with 1008
  mind.connections[0].end();
  mind.refuseConnects = 3;
  for (let n = 2; n <= 6; n++) events.add(move(n));
  const sending = events.send();
  events.add(presence(7));
  await sending;
  await events.send();
  assert.deepEqual(mind.appended.map((e) => e.payload.n), [1, 2, 3, 4, 5, 6, 7]);
  assert.equal(mind.connections.length, 2);
  assert.deepEqual(said.filter((l) => "connected" in l).map((l) => l.connected), [true, false, false, false, false, true]);
  await events.end();
});

test("a batch that failed because the connection broke is tried again on the next one", async () => {
  const mind = fakeMind();
  const { events } = start(mind);
  events.add(presence(1));
  events.add(move(2));
  mind.failNextAppend = new Error(`Peer closed WebSocket: ${SIGN_IN_ENDED}`);
  await events.send();
  assert.deepEqual(mind.appended, []);
  await events.send();
  assert.deepEqual(mind.appended.map((e) => e.payload.n), [1, 2]);
  assert.equal(mind.connections.length, 2);
  await events.end();
});

test("over the bound, the oldest moves and keys go first; presence is kept", async () => {
  const mind = fakeMind();
  mind.refuseConnects = 1_000;
  const { events } = start(mind, { mostWaiting: 4 });
  events.add(presence(1));
  events.add(move(2));
  events.add(move(3));
  events.add(presence(4));
  events.add(move(5));
  events.add(move(6));
  assert.deepEqual(events.waiting().map((e) => e.payload.n), [1, 4, 5, 6]);
  events.add(presence(7));
  events.add(presence(8));
  events.add(presence(9));
  assert.deepEqual(events.waiting().map((e) => e.payload.n), [4, 7, 8, 9]);
  await events.end(10);
});

test("a batch the mind refuses three times is dropped, and holds back nothing", async () => {
  const mind = fakeMind();
  const { events, said } = start(mind);
  events.add(presence(1));
  for (let i = 0; i < 3; i++) {
    mind.failNextAppend = Object.assign(new Error("not valid"), { code: "INVALID_INPUT" });
    await events.send();
  }
  assert.deepEqual(said.at(-1), { failed: "not valid", dropped: 1 });
  events.add(presence(2));
  await events.send();
  assert.deepEqual(mind.appended.map((e) => e.payload.n), [2]);
  assert.equal(mind.connections.length, 1, "a refusal is no broken connection");
  await events.end();
});

test("the end sends what waits", async () => {
  const mind = fakeMind();
  const { events } = start(mind);
  events.add(presence(1));
  await events.end();
  await until(() => mind.appended.length === 1);
});

const act = (kind, id) => ({
  type: `device/act-${kind}`,
  idempotencyKey: `device/act-${kind}/${id}`,
  payload: kind === "started" ? { act: id, thing: "commands", doing: "Running a command" } : { act: id, did: "Ran a command" },
});

test("the acts on the context come back to the app, each once, and only the log's types", async () => {
  const mind = fakeMind();
  // an act of an earlier run is in the context before the bridge starts
  await (await mind.connect()).itx.cd("/devices/test").append(act("started", "old"), act("ended", "old"));
  const { events, said } = start(mind);
  const told = () => said.filter((line) => line.event).map((line) => `${line.event.type} ${line.event.payload.act ?? line.event.payload.state}`);
  await until(() => told().length === 2);

  events.add(act("started", "a"));
  events.add({ type: "device/key-pressed", payload: { key: "x" } });
  events.add(move(1));
  events.add(act("ended", "a"));
  events.add({ type: "device/presence-changed", payload: { state: "idle" } });
  await events.send();
  await until(() => told().length === 5);
  assert.deepEqual(told(), [
    "device/act-started old",
    "device/act-ended old",
    "device/act-started a",
    "device/act-ended a",
    "device/presence-changed idle",
  ]);
  const echo = said.find((line) => line.event?.payload.act === "a").event;
  assert.equal(typeof echo.offset, "number");
  assert.equal(typeof echo.createdAt, "string");
  assert.deepEqual(echo.payload, act("started", "a").payload);
  assert.equal(mind.appended.find((e) => e.payload.act === "a").idempotencyKey, "device/act-started/a");
  await events.end();
});

test("a new connection reads the context again", async () => {
  const mind = fakeMind();
  const { events, said } = start(mind);
  events.add(act("started", "a"));
  await events.send();
  await until(() => said.filter((line) => line.event).length === 1);
  mind.connections[0].end();
  await until(() => mind.connections.length === 2 && said.filter((line) => line.event).length === 2);
  assert.equal(mind.subscriptions.filter((s) => s.alive).length, 1, "the first connection's read ended");
  await events.end();
});

/** Appends to /devices/test with no bridge, as an earlier run of the app did. */
const earlier = async (mind, events) => (await mind.connect()).itx.cd("/devices/test").append(...events);
const key = (n) => ({ type: "device/key-pressed", payload: { key: "x", n } });

test("the backward read stops at 10 pages of 500 offsets, and tells no other type", async () => {
  const mind = fakeMind();
  // an act at the start, then 6,000 kept keys, then an act: the first is beyond the read
  await earlier(mind, [act("started", "first"), act("ended", "first")]);
  await earlier(mind, Array.from({ length: 6_000 }, (_, n) => key(n)));
  await earlier(mind, [act("started", "last"), act("ended", "last")]);
  const { events, said } = start(mind);
  await until(() => mind.reads.length >= 11 && said.some((line) => line.event));
  await new Promise((resolve) => setTimeout(resolve, 20));
  const told = said.filter((line) => line.event).map((line) => `${line.event.type} ${line.event.payload.act}`);
  assert.deepEqual(told, ["device/act-started last", "device/act-ended last"]);
  const scanned = mind.reads.slice(1).reduce((sum, read) => sum + read.events, 0);
  assert.ok(scanned <= 5_000, `it scanned ${scanned} events`);
  assert.equal(mind.reads.at(-1).after, 6_004 - 5_000, "the tenth page is the last");
  await events.end();
});

test("the backward read ends when it has 50 acts, and tells at most the last 200 events", async () => {
  const mind = fakeMind();
  for (let n = 0; n < 400; n++) await earlier(mind, [act("started", `${n}`), act("ended", `${n}`)]);
  const { events, said } = start(mind);
  await until(() => said.filter((line) => line.event).length === 200);
  await new Promise((resolve) => setTimeout(resolve, 20));
  const told = said.filter((line) => line.event);
  assert.equal(told.length, 200);
  assert.equal(told.at(-1).event.payload.act, "399");
  assert.equal(told[0].event.payload.act, "300");
  assert.equal(mind.reads.length, 2, "the probe, and one page of 250 acts");
  await events.end();
});

test("the window's log: on start, every kept type newest first, a page of 100, older pages on request", async () => {
  const mind = fakeMind();
  // 250 kept events of mixed types, and ephemeral keys among them that are in no log
  const mixed = Array.from({ length: 250 }, (_, n) => (n % 2 ? presence(n) : { type: "device/app-focused", payload: { app: "Ghostty", n } }));
  await earlier(mind, mixed);
  await earlier(mind, [{ ...key(999), ephemeral: true }]);
  const { events, said } = start(mind);
  events.log({ log: "start" });
  const pages = () => said.filter((line) => line.log?.page);
  await until(() => pages().length === 1);
  assert.ok(said.some((line) => line.log?.reset), "a reset first");
  const first = pages()[0].log;
  assert.equal(first.page.length, 100);
  assert.deepEqual(first.page.slice(0, 2).map((e) => e.payload.n), [249, 248]);
  assert.ok(first.more);
  assert.ok(first.page.every((e) => e.type !== "device/key-pressed"));
  events.log({ log: "older", before: first.before });
  await until(() => pages().length === 2);
  assert.equal(pages()[1].log.page[0].payload.n, 149);
  events.log({ log: "older", before: pages()[1].log.before });
  await until(() => pages().length === 3);
  const last = pages()[2].log;
  assert.equal(last.page.length, 50);
  assert.equal(last.page.at(-1).payload.n, 0);
  assert.equal(last.more, false);
  await events.end();
});

test("the window's log follows new events of every kept type, cuts long text, and stops with the window", async () => {
  const mind = fakeMind();
  const { events, said } = start(mind);
  events.log({ log: "start" });
  await until(() => said.some((line) => line.log?.page) && mind.subscriptions.some((s) => s.alive && s.consumes.includes("*")));
  events.add({ type: "device/window-read", payload: { app: "Ghostty", text: "x".repeat(20_000) } });
  events.add({ type: "device/key-pressed", ephemeral: true, payload: { key: "a" } });
  await events.send();
  await until(() => said.some((line) => line.log?.event));
  const told = said.filter((line) => line.log?.event).map((line) => line.log.event);
  assert.deepEqual(told.map((e) => e.type), ["device/window-read"]);
  assert.equal(told[0].payload.text.length, 2_001);
  events.log({ log: "stop" });
  assert.equal(mind.subscriptions.filter((s) => s.alive && s.consumes.includes("*")).length, 0);
  events.add(presence(1));
  await events.send();
  await new Promise((resolve) => setTimeout(resolve, 20));
  assert.equal(said.filter((line) => line.log?.event).length, 1);
  await events.end();
});

test("a new connection while the window is open reads its log again from a reset", async () => {
  const mind = fakeMind();
  await earlier(mind, [presence(1)]);
  const { events, said } = start(mind);
  events.log({ log: "start" });
  await until(() => said.filter((line) => line.log?.page).length === 1);
  mind.connections.at(-1).end();
  await until(() => said.filter((line) => line.log?.page).length === 2);
  assert.equal(said.filter((line) => line.log?.reset).length, 2);
  assert.equal(mind.subscriptions.filter((s) => s.alive && s.consumes.includes("*")).length, 1);
  await events.end();
});

/** A link whose connection never comes, and how often the job asked for it. */
const nowhere = () => {
  const link = { asked: 0, each: () => () => {}, now: () => (link.asked++, new Promise(() => {})), broke() {}, current: () => undefined };
  return link;
};
const timeouts = () => process.getActiveResourcesInfo().filter((kind) => kind === "Timeout").length;

test("an idle job runs no timer, and a send that waits for the connection is asked for once", async () => {
  const link = nowhere();
  const before = timeouts();
  const events = deviceEvents({ link, say: () => {}, everyMs: 5 });
  await new Promise((resolve) => setTimeout(resolve, 30));
  assert.equal(timeouts(), before, "no timer while nothing waits");
  events.add(presence(1));
  await new Promise((resolve) => setTimeout(resolve, 60));
  assert.equal(link.asked, 1, "one send, waiting for the connection; not one more each 5 ms");
  await events.end(10);
});
