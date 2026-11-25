// node --test bridge/openai.test.mjs — OpenAI's realtime socket, opened through the mind with the
// mind's own key, and its text frames relayed both ways.
import assert from "node:assert/strict";
import { test } from "node:test";
import { fakeMind, until } from "./fake-mind.test-helper.mjs";
import { mindBridge, mindLink } from "./mind.mjs";
import { openaiSockets, REALTIME, redacted } from "./openai.mjs";

/** The upstream socket as the mind's `itx.fetch` gives it: `sent` has what the bridge sent it. */
function fakeSocket() {
  const listeners = { message: [], close: [], error: [] };
  const socket = {
    readyState: 1,
    sent: [],
    accepted: false,
    closedWith: undefined,
    accept() {
      socket.accepted = true;
    },
    addEventListener(type, listener) {
      listeners[type]?.push(listener);
    },
    send(text) {
      if (socket.readyState !== 1) throw new Error("the socket is closed");
      socket.sent.push(text);
    },
    close(code, reason) {
      socket.closedWith ??= { code, reason };
      socket.readyState = 3;
    },
    /** OpenAI sends a frame. */
    frame(data) {
      for (const listener of listeners.message) listener({ data });
    },
    /** OpenAI or the mind closes it. */
    closeFromFar(code, reason) {
      socket.readyState = 3;
      for (const listener of listeners.close) listener({ code, reason });
    },
    fail(message) {
      for (const listener of listeners.error) listener({ message });
    },
  };
  return socket;
}

/** The job on a link to `mind`, with what it said. */
function job(mind, options = {}) {
  const link = mindLink({ name: "test", connect: mind.connect, sleep: mind.sleep, say: () => {} });
  const said = [];
  const sockets = openaiSockets({ link, say: (line) => said.push(line), ...options });
  return { link, said, sockets, stop: () => (sockets.end(), link.stop()) };
}

test("the socket opens through itx.fetch with the vault's placeholder, and text frames go both ways", async () => {
  const mind = fakeMind();
  const upstream = fakeSocket();
  mind.fetch = async () => ({ status: 200, webSocket: upstream });
  const { said, sockets, stop } = job(mind);
  try {
    const opening = sockets.take({ socket: "1", open: true });
    // the session's setup goes before the socket is open: it waits, in order
    sockets.take({ socket: "1", frame: '{"type":"session.update"}' });
    await opening;
    assert.deepEqual(said, [{ socket: "1", opened: true }]);
    assert.equal(upstream.accepted, true);
    assert.deepEqual(upstream.sent, ['{"type":"session.update"}']);

    const [request] = mind.fetched;
    assert.equal(request.url, REALTIME);
    assert.equal(request.headers.get("upgrade"), "websocket");
    assert.equal(request.headers.get("authorization"), 'Bearer getSecret("/secrets/openai")');

    sockets.take({ socket: "1", frame: '{"type":"input_audio_buffer.append","audio":"AAAA"}' });
    assert.equal(upstream.sent.length, 2);
    upstream.frame('{"type":"session.created"}');
    // bytes are text too: OpenAI's frames are JSON
    upstream.frame(new TextEncoder().encode('{"type":"session.updated"}'));
    upstream.frame(new Blob(["no"]));
    assert.deepEqual(said.slice(1), [
      { socket: "1", frame: '{"type":"session.created"}' },
      { socket: "1", frame: '{"type":"session.updated"}' },
    ]);

    sockets.take({ socket: "1", ping: 4 });
    assert.deepEqual(said.at(-1), { socket: "1", pong: 4 });
  } finally {
    stop();
  }
});

test("the app's close closes the upstream and nothing more is said; OpenAI's close is said", async () => {
  const mind = fakeMind();
  const first = fakeSocket();
  const second = fakeSocket();
  const given = [first, second];
  mind.fetch = async () => ({ status: 200, webSocket: given.shift() });
  const { said, sockets, stop } = job(mind);
  try {
    await sockets.take({ socket: "a", open: true });
    await sockets.take({ socket: "b", open: true });
    sockets.take({ socket: "a", close: true, code: 1000 });
    assert.deepEqual(first.closedWith, { code: 1000, reason: "" });
    first.closeFromFar(1000, "");
    // a late frame of a closed socket is nothing
    sockets.take({ socket: "a", frame: "late" });
    assert.deepEqual(first.sent, []);

    second.closeFromFar(1011, "Incorrect API key provided: sk-proj-abcdefgh1234");
    assert.deepEqual(said, [
      { socket: "a", opened: true },
      { socket: "b", opened: true },
      { socket: "b", closed: true, code: 1011, reason: "Incorrect API key provided: sk…" },
    ]);
    assert.equal(sockets.size, 0);
  } finally {
    stop();
  }
});

test("a mind with no /secrets/openai is a refusal: the app falls back", async () => {
  const { said, sockets, stop } = job(fakeMind());
  try {
    await sockets.take({ socket: "7", open: true });
    const [line] = said;
    assert.equal(line.socket, "7");
    assert.equal(line.refused, true);
    assert.match(line.failed, /no stored mind secret/);
    assert.equal(sockets.size, 0);
  } finally {
    stop();
  }
});

