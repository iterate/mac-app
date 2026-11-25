// This Mac's pages (pages.mjs), as a mind calls them: `http` for each path, the Off choice, the
// live view's bounds (a cancel stops the frames, a slow reader holds at most one frame, two at
// once, ten minutes), and the whole endpoint (mac-endpoint.ts) on a fake app's socket, through
// a real capnweb session when the installed runtime has capnweb.
import assert from "node:assert/strict";
import { existsSync, mkdtempSync } from "node:fs";
import { createServer } from "node:net";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { BOUNDARY, MOST_STREAMS, STREAM_MS, pages } from "./pages.mjs";
import { eventually } from "./fake-mind.test-helper.mjs";

const OFF = "The Mac's owner has this off in the iterate panel: Pages. A mind cannot open this Mac's pages.";
const JPEG = (n) => Buffer.from([0xff, 0xd8, n, 0xff, 0xd9]);

/** The app's side of the socket, as a function: what PagePowers.swift answers. */
function fakeApp({ off = false, endAfter = Infinity } = {}) {
  const app = { asked: [], frames: 0, stops: [], streams: 0 };
  app.ask = async (method, parameters = {}) => {
    app.asked.push(method);
    if (off && method !== "pages.live.stop") throw new Error(OFF);
    switch (method) {
      case "state":
        return { things: [] };
      case "pages.state":
        return { mac: "test.mac", mind: "example.com", lend: { phase: "live", line: "Live since 14:00" }, record: { recording: false, line: "Off" }, acts: [], displays: [{ display: 0, name: "Display", sharing: "shared" }] };
      case "pages.live.start":
        return { stream: `s${++app.streams}`, display: "Display", perSecond: 4, maxWidth: parameters.maxWidth, seconds: 600 };
      case "pages.live.frame":
        if (app.frames >= endAfter) throw new Error("The live view ended: the owner turned Display off.");
        app.frames++;
        return { jpegBase64: JPEG(app.frames).toString("base64"), pixelWidth: 1280, pixelHeight: 800, frame: app.frames };
      case "pages.live.stop":
        app.stops.push(parameters);
        return { streams: 0 };
      default:
        throw new Error(`No method "${method}".`);
    }
  };
  return app;
}

/** A clock that only the test moves, and a sleep that moves it. */
function fakeClock() {
  const clock = { t: 1_000_000 };
  clock.now = () => clock.t;
  clock.sleep = async (ms) => {
    clock.t += ms;
  };
  return clock;
}

/** The multipart parts read so far: each one's head and its JPEG. */
function partsOf(bytes) {
  const text = Buffer.from(bytes).toString("latin1");
  const parts = [];
  const head = new RegExp(`--${BOUNDARY}\\r\\nContent-Type: image/jpeg\\r\\nContent-Length: (\\d+)\\r\\n\\r\\n`, "g");
  for (let match; (match = head.exec(text)); ) {
    const length = Number(match[1]);
    const start = match.index + match[0].length;
    parts.push(Buffer.from(text.slice(start, start + length), "latin1"));
    assert.equal(text.slice(start + length, start + length + 2), "\r\n", "each JPEG ends with CRLF before the next boundary");
    head.lastIndex = start + length;
  }
  return { parts, closed: text.endsWith(`--${BOUNDARY}--\r\n`) };
}

async function readParts(stream, count) {
  const reader = stream.getReader();
  let bytes = Buffer.alloc(0);
  while (partsOf(bytes).parts.length < count) {
    const { value, done } = await reader.read();
    if (done) break;
    bytes = Buffer.concat([bytes, value]);
  }
  return { reader, bytes };
}

test("/ is the page, /state.json the app's data, anything else 404, and only GET", async () => {
  const app = fakeApp();
  const { http } = pages({ ask: app.ask });
  const page = await http({ method: "GET", path: "/", query: {}, headers: {} });
  assert.equal(page.status, 200);
  assert.match(page.headers["content-type"], /^text\/html/);
  const html = Buffer.from(page.body).toString();
  assert.match(html, /state\.json/);
  assert.match(html, /live\.mjpeg/);
  assert.match(html, /system-ui/);
  assert.match(html, /prefers-color-scheme: dark/);

  const state = await http({ path: "/state.json" });
  assert.equal(state.status, 200);
  assert.match(state.headers["content-type"], /^application\/json/);
  assert.equal(JSON.parse(state.body).mac, "test.mac");
  assert.deepEqual(app.asked, ["pages.state", "pages.state"]);

  assert.equal((await http({ path: "/../bridge/pages.mjs" })).status, 404);
  assert.equal((await http({ path: "/nothing" })).status, 404);
  const post = await http({ method: "POST", path: "/" });
  assert.equal(post.status, 405);
  assert.equal(post.headers.allow, "GET");
});

