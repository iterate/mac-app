// node --test bridge/record.test.mjs — the record's spool into the mind, through mind.mjs.
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { eventually, fakeMind } from "./fake-mind.test-helper.mjs";
import { createServer } from "node:http";
import { mindBridge, mindLink } from "./mind.mjs";
import { recordUploads } from "./record.mjs";

/** A slot as the recorder seals it: an audio file and the event's payload. */
function slot(spool, t, bytes = "x".repeat(1000)) {
  const file = `/devices/test/record/mic-0/2026-11-24/14/${String(t % 60).padStart(2, "0")}-00.mp4`;
  mkdirSync(dirname(join(spool, file)), { recursive: true });
  writeFileSync(join(spool, file), bytes);
  const payload = { t, tracks: { "mic-0": { kind: "audio", file, bytes: bytes.length } } };
  mkdirSync(join(spool, "slots"), { recursive: true });
  writeFileSync(join(spool, "slots", `${t}.json`), JSON.stringify(payload));
  return { file, payload };
}

const stored = (mind) => mind.appended.filter((event) => event.type === "record/slot-stored");

test("the mind ends the session (1008) and the record goes on: the next slot goes up on the next connection", async () => {
  const mind = fakeMind();
  const spool = mkdtempSync(join(tmpdir(), "record-"));
  const said = [];
  const bridge = mindBridge({
    mind: "example.com",
    name: "test",
    connect: mind.connect,
    sleep: mind.sleep,
    say: (line) => said.push(line),
    record: { everyMs: 10, sleep: () => new Promise((resolve) => setTimeout(resolve, 5)) },
  });
  try {
    const first = slot(spool, 1764000000);
    bridge.take({ job: "record", start: true, spool });
    await eventually(() => stored(mind).length === 1);
    assert.equal(mind.order.indexOf(`file ${first.file.slice(1)}`) < mind.order.indexOf("event record/slot-stored"), true, "the file before its event");
    assert.equal(mind.files.get(first.file.slice(1)).via, "signed");

    // the sign-in of the session ends after its 4 hours: the mind closes the socket with 1008
    mind.connections[0].end();
    const second = slot(spool, 1764000030, "y".repeat(2000));
    await eventually(() => stored(mind).length === 2);
    assert.equal(mind.connections.length, 2, "one connection again, not one for each try");
    assert.equal(mind.files.get(second.file.slice(1)).bytes.length, 2000);
    assert.deepEqual(stored(mind).map((event) => [event.path, event.idempotencyKey, event.payload]), [
      ["/devices/test", "record/slot-stored/1764000000", first.payload],
      ["/devices/test", "record/slot-stored/1764000030", second.payload],
    ]);
    assert.deepEqual(readdirSync(join(spool, "slots")), [], "each slot left the spool after its event");
    assert.deepEqual(readdirSync(join(spool, "devices")), [], "and its empty folders");
    assert.deepEqual(
      said.filter((line) => line.job === "record" && line.uploaded).map((line) => line.uploaded),
      [1764000000, 1764000030],
    );
    assert.ok(said.some((line) => line.connected === false && /^1008 /.test(line.failed)));
  } finally {
    await bridge.end();
    rmSync(spool, { recursive: true, force: true });
  }
});

test("a signed route that answers 5xx sends a slot's files through the connection", async () => {
  const mind = fakeMind();
  mind.failSignedPuts = 500;
  const spool = mkdtempSync(join(tmpdir(), "record-"));
  const said = [];
  const bridge = mindBridge({
    mind: "example.com",
    name: "test",
    connect: mind.connect,
    sleep: mind.sleep,
    say: (line) => said.push(line),
    record: { everyMs: 10 },
  });
  try {
    const { file } = slot(spool, 1764000000);
    bridge.take({ job: "record", start: true, spool });
    await eventually(() => stored(mind).length === 1);
    assert.equal(mind.files.get(file.slice(1)).via, "connection");
    assert.equal(said.filter((line) => line.fallback).length, 1);
  } finally {
    await bridge.end();
    rmSync(spool, { recursive: true, force: true });
  }
});

/** The job alone on a link of the fake mind, with fast waits. */
function job(mind, spool, more = {}) {
  const said = [];
  const link = mindLink({ name: "test", connect: more.connect ?? mind.connect, sleep: mind.sleep, say: () => {} });
  const record = recordUploads({ link, spool, say: (line) => said.push(line), sleep: () => new Promise((resolve) => setTimeout(resolve, 5)), ...more });
  return { said, link, record, end: async () => (await record.end(), link.stop()) };
}

