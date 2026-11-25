// node --test bridge/input.test.mjs — an input goes into a mind as its files and ONE event, against
// the fake mind.
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, test } from "node:test";
import { fakeMind } from "./fake-mind.test-helper.mjs";
import { INPUT_SUBMITTED, mindFileName, sendInput } from "./input.mjs";
import { mindLink } from "./mind.mjs";

/** The fake mind and a connection to it, for the device jane.mac. */
function mind({ connect } = {}) {
  const fake = fakeMind();
  const link = mindLink({ name: "jane.mac", connect: connect ?? fake.connect, sleep: () => new Promise((resolve) => setTimeout(resolve, 5)), say: () => {} });
  const send = (input, more = {}) => sendInput({ input, name: "jane.mac", link, ...more }).finally(() => link.stop());
  const events = () => fake.appended.map(({ type, payload, idempotencyKey, path }) => ({ type, payload, idempotencyKey, path }));
  return { fake, send, events };
}

function folderWith(files) {
  const folder = mkdtempSync(join(tmpdir(), "input-"));
  return {
    files: Object.entries(files).map(([name, text]) => {
      writeFileSync(join(folder, name), text);
      return { local: join(folder, name), name, contentType: name.endsWith(".png") ? "image/png" : "text/plain" };
    }),
    remove: () => rmSync(folder, { recursive: true, force: true }),
  };
}

test("a text with no file is one event on the device's context, and nothing else", async () => {
  const { fake, send, events } = mind();
  const payload = await send({ id: "a1", text: "open the roadmap", at: "2026-11-24T14:00:00Z" });
  assert.equal(fake.files.size, 0);
  assert.deepEqual(events(), [
    {
      type: INPUT_SUBMITTED,
      payload: { id: "a1", text: "open the roadmap", at: "2026-11-24T14:00:00Z", files: [] },
      idempotencyKey: "device/input-submitted/a1",
      path: "/devices/jane.mac",
    },
  ]);
  assert.deepEqual(payload, fake.appended[0].payload);
});

test("each file goes up under the input's own folder before the event names it", async () => {
  const { fake, send } = mind();
  const local = folderWith({ "notes.txt": "hello", "shot.png": "12345678" });
  const lines = [];
  try {
    await send({ id: "b2", text: "", at: "t", files: local.files }, { say: (line) => lines.push(line) });
  } finally {
    local.remove();
  }
  assert.deepEqual(fake.order.slice(0, 2).sort(), ["file devices/jane.mac/inputs/b2/1-notes.txt", "file devices/jane.mac/inputs/b2/2-shot.png"]);
  assert.deepEqual(fake.order.slice(2), ["event device/input-submitted"]);
  assert.deepEqual(
    [...fake.files].map(([key, file]) => [key, file.contentType, file.bytes.length, file.via]).sort(),
    [
      ["devices/jane.mac/inputs/b2/1-notes.txt", "text/plain", 5, "signed"],
      ["devices/jane.mac/inputs/b2/2-shot.png", "image/png", 8, "signed"],
    ],
  );
  assert.deepEqual(fake.appended[0].payload.files, [
    { path: "/devices/jane.mac/inputs/b2/1-notes.txt", name: "notes.txt", contentType: "text/plain", bytes: 5 },
    { path: "/devices/jane.mac/inputs/b2/2-shot.png", name: "shot.png", contentType: "image/png", bytes: 8 },
  ]);
  assert.ok(lines.every((line) => line.progress >= 0 && line.progress <= 1));
});

test("a signed route that answers 5xx sends a small file through the connection", async () => {
  const { fake, send } = mind();
  fake.failSignedPuts = 500;
  const local = folderWith({ "notes.txt": "hello" });
  try {
    await send({ id: "c3", text: "x", at: "t", files: local.files });
  } finally {
    local.remove();
  }
  assert.deepEqual(
    [...fake.files].map(([key, file]) => [key, file.bytes.length, file.contentType, file.via]),
    [["devices/jane.mac/inputs/c3/1-notes.txt", 5, "text/plain", "connection"]],
  );
  assert.equal(fake.appended.length, 1);
});

test("a file that does not go up fails the input with its name, and no event is added", async () => {
  const { fake, send } = mind();
  fake.failSignedPuts = 403;
  const local = folderWith({ "notes.txt": "hello" });
  try {
    await assert.rejects(send({ id: "d4", text: "x", at: "t", files: local.files }), /notes\.txt did not go up: HTTP 403/);
  } finally {
    local.remove();
  }
  assert.equal(fake.files.size, 0);
  assert.deepEqual(fake.appended, []);
});

