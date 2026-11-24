// node --test bridge/record.test.mjs — the record's spool into the mind, through mind.mjs.
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { eventually, fakeMind } from "./fake-mind.test-helper.mjs";
import { mindBridge } from "./mind.mjs";

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
