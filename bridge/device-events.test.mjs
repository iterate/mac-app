import assert from "node:assert/strict";
import { test } from "node:test";
import { deviceEvents } from "./device-events.mjs";
import { SIGN_IN_ENDED, fakeMind, until } from "./fake-mind.test-helper.mjs";

const start = (mind, more = {}) => {
  const said = [];
  const events = deviceEvents({
    name: "test",
    connect: mind.connect,
    sleep: mind.sleep,
    say: (line) => said.push(line),
    everyMs: 3_600_000,
    ...more,
  });
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