test("OpenAI's no to the upgrade is a refusal, and its words lose any key", async () => {
  const mind = fakeMind();
  mind.fetch = async () => new Response(JSON.stringify({ error: { message: "Incorrect API key provided: sk-proj-abcdefghijkl1234" } }), { status: 401 });
  const { said, sockets, stop } = job(mind);
  try {
    await sockets.take({ socket: "7", open: true });
    assert.deepEqual(said, [{ socket: "7", failed: "OpenAI answered 401: Incorrect API key provided: sk…", refused: true }]);
  } finally {
    stop();
  }
});

test("an error of OpenAI's servers, or an answer with no socket, may pass: a failure, not a refusal", async () => {
  const mind = fakeMind();
  const answers = [new Response("upstream unavailable", { status: 503 }), new Response("ok", { status: 200 })];
  mind.fetch = async () => answers.shift();
  const { said, sockets, stop } = job(mind);
  try {
    await sockets.take({ socket: "1", open: true });
    await sockets.take({ socket: "2", open: true });
    assert.deepEqual(said, [
      { socket: "1", failed: "OpenAI answered 503: upstream unavailable" },
      { socket: "2", failed: "OpenAI answered 200: ok" },
    ]);
  } finally {
    stop();
  }
});

test("no socket within the bound is a failure, and one that comes later is closed", async () => {
  const mind = fakeMind();
  let answer;
  mind.fetch = () => new Promise((resolve) => (answer = resolve));
  const { said, sockets, stop } = job(mind, { withinMs: 50 });
  try {
    const started = Date.now();
    await sockets.take({ socket: "1", open: true });
    assert.ok(Date.now() - started < 1000);
    assert.deepEqual(said, [{ socket: "1", failed: "no socket from the mind in 0.05 s" }]);
    const late = fakeSocket();
    answer({ status: 200, webSocket: late });
    await until(() => late.closedWith);
    assert.deepEqual(late.closedWith, { code: 1000, reason: "came too late" });
    assert.equal(said.length, 1);
  } finally {
    stop();
  }
});

test("no connection within the bound is a failure, not a refusal", async () => {
  const mind = fakeMind();
  mind.refuseConnects = Infinity;
  const { said, sockets, stop } = job(mind, { withinMs: 50 });
  try {
    await sockets.take({ socket: "1", open: true });
    assert.equal(said[0].socket, "1");
    assert.equal(said[0].refused, undefined);
    assert.match(said[0].failed, /no connection|ECONNREFUSED/);
  } finally {
    stop();
  }
});

test("a drop of the link's connection fails every socket on it, and closes the upstream", async () => {
  const mind = fakeMind();
  const upstreams = [fakeSocket(), fakeSocket()];
  const given = [...upstreams];
  mind.fetch = async () => ({ status: 200, webSocket: given.shift() });
  const { said, sockets, stop } = job(mind);
  try {
    await sockets.take({ socket: "1", open: true });
    await sockets.take({ socket: "2", open: true });
    mind.connections[0].end();
    await until(() => said.filter((line) => line.failed).length === 2);
    assert.deepEqual(
      said.filter((line) => line.failed),
      [
        { socket: "1", failed: "the connection to the mind ended" },
        { socket: "2", failed: "the connection to the mind ended" },
      ],
    );
    assert.deepEqual(upstreams.map((socket) => socket.closedWith?.code), [1001, 1001]);
    assert.equal(sockets.size, 0);
  } finally {
    stop();
  }
});

test("an error of the upstream socket fails it", async () => {
  const mind = fakeMind();
  const upstream = fakeSocket();
  mind.fetch = async () => ({ status: 200, webSocket: upstream });
  const { said, sockets, stop } = job(mind);
  try {
    await sockets.take({ socket: "1", open: true });
    upstream.fail("reset by peer, Bearer sk-abcdef123");
    assert.deepEqual(said.at(-1), { socket: "1", failed: "the socket failed: reset by peer, Bearer …" });
    assert.equal(upstream.closedWith.code, 1011);
  } finally {
    stop();
  }
});

test("the redaction cuts tokens, keys and Bearer values", () => {
  assert.equal(redacted("ek_1234567890 and sk-abcd1234 and Bearer xyz"), "ek… and sk… and Bearer …");
});

test("the bridge runs the job by its line, names the job and the socket, and its end closes every socket", async () => {
  const mind = fakeMind();
  const upstream = fakeSocket();
  mind.fetch = async () => ({ status: 200, webSocket: upstream });
  const said = [];
  const bridge = mindBridge({ mind: "example.com", name: "test", connect: mind.connect, sleep: mind.sleep, say: (line) => said.push(line) });
  bridge.take({ job: "openai", socket: "a1", open: true });
  await until(() => said.some((line) => line.opened));
  bridge.take({ job: "openai", socket: "a1", frame: "hello" });
  upstream.frame("world");
  await bridge.end();
  assert.deepEqual(upstream.sent, ["hello"]);
  assert.equal(upstream.closedWith.code, 1001);
  assert.deepEqual(
    said.filter((line) => line.job),
    [
      { job: "openai", socket: "a1", opened: true },
      { job: "openai", socket: "a1", frame: "world" },
      { job: "openai", socket: "a1", failed: "the mind's process ends" },
    ],
  );
});
