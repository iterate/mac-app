// node --test bridge/capture.test.mjs — the words of a capture come from the app as segments, and
// go to the numbered pictures and to transcript.json; the text for the clipboard comes before any
// upload. Against the fake mind.
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
import { test } from "node:test";
import { captureUpload } from "./capture.mjs";
import { fakeMind } from "./fake-mind.test-helper.mjs";
import { mindLink } from "./mind.mjs";

/** A capture's folder with capture.json: two numbered pictures, at 3 s and at 8 s. */
function captureFolder() {
  const folder = mkdtempSync(join(tmpdir(), "capture-"));
  writeFileSync(
    join(folder, "capture.json"),
    JSON.stringify({
      durationMs: 9000,
      microphone: true,
      by: { device: "test.mac" },
      observations: [],
      panels: [
        { n: 1, t: 3000, did: "drew", file: "1.jpg" },
        { n: 2, t: 8000, did: "clicked", file: "2.jpg" },
      ],
    }),
  );
  return folder;
}

/**
 * The capture with `lines`, each a step, and every line it said once `until(said)` is true. The
 * fake mind answers unless `refuse`, and has the `rules` on its root.
 */
async function capture(folder, lines, { kept = false, refuse = false, heardBy, rules = {}, until = (said) => said.some((line) => line.copy) } = {}) {
  const mind = fakeMind();
  Object.assign(mind.rules, rules);
  if (refuse) mind.refuseConnects = 1_000_000;
  const said = [];
  const link = mindLink({ name: "test.mac", connect: mind.connect, sleep: () => new Promise((resolve) => setTimeout(resolve, 5)), say: () => {} });
  const job = captureUpload({ link, mind: "example.com", capture: basename(folder), folder, heardBy, kept, say: (line) => said.push(line), withinMs: 100 });
  for (const line of lines) await job.take(line);
  for (const deadline = Date.now() + 5000; !until(said) && Date.now() < deadline; ) await new Promise((resolve) => setTimeout(resolve, 10));
  link.stop();
  return { said, mind };
}

const segment = (t, to, text) => ({ segment: { t, to, text, words: [{ t, to: t + 400, text: text.split(" ")[0] }] } });

