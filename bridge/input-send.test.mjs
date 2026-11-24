// node --test bridge/input-send.test.mjs — an input goes into a mind as its files and ONE event.
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { INPUT_SUBMITTED, mindFileName, sendInput } from "./input-send.mjs";

/** A mind that keeps what it was sent: the signed links, the bytes through the connection, the events. */
function mind({ appendError } = {}) {
  const seen = { presigned: [], put: [], through: [], appended: [], contexts: [] };
  const itx = {
    r2: {
      presign: async ({ key, method }) => (seen.presigned.push([method, key]), { url: `https://mind.test/${key}` }),
      put: async (key, bytes, options) => seen.through.push([key, bytes.length, options.httpMetadata.contentType]),
    },
    cd: (path) => ({
      append: async (event) => {
        seen.contexts.push(path);
        if (appendError) throw appendError;
        seen.appended.push(event);
      },
    }),
  };
  return { seen, connect: async () => ({ itx }) };
}

function folderWith(files) {
  const folder = mkdtempSync(join(tmpdir(), "input-send-"));
  return {
    folder,
    files: Object.entries(files).map(([name, text]) => {
      writeFileSync(join(folder, name), text);
      return { local: join(folder, name), name, contentType: name.endsWith(".png") ? "image/png" : "text/plain" };
    }),
    remove: () => rmSync(folder, { recursive: true, force: true }),
  };
}

test("a text with no file is one event on the device's context, and nothing else", async () => {
  const { seen, connect } = mind();
  const payload = await sendInput({ input: { id: "a1", text: "open the roadmap", at: "2026-11-24T14:00:00Z" }, name: "jane.mac", connect });
  assert.deepEqual(seen.presigned, []);
  assert.deepEqual(seen.contexts, ["/devices/jane.mac"]);
  assert.deepEqual(seen.appended, [
    { type: INPUT_SUBMITTED, payload: { id: "a1", text: "open the roadmap", at: "2026-11-24T14:00:00Z", files: [] }, idempotencyKey: "device/input-submitted/a1" },
  ]);
  assert.deepEqual(payload, seen.appended[0].payload);
});

test("each file goes up under the input's own folder before the event names it", async () => {
  const { seen, connect } = mind();
  const local = folderWith({ "notes.txt": "hello", "shot.png": "12345678" });
  const order = [];
  const lines = [];
  try {
    await sendInput({
      input: { id: "b2", text: "", at: "t", files: local.files },
      name: "jane.mac",
      connect: async () => {
        const connection = await connect();
        const cd = connection.itx.cd;
        connection.itx.cd = (path) => ({ append: (event) => (order.push("event"), cd(path).append(event)) });
        return connection;
      },
      say: (line) => lines.push(line),
      put: async (url, path, contentType, size, said) => {
        order.push("put");
        seen.put.push([url, contentType, size]);
        said(size);
      },
    });
  } finally {
    local.remove();
  }
  assert.deepEqual(order, ["put", "put", "event"]);
  assert.deepEqual(seen.put.sort(), [
    ["https://mind.test/devices/jane.mac/inputs/b2/1-notes.txt", "text/plain", 5],
    ["https://mind.test/devices/jane.mac/inputs/b2/2-shot.png", "image/png", 8],
  ]);
  assert.deepEqual(seen.appended[0].payload.files, [
    { path: "/devices/jane.mac/inputs/b2/1-notes.txt", name: "notes.txt", contentType: "text/plain", bytes: 5 },
    { path: "/devices/jane.mac/inputs/b2/2-shot.png", name: "shot.png", contentType: "image/png", bytes: 8 },
  ]);
  assert.ok(lines.every((line) => line.progress >= 0 && line.progress <= 1));
});

test("a signed route that answers 5xx sends a small file through the connection", async () => {
  const { seen, connect } = mind();
  const local = folderWith({ "notes.txt": "hello" });
  try {
    await sendInput({
      input: { id: "c3", text: "x", at: "t", files: local.files },
      name: "jane.mac",
      connect,
      put: async () => {
        throw new Error("HTTP 500 error code: 1101");
      },
    });
  } finally {
    local.remove();
  }
  assert.deepEqual(seen.through, [["devices/jane.mac/inputs/c3/1-notes.txt", 5, "text/plain"]]);
  assert.equal(seen.appended.length, 1);
});

test("a file that does not go up fails the input with its name, and no event is added", async () => {
  const { seen, connect } = mind();
  const local = folderWith({ "notes.txt": "hello" });
  try {
    await assert.rejects(
      sendInput({
        input: { id: "d4", text: "x", at: "t", files: local.files },
        name: "jane.mac",
        connect,
        put: async () => {
          throw new Error("HTTP 403 no");
        },
      }),
      /notes\.txt did not go up: HTTP 403 no/,
    );
  } finally {
    local.remove();
  }
  assert.deepEqual(seen.through, []);
  assert.deepEqual(seen.appended, []);
});

test("an event the mind has already is a sent input; any other refusal is a failure", async () => {
  const twice = mind({ appendError: Object.assign(new Error("the key is taken"), { code: "IDEMPOTENCY_CONFLICT" }) });
  await sendInput({ input: { id: "e5", text: "x", at: "t" }, name: "jane.mac", connect: twice.connect });
  const refused = mind({ appendError: new Error("no rewrite rule matches") });
  await assert.rejects(sendInput({ input: { id: "e5", text: "x", at: "t" }, name: "jane.mac", connect: refused.connect }), /no rewrite rule/);
});

test("no sign-in fails with the connection's own words", async () => {
  await assert.rejects(
    sendInput({ input: { id: "f6", text: "x", at: "t" }, name: "jane.mac", connect: async () => Promise.reject(new Error("Not signed in to example.com: run iterate login")) }),
    /run iterate login/,
  );
});

test("a file's name in the mind keeps no slash, no control character and no leading dot", () => {
  assert.equal(mindFileName(0, "a/b\\c.txt"), "1-a_b_c.txt");
  assert.equal(mindFileName(1, "..env"), "2-env");
  assert.equal(mindFileName(2, "line\nbreak.md"), "3-line_break.md");
  assert.equal(mindFileName(3, ""), "4-file");
  assert.equal(mindFileName(4, "Screenshot 2026-11-24 at 14.02.11.png"), "5-Screenshot 2026-11-24 at 14.02.11.png");
});