test("an event the mind has already is a sent input; any other refusal is a failure", async () => {
  const twice = mind();
  twice.fake.failNextAppend = Object.assign(new Error("the key is taken"), { code: "IDEMPOTENCY_CONFLICT" });
  await twice.send({ id: "e5", text: "x", at: "t" });
  const refused = mind();
  refused.fake.failNextAppend = new Error("no rewrite rule matches");
  await assert.rejects(refused.send({ id: "e5", text: "x", at: "t" }), /no rewrite rule/);
});

test("no sign-in fails with the connection's own words", async () => {
  const { send } = mind({ connect: async () => Promise.reject(new Error("Not signed in to example.com: run iterate login")) });
  await assert.rejects(send({ id: "f6", text: "x", at: "t" }, { silentMs: 100 }), /run iterate login/);
});

test("a file's name in the mind keeps no slash, no control character and no leading dot", () => {
  assert.equal(mindFileName(0, "a/b\\c.txt"), "1-a_b_c.txt");
  assert.equal(mindFileName(1, "..env"), "2-env");
  assert.equal(mindFileName(2, "line\nbreak.md"), "3-line_break.md");
  assert.equal(mindFileName(3, ""), "4-file");
  assert.equal(mindFileName(4, "Screenshot 2026-11-24 at 14.02.11.png"), "5-Screenshot 2026-11-24 at 14.02.11.png");
});

test("a send again after a lost answer: unchanged it is the same input; changed it is a new one that leaves the first one's files", async () => {
  const { fake, send, events } = mind();
  const local = folderWith({ "notes.txt": "one" });
  const folder = mkdtempSync(join(tmpdir(), "input-folder-"));
  try {
    fake.dropNextAnswer = true;
    await assert.rejects(send({ id: "c3", text: "hi", at: "t1", files: local.files }, { folder }));
    // the same input again (a send has a new time)
    await sendInput({ input: { id: "c3", text: "hi", at: "t2", files: local.files }, name: "jane.mac", link: linkTo(fake), folder });
    assert.equal(events().length, 1, "the mind has it once");
    // changed after the failure: other words, other bytes
    writeFileSync(local.files[0].local, "two");
    const payload = await sendInput({ input: { id: "c3", text: "hi there", at: "t3", files: local.files }, name: "jane.mac", link: linkTo(fake), folder });
    assert.match(payload.id, /^c3-[0-9a-f]{16}$/);
    assert.deepEqual(events().map((event) => event.payload.text), ["hi", "hi there"]);
    assert.equal(fake.files.get("devices/jane.mac/inputs/c3/1-notes.txt").bytes.toString(), "one", "the first event's file is as it was");
    assert.equal(fake.files.get(`devices/jane.mac/inputs/${payload.id}/1-notes.txt`).bytes.toString(), "two");
  } finally {
    local.remove();
    rmSync(folder, { recursive: true, force: true });
  }
});

const links = [];
after(() => links.forEach((link) => link.stop()));
const linkTo = (fake) => {
  const link = mindLink({ name: "jane.mac", connect: fake.connect, sleep: () => new Promise((resolve) => setTimeout(resolve, 5)), say: () => {} });
  links.push(link);
  return link;
};

test("a send with no answer is aborted: its PUT ends and nothing is appended after", async () => {
  const fake = fakeMind();
  const requests = [];
  const server = createServer((request) => requests.push(request));
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const link = mindLink({
    name: "jane.mac",
    connect: async () => {
      const connection = await fake.connect();
      connection.itx.r2.presign = async ({ key }) => ({ url: `http://127.0.0.1:${server.address().port}/${key}` });
      return connection;
    },
    sleep: () => new Promise((resolve) => setTimeout(resolve, 5)),
    say: () => {},
  });
  const local = folderWith({ "big.txt": "x".repeat(1000) });
  try {
    await assert.rejects(sendInput({ input: { id: "d4", text: "", at: "t", files: local.files }, name: "jane.mac", link, silentMs: 200 }), /no answer/);
    await new Promise((resolve) => setTimeout(resolve, 50));
    assert.equal(requests.length, 1);
    assert.equal(requests[0].destroyed, true, "the PUT was ended");
    assert.equal(fake.appended.length, 0);
  } finally {
    link.stop();
    server.close();
    local.remove();
  }
});