test("segments go to the picture that ends after they start, and to transcript.json at `heard`", async () => {
  const folder = captureFolder();
  try {
    const { said } = await capture(folder, [segment(5200, 6900, "and this is slow"), segment(1000, 2500, "what is this here?"), { heard: true }, { copy: true }], {
      heardBy: "parakeet-v3",
    });
    const { copy } = said.find((line) => line.copy);
    assert.match(copy, /- #1 \(0:03\) drew “what is this here\?”/);
    assert.match(copy, /- #2 \(0:08\) clicked “and this is slow”/);
    assert.doesNotMatch(copy, /last words are not in this text/);
    const transcript = JSON.parse(readFileSync(join(folder, "transcript.json"), "utf8"));
    assert.deepEqual(transcript.by, { kind: "model", id: "parakeet-v3" });
    assert.deepEqual(transcript.basis, ["voice.m4a"]);
    assert.deepEqual(
      transcript.segments.map(({ t, to, text }) => [t, to, text]),
      [
        [1000, 2500, "what is this here?"],
        [5200, 6900, "and this is slow"],
      ],
    );
    assert.deepEqual(transcript.segments[0].words, [{ t: 1000, to: 1400, text: "what" }]);
  } finally {
    rmSync(folder, { recursive: true, force: true });
  }
});

test("before `heard`, the text says that the last words are still to come", async () => {
  const folder = captureFolder();
  try {
    const { said } = await capture(folder, [segment(1000, 2500, "what is this here?"), { copy: true }]);
    const { copy } = said.find((line) => line.copy);
    assert.match(copy, /#1 \(0:03\) drew “what is this here\?”/);
    assert.match(copy, /The last words are not in this text yet/);
  } finally {
    rmSync(folder, { recursive: true, force: true });
  }
});

/** A capture that stayed on this Mac, with the words of its transcript.json. */
function keptFolder() {
  const folder = captureFolder();
  writeFileSync(
    join(folder, "transcript.json"),
    JSON.stringify({ by: { kind: "model", id: "parakeet-ultra" }, basis: ["voice.m4a"], segments: [{ t: 7000, to: 7600, text: "this one", words: [] }] }),
  );
  return folder;
}

test("a capture first heard of at its `finish` reads the words of the transcript.json that stayed on this Mac", async () => {
  const folder = keptFolder();
  try {
    const { said } = await capture(folder, [{ finish: true }], { kept: true, refuse: true, until: (said) => said.some((line) => line.failed) });
    // no mind here: the capture stays, and its text names this Mac's folder with the words
    const failed = said.find((line) => line.failed);
    assert.match(failed.copy, /#2 \(0:08\) clicked “this one”/);
    assert.equal(JSON.parse(readFileSync(join(folder, "transcript.json"), "utf8")).by.id, "parakeet-ultra");
  } finally {
    rmSync(folder, { recursive: true, force: true });
  }
});

test("`finish` puts every file under /captures/<id>/, then adds capture/ready and capture/received", async () => {
  const folder = keptFolder();
  writeFileSync(join(folder, "1.jpg"), "a picture");
  writeFileSync(join(folder, "2.jpg"), "another picture");
  const id = basename(folder);
  try {
    const { said, mind } = await capture(folder, [{ finish: true }], { kept: true, until: (said) => said.some((line) => line.done || line.failed) });
    assert.deepEqual(said.at(-1), { done: true });
    for (const file of ["capture.json", "1.jpg", "2.jpg", "transcript.json", "context.json", "summary.md"])
      assert.ok(mind.files.has(`captures/${id}/${file}`), `${file} is in the mind`);
    assert.match(mind.files.get(`captures/${id}/summary.md`).bytes.toString(), /#2 \(0:08\) clicked “this one”/);
    const events = mind.appended.filter((event) => event.path === `/captures/${id}`).map((event) => event.type);
    assert.deepEqual(events, ["capture/ready", "events.iterate.com/itx/described", "capture/received"]);
  } finally {
    rmSync(folder, { recursive: true, force: true });
  }
});

test("the last words after the movie still go in, capture.json goes up once, and a reconnect between copy and finish sends it", async () => {
  const folder = captureFolder();
  writeFileSync(join(folder, "1.jpg"), "a picture");
  writeFileSync(join(folder, "2.jpg"), "another picture");
  const id = basename(folder);
  const puts = [];
  const mind = fakeMind({ stored: (key) => puts.push(key) });
  const said = [];
  const link = mindLink({ name: "test.mac", connect: mind.connect, sleep: () => new Promise((resolve) => setTimeout(resolve, 5)), say: () => {} });
  const job = captureUpload({ link, mind: "example.com", capture: id, folder, kept: false, say: (line) => said.push(line), withinMs: 2000 });
  try {
    job.take({ copy: true });
    await new Promise((resolve) => setTimeout(resolve, 50));
    // the connection ends between the copy and the finish
    mind.connections[0].end();
    // capture.json grows before the finish (the movie's observations)
    const manifest = JSON.parse(readFileSync(join(folder, "capture.json"), "utf8"));
    writeFileSync(join(folder, "capture.json"), JSON.stringify({ ...manifest, observations: [{ kind: "screen", t: 0, more: "x".repeat(200) }] }));
    const finished = job.take({ finish: true });
    // the speech model ends after the movie
    await new Promise((resolve) => setTimeout(resolve, 50));
    job.take(segment(8500, 8900, "the last words"));
    job.take({ heard: true });
    await finished;
    assert.deepEqual(said.at(-1), { done: true });
    assert.equal(puts.filter((key) => key === `captures/${id}/capture.json`).length, 1, "capture.json went once");
    assert.match(mind.files.get(`captures/${id}/capture.json`).bytes.toString(), /"screen"/);
    assert.match(readFileSync(join(folder, "transcript.json"), "utf8"), /the last words/);
    assert.match(mind.files.get(`captures/${id}/summary.md`).bytes.toString(), /the last words/);
    const events = mind.appended.filter((event) => event.path === `/captures/${id}`).map((event) => event.type);
    assert.deepEqual(events, ["capture/ready", "events.iterate.com/itx/described", "capture/received"]);
  } finally {
    link.stop();
    rmSync(folder, { recursive: true, force: true });
  }
});

test("a mind that has `itx.getScrawl`: the text names the capture's id and the one call, and holds no script", async () => {
  const folder = keptFolder();
  writeFileSync(join(folder, "1.jpg"), "a picture");
  writeFileSync(join(folder, "2.jpg"), "another picture");
  const id = basename(folder);
  try {
    const { said, mind } = await capture(folder, [{ finish: true }], {
      kept: true,
      rules: { "itx.getScrawl": { match: "itx.getScrawl", target: 'itx.builtins.cd("/").config.getScrawl(@)' } },
      until: (said) => said.some((line) => line.done || line.failed),
    });
    assert.deepEqual(said.at(-1), { done: true });
    const text = mind.files.get(`captures/${id}/summary.md`).bytes.toString();
    assert.ok(text.includes(`the capture's id is ${id}`));
    assert.ok(text.includes(`await itx.getScrawl("${id}")`));
    // no script, no path of the mind and no link: the id is a name
    assert.ok(!text.includes("const d ="));
    assert.ok(!text.includes("/captures/"));
    assert.ok(!text.includes("waitForEvent"));
    assert.match(text, /#2 \(0:08\) clicked “this one”/);
    // the clipboard holds one line, the first time too: the id and the call, and no more
    assert.deepEqual(
      said.filter((line) => line.copy).map((line) => line.copy),
      Array(2).fill(`Run itx.getScrawl("${id}") on example.com to see the scrawl`),
    );
  } finally {
    rmSync(folder, { recursive: true, force: true });
  }
});

test("a capture's 13th picture, and a file that no link was asked for, go up", async () => {
  // 20261127T211958Z-0259 on jonas.mac: 12 pictures and the one of its end. "The upload of
  // pictures/13.jpg failed: r2.presign is not a function", and the capture was never ready.
  const folder = keptFolder();
  mkdirSync(join(folder, "pictures"));
  for (const file of ["1.jpg", "2.jpg", "pictures/13.jpg", "pictures/14.jpg"]) writeFileSync(join(folder, file), `the picture ${file}`);
  const id = basename(folder);
  try {
    const { said, mind } = await capture(folder, [{ finish: true }], { kept: true, until: (said) => said.some((line) => line.done || line.failed) });
    assert.deepEqual(said.at(-1), { done: true });
    for (const file of ["pictures/13.jpg", "pictures/14.jpg"]) assert.equal(mind.files.get(`captures/${id}/${file}`).bytes.toString(), `the picture ${file}`);
  } finally {
    rmSync(folder, { recursive: true, force: true });
  }
});

test("a mind with no `itx.getScrawl` still gets the one script", async () => {
  const folder = keptFolder();
  writeFileSync(join(folder, "1.jpg"), "a picture");
  writeFileSync(join(folder, "2.jpg"), "another picture");
  const id = basename(folder);
  try {
    const { said, mind } = await capture(folder, [{ finish: true }], { kept: true, until: (said) => said.some((line) => line.done || line.failed) });
    const text = mind.files.get(`captures/${id}/summary.md`).bytes.toString();
    assert.ok(text.includes(`const d = "/captures/${id}/"`));
    assert.ok(!text.includes("getScrawl"));
    assert.equal(said.filter((line) => line.copy).at(-1).copy, text);
  } finally {
    rmSync(folder, { recursive: true, force: true });
  }
});
