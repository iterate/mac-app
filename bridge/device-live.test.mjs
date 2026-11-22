import assert from "node:assert/strict";
import { test } from "node:test";
import { deviceLive } from "./device-live.mjs";
import { fakeMind, until } from "./fake-mind.test-helper.mjs";

const start = (mind) => {
  const said = [];
  const live = deviceLive({
    name: "test",
    connect: mind.connect,
    sleep: mind.sleep,
    say: (line) => said.push(line),
    pingEveryMs: 3_600_000,
  });
  return { live, said };
};
const want = (from) => ({
  type: "device/live-signal",
  payload: { from, to: "device", want: true },
  source: { principal: { email: "watcher@example.com" } },
});
const heard = (said) => said.filter((l) => l.signal).map((l) => l.signal.from);
const alive = (mind) => mind.subscriptions.filter((s) => s.alive && s.connection.isOpen);

test("after each new connection it subscribes again, asks for the ICE servers, and hears", async () => {
  const mind = fakeMind();
  const { live, said } = start(mind);
  await until(() => alive(mind).length === 1);
  mind.deliver([want("a")]);
  assert.deepEqual(heard(said), ["a"]);

  mind.connections[0].end();
  await until(() => alive(mind).length === 1 && mind.connections.length === 2);
  mind.deliver([want("b")]);
  assert.deepEqual(heard(said), ["a", "b"]);
  assert.equal(said.filter((l) => l.iceServers).length, 2);
  assert.deepEqual(said.filter((l) => "connected" in l).map((l) => l.connected), [true, false, true]);
  await live.end();
});

test("a subscription that ends with no word is found by the ping and made again", async () => {
  const mind = fakeMind();
  const { live, said } = start(mind);
  await until(() => alive(mind).length === 1);
  await live.ping();
  await live.ping();
  assert.equal(mind.connections.length, 1, "a heard ping changes nothing");

  mind.subscriptions[0].alive = false;
  await live.ping();
  await live.ping();
  await until(() => alive(mind).length === 1 && mind.connections.length === 2);
  mind.deliver([want("c")]);
  assert.deepEqual(heard(said), ["c"]);
  assert.match(said.find((l) => l.connected === false).failed, /heard nothing/);
  await live.end();
});

test("what the device says goes out in order, and waits for the connection that comes back", async () => {
  const mind = fakeMind();
  const { live } = start(mind);
  await until(() => alive(mind).length === 1);
  mind.connections[0].end();
  live.take({ signal: { to: "w", description: { type: "offer" } } });
  live.take({ signal: { to: "w", candidate: { candidate: "c1" } } });
  await live.take({ started: { watcher: "w", who: "x", tracks: [] } });
  const sent = mind.appended.filter((e) => e.type !== "device/live-ping");
  assert.deepEqual(
    sent.map((e) => e.type),
    ["device/live-signal", "device/live-signal", "device/live-watch-started"],
  );
  assert.equal(sent[0].payload.description.type, "offer");
  assert.equal(sent[2].idempotencyKey, "device/live-watch-started/w");
  await live.end();
});