test("Off refuses every path with the owner's words, and no live view starts", async () => {
  const app = fakeApp({ off: true });
  const { http, streams } = pages({ ask: app.ask });
  for (const path of ["/", "/state.json", "/live.mjpeg"]) {
    const answer = await http({ path });
    assert.equal(answer.status, 403, path);
    assert.equal(answer.body, `${OFF}\n`);
  }
  assert.equal(streams.size, 0);
  assert.equal(app.frames, 0);
});

test("the app that does not run is a 503", async () => {
  const { http } = pages({
    ask: async () => {
      throw new Error("The iterate menu-bar app is not running on this Mac: its owner starts it.");
    },
  });
  assert.equal((await http({ path: "/state.json" })).status, 503);
});

test("/live.mjpeg is multipart JPEG frames, at most 4 a second, 1280 px wide", async () => {
  const app = fakeApp();
  const clock = fakeClock();
  const asked = [];
  const ask = (method, parameters) => (asked.push({ method, parameters, t: clock.now() }), app.ask(method, parameters));
  const { http } = pages({ ask, now: clock.now, sleep: clock.sleep });
  const answer = await http({ path: "/live.mjpeg", query: {} });
  assert.equal(answer.status, 200);
  assert.equal(answer.headers["content-type"], `multipart/x-mixed-replace; boundary=${BOUNDARY}`);
  assert.equal(asked[0].parameters.maxWidth, 1280);
  assert.equal(asked[0].parameters.display, 0);
  const { reader, bytes } = await readParts(answer.body, 3);
  const { parts } = partsOf(bytes);
  assert.deepEqual(parts.slice(0, 3), [JPEG(1), JPEG(2), JPEG(3)]);
  const times = asked.filter((a) => a.method === "pages.live.frame").map((a) => a.t);
  for (let i = 1; i < times.length; i++) assert.ok(times[i] - times[i - 1] >= 250, `frames ${times[i - 1]} → ${times[i]}`);
  await reader.cancel();
});

test("a cancel of the stream stops the frames at once and ends the view in the app", async () => {
  const app = fakeApp();
  const { http, streams } = pages({ ask: app.ask, sleep: async () => {} });
  const answer = await http({ path: "/live.mjpeg" });
  const { reader } = await readParts(answer.body, 2);
  assert.equal(streams.size, 1);
  await reader.cancel();
  const frames = app.frames;
  await new Promise((resolve) => setTimeout(resolve, 50));
  assert.equal(app.frames, frames, "no frame is made after the cancel");
  assert.deepEqual(app.stops, [{ stream: "s1", why: "the reader went away" }]);
  assert.equal(streams.size, 0);
});

test("a slow reader holds at most one frame: the frames between its reads are never made", async () => {
  const app = fakeApp();
  const { http } = pages({ ask: app.ask, sleep: async () => {} });
  const answer = await http({ path: "/live.mjpeg" });
  const reader = answer.body.getReader();
  await reader.read();
  // the reader rests: no frame is asked while no read waits
  await new Promise((resolve) => setTimeout(resolve, 100));
  assert.ok(app.frames <= 2, `${app.frames} frames made for one read`);
  await reader.read();
  await new Promise((resolve) => setTimeout(resolve, 50));
  assert.ok(app.frames <= 3, `${app.frames} frames made for two reads`);
  await reader.cancel();
});

test(`at most ${MOST_STREAMS} views at once; a closed one makes room`, async () => {
  const app = fakeApp();
  const { http } = pages({ ask: app.ask, sleep: async () => {} });
  const views = [];
  for (let i = 0; i < MOST_STREAMS; i++) views.push(await http({ path: "/live.mjpeg" }));
  const third = await http({ path: "/live.mjpeg" });
  assert.equal(third.status, 429);
  assert.equal(app.asked.filter((m) => m === "pages.live.start").length, MOST_STREAMS);
  await views[0].body.cancel();
  assert.equal((await http({ path: "/live.mjpeg" })).status, 200);
});

