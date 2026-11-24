// node --test bridge/mind.test.mjs — one process for a mind: the jobs share one connection, and
// each line names its job.
import assert from "node:assert/strict";
import { test } from "node:test";
import { eventually, fakeMind } from "./fake-mind.test-helper.mjs";
import { mindBridge } from "./mind.mjs";

const start = (mind) => {
  const said = [];
  const bridge = mindBridge({ mind: "example.com", name: "test", connect: mind.connect, sleep: mind.sleep, say: (line) => said.push(line) });
  return { bridge, said };
};

test("events and live share one connection; what each says names its job", async (t) => {
  const mind = fakeMind();
  const { bridge, said } = start(mind);
  t.after(() => bridge.end());
  bridge.take({ job: "live", start: true });
  bridge.take({ job: "events", start: true });
  bridge.take({ job: "events", event: { type: "device/presence-changed", payload: { state: "active" } } });
  await eventually(() => said.some((line) => line.job === "events" && line.event));
  await eventually(() => said.some((line) => line.job === "live" && line.iceServers));
  assert.equal(mind.connections.length, 1);
  assert.deepEqual(said.find((line) => "connected" in line), { connected: true });
  bridge.take({ job: "live", stop: true });
  await eventually(() => mind.subscriptions.filter((s) => s.alive && s.consumes.includes("device/live-signal")).length === 0);
  assert.equal(mind.subscriptions.filter((s) => s.alive).length, 1, "the events' read back goes on");
  await bridge.end();
  assert.equal(mind.connections[0].isOpen, false, "the end ends the connection");
});

test("a line that breaks fails its own job alone", async (t) => {
  const mind = fakeMind();
  const { bridge, said } = start(mind);
  t.after(() => bridge.end());
  bridge.take({ job: "nothing" });
  bridge.take({ job: "capture", capture: "c1", folder: "/nowhere", put: "1.jpg" });
  bridge.take({ job: "capture", capture: "c2", heard: true });
  bridge.take({ job: "events", start: true });
  bridge.take({ job: "events", event: { type: "device/presence-changed", payload: {} } });
  await eventually(() => said.some((line) => line.job === "events" && line.sent));
  assert.match(said.find((line) => line.job === "nothing").failed, /no job "nothing"/);
  assert.match(said.find((line) => line.capture === "c1").failed, /ENOENT/);
  assert.match(said.find((line) => !line.job && line.failed).failed, /capture c2: a line after its end/);
  await bridge.end();
});