test("a slot that the app tells wakes the job: it does not look at the spool's list each 2 s", async () => {
  const mind = fakeMind();
  const spool = mkdtempSync(join(tmpdir(), "record-"));
  const { said, end, record } = job(mind, spool, { everyMs: 3_600_000, sleep: undefined });
  try {
    await new Promise((resolve) => setTimeout(resolve, 20));
    const { payload } = slot(spool, 1764000000);
    record.sealed(1764000000);
    await eventually(() => stored(mind).length === 1, 2000);
    assert.deepEqual(stored(mind)[0].payload, payload);
    assert.ok(said.some((line) => line.waiting === 1 && !("uploaded" in line)), "the new slot's count");
  } finally {
    await end();
    rmSync(spool, { recursive: true, force: true });
  }
});

test("a slot recorded under the old name of this Mac goes to that device, with its files", async () => {
  const mind = fakeMind();
  const spool = mkdtempSync(join(tmpdir(), "record-"));
  const file = "/devices/old.mac/record/mic-0/2026-11-24/14/00-00.mp4";
  mkdirSync(dirname(join(spool, file)), { recursive: true });
  writeFileSync(join(spool, file), "old");
  mkdirSync(join(spool, "slots"), { recursive: true });
  writeFileSync(join(spool, "slots", "1764000000.json"), JSON.stringify({ t: 1764000000, tracks: { "mic-0": { kind: "audio", file, bytes: 3 } } }));
  const { end } = job(mind, spool, { everyMs: 10 });
  try {
    await eventually(() => stored(mind).length === 1);
    assert.equal(stored(mind)[0].path, "/devices/old.mac");
    assert.ok(mind.files.has(file.slice(1)));
  } finally {
    await end();
    rmSync(spool, { recursive: true, force: true });
  }
});

test("a slot that fails 3 times for its own reason is set aside, and the next slot goes", async () => {
  const mind = fakeMind();
  const spool = mkdtempSync(join(tmpdir(), "record-"));
  mkdirSync(join(spool, "slots"), { recursive: true });
  writeFileSync(join(spool, "slots", "1764000000.json"), "{");
  const next = slot(spool, 1764000030);
  const { said, end } = job(mind, spool, { everyMs: 10 });
  try {
    await eventually(() => stored(mind).length === 1);
    assert.deepEqual(stored(mind)[0].payload, next.payload);
    assert.deepEqual(readdirSync(join(spool, "slots", "failed")), ["1764000000.json"]);
    assert.equal(said.filter((line) => line.failed).length, 3);
    assert.equal(said.find((line) => line.setAside).setAside, 1764000000);
    assert.equal(mind.connections.length, 1, "a failure of the slot is not the connection's");
  } finally {
    await end();
    rmSync(spool, { recursive: true, force: true });
  }
});

test("an attempt with no answer is aborted: its PUT ends, the next try sends the slot once", async () => {
  const mind = fakeMind();
  const spool = mkdtempSync(join(tmpdir(), "record-"));
  const puts = [];
  const server = createServer((request, answer) => {
    const chunks = [];
    puts.push(request);
    request.on("data", (chunk) => chunks.push(chunk));
    // the first PUT never answers
    if (puts.length === 1) return;
    request.on("end", () => {
      mind.files.set(decodeURIComponent(request.url.slice(1)), { bytes: Buffer.concat(chunks) });
      answer.writeHead(200, { connection: "close" }).end(JSON.stringify({ size: Buffer.concat(chunks).length }));
    });
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const connect = async () => {
    const connection = await mind.connect();
    connection.itx.r2.presign = async ({ key }) => ({ url: `http://127.0.0.1:${server.address().port}/${encodeURIComponent(key)}` });
    return connection;
  };
  const { file } = slot(spool, 1764000000);
  const { said, end } = job(mind, spool, { everyMs: 10, idleMs: 300, connect });
  try {
    await eventually(() => stored(mind).length === 1);
    assert.equal(puts.length, 2);
    assert.equal(puts[0].destroyed || puts[0].complete === false, true, "the first PUT was ended");
    assert.match(said.find((line) => line.failed).failed, /no answer in 0.3 s/);
    assert.ok(mind.files.has(file.slice(1)));
    await new Promise((resolve) => setTimeout(resolve, 50));
    assert.equal(stored(mind).length, 1, "one event");
  } finally {
    await end();
    server.close();
    rmSync(spool, { recursive: true, force: true });
  }
});