test("a view ends after ten minutes, and when the app ends it, with the closing boundary", async () => {
  const clock = fakeClock();
  const app = fakeApp();
  const { http, streams } = pages({ ask: app.ask, now: clock.now, sleep: clock.sleep });
  const answer = await http({ path: "/live.mjpeg" });
  const { reader, bytes: first } = await readParts(answer.body, 1);
  clock.t += STREAM_MS;
  let bytes = first;
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    bytes = Buffer.concat([bytes, value]);
  }
  assert.ok(partsOf(bytes).closed);
  assert.match(app.stops[0].why, /10 minutes/);
  assert.equal(streams.size, 0);

  const ended = fakeApp({ endAfter: 2 });
  const second = await pages({ ask: ended.ask, sleep: async () => {} }).http({ path: "/live.mjpeg" });
  const all = await new Response(second.body).arrayBuffer();
  const read = partsOf(new Uint8Array(all));
  assert.equal(read.parts.length, 2);
  assert.ok(read.closed);
  assert.match(ended.stops[0].why, /turned Display off/);
});

/** The app's socket in a home of its own: one line of JSON in, one out, as LocalEndpoint.swift. */
async function appSocket(app) {
  const home = mkdtempSync(join(tmpdir(), "pages-"));
  const server = createServer((socket) => {
    let text = "";
    socket.setEncoding("utf8");
    socket.on("data", async (chunk) => {
      text += chunk;
      if (!text.includes("\n")) return;
      const { method, ...parameters } = JSON.parse(text.slice(0, text.indexOf("\n")));
      const answer = await app.ask(method, parameters).then((ok) => ({ ok }), (error) => ({ error: error.message }));
      socket.end(`${JSON.stringify(answer)}\n`);
    });
  });
  await new Promise((resolve) => server.listen(join(home, "endpoint.sock"), resolve));
  return { home, close: () => server.close() };
}

/** capnweb from the installed app's runtime, read only; null where there is none (CI). */
async function capnweb() {
  const path = process.env.ITERATE_CAPNWEB ?? join(homedir(), "Library/Application Support/iterate-mac-app/runtime/node_modules/capnweb/dist/index.js");
  return existsSync(path) ? import(path) : null;
}

test("the endpoint lends http: the mind reads 3 frames over capnweb, and its cancel stops the view", async (t) => {
  const app = fakeApp();
  const socket = await appSocket(app);
  t.after(socket.close);
  process.env.ITERATE_MAC_HOME = socket.home;
  process.env.ITERATE_MAC_APP_SUPERVISED = "1";
  const { default: macEndpoint } = await import("./mac-endpoint.ts");
  const lent = await macEndpoint();
  const rpc = await capnweb();
  let mac = lent;
  if (rpc) {
    // the mind's end and the Mac's end of one session, as `iterate provide` holds it
    const { port1, port2 } = new MessageChannel();
    class Lent extends rpc.RpcTarget {
      http(request) {
        return lent.http(request);
      }
    }
    rpc.newMessagePortRpcSession(port1, new Lent());
    mac = rpc.newMessagePortRpcSession(port2);
    t.after(() => {
      port1.close();
      port2.close();
    });
  } else t.diagnostic("no capnweb in the installed runtime: the call is direct");

  const state = await mac.http({ method: "GET", path: "/state.json", query: {}, headers: {} });
  assert.equal(state.status, 200);
  assert.equal(JSON.parse(state.body).mac, "test.mac");

  const answer = await mac.http({ method: "GET", path: "/live.mjpeg", query: {}, headers: {} });
  assert.equal(answer.status, 200);
  assert.ok(answer.body instanceof ReadableStream);
  // what a mind's site does with it (pages/MIND-ROUTE.md)
  const response = new Response(answer.body, { status: answer.status, headers: answer.headers });
  assert.match(response.headers.get("content-type"), /multipart\/x-mixed-replace; boundary=frame/);
  const { reader, bytes } = await readParts(response.body, 3);
  assert.deepEqual(partsOf(bytes).parts.slice(0, 3), [JPEG(1), JPEG(2), JPEG(3)]);
  await reader.cancel();
  await eventually(() => app.stops.length === 1, 3000);
  const frames = app.frames;
  await new Promise((resolve) => setTimeout(resolve, 600));
  assert.equal(app.frames, frames, "no frame after the cancel reached the Mac");
  assert.equal(app.stops[0].why, "the reader went away");
});
