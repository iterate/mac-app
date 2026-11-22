import assert from "node:assert/strict";
import { test } from "node:test";
import { SIGN_IN_ENDED, fakeMind, until } from "./fake-mind.test-helper.mjs";
import { isConnectionError, lastingConnection } from "./mind-connection.mjs";

const start = (mind, more = {}) => {
  const said = [];
  const link = lastingConnection({
    connect: mind.connect,
    sleep: mind.sleep,
    now: mind.now,
    say: (line) => said.push(line),
    ...more,
  });
  return { link, said };
};

test("a session the mind ends (1008) connects again, and the waits double to 60 s and reset", async () => {
  const mind = fakeMind();
  const { link, said } = start(mind);
  const first = await link.now();
  assert.equal(link.current(), first);

  mind.refuseConnects = 8;
  first.end();
  await until(() => link.current() !== first);
  const second = await link.now();
  assert.notEqual(second, first);
  assert.deepEqual(mind.waits, [1000, 2000, 4000, 8000, 16000, 32000, 60000, 60000, 60000]);
  assert.deepEqual(said[1], { connected: false, failed: SIGN_IN_ENDED });
  assert.deepEqual(said.at(-1), { connected: true });

  // a connection that lasted a minute: the wait starts at 1 s again
  mind.waits.length = 0;
  mind.clock += 61_000;
  second.end();
  await until(() => link.current() && link.current() !== second);
  assert.deepEqual(mind.waits, [1000]);
  link.stop();
});

test("broke() ends the connection it names, never a newer one", async () => {
  const mind = fakeMind();
  const { link } = start(mind);
  const first = await link.now();
  link.broke(first, new Error("Peer closed WebSocket: 1008"));
  await until(() => link.current() && link.current() !== first);
  const second = link.current();
  link.broke(first);
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(link.current(), second);
  assert.equal(first.isOpen, false, "the broken one is disposed");
  link.stop();
});

test("a connection whose callback fails is no connection: it is closed, and tried again", async () => {
  const mind = fakeMind();
  let calls = 0;
  const { link } = start(mind, {
    connected: async () => {
      if (++calls === 1) throw new Error("subscribe failed");
    },
  });
  const up = await link.now();
  assert.equal(mind.connections.length, 2);
  assert.equal(mind.connections[0].isOpen, false);
  assert.equal(up, mind.connections[1]);
  link.stop();
  await assert.rejects(link.now());
});

test("which failures are a connection's", () => {
  assert.ok(isConnectionError(new Error(`Peer closed WebSocket: ${SIGN_IN_ENDED}`)));
  assert.ok(isConnectionError(new Error("RPC session was shut down by disposing the main stub")));
  assert.ok(!isConnectionError(Object.assign(new Error("payload is not valid"), { code: "INVALID_INPUT" })));
});
