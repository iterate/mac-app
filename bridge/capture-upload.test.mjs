// node --test bridge/capture-upload.test.mjs — the words of a capture come from the app as
// segments, and go to the numbered pictures and to transcript.json. With no mind to reach: the
// text for the clipboard and transcript.json come before any upload.
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";

const script = join(import.meta.dirname, "capture-upload.mjs");

/** A capture's folder with capture.json: two numbered pictures, at 3 s and at 8 s. */
function captureFolder() {
  const folder = mkdtempSync(join(tmpdir(), "capture-upload-"));
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

/** The uploader with `lines` on stdin (then stdin closes), and every JSON line it printed. */
function upload(folder, lines, more = []) {
  const child = spawn(process.execPath, [script, folder, "--iterate", "/nowhere/bin/iterate.js", "--mind", "example.com", ...more]);
  let out = "";
  child.stdout.on("data", (chunk) => (out += chunk));
  for (const line of lines) child.stdin.write(`${line}\n`);
  // a moment for `copy`'s text, which is said one turn later
  setTimeout(() => child.stdin.end(), 300);
  return new Promise((resolve) => child.on("exit", () => resolve(out.trim().split("\n").filter(Boolean).map((line) => JSON.parse(line)))));
}

const segment = (t, to, text) => `segment ${JSON.stringify({ t, to, text, words: [{ t, to: t + 400, text: text.split(" ")[0] }] })}`;

test("segments go to the picture that ends after they start, and to transcript.json at `heard`", async () => {
  const folder = captureFolder();
  try {
    const said = await upload(folder, [segment(5200, 6900, "and this is slow"), segment(1000, 2500, "what is this here?"), "heard", "copy"], ["--heard-by", "parakeet-v3"]);
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
    const said = await upload(folder, [segment(1000, 2500, "what is this here?"), "copy"]);
    const { copy } = said.find((line) => line.copy);
    assert.match(copy, /#1 \(0:03\) drew “what is this here\?”/);
    assert.match(copy, /The last words are not in this text yet/);
  } finally {
    rmSync(folder, { recursive: true, force: true });
  }
});

test("--finish reads the words of the transcript.json that stayed on this Mac", async () => {
  const folder = captureFolder();
  writeFileSync(
    join(folder, "transcript.json"),
    JSON.stringify({ by: { kind: "model", id: "parakeet-ultra" }, basis: ["voice.m4a"], segments: [{ t: 7000, to: 7600, text: "this one", words: [] }] }),
  );
  try {
    const child = spawn(process.execPath, [script, folder, "--finish", "--iterate", "/nowhere/bin/iterate.js", "--mind", "example.com"]);
    let out = "";
    child.stdout.on("data", (chunk) => (out += chunk));
    await new Promise((resolve) => child.on("exit", resolve));
    const lines = out.trim().split("\n").map((line) => JSON.parse(line));
    // no mind here: the capture stays, and its text names this Mac's folder with the words
    const failed = lines.find((line) => line.failed);
    assert.match(failed.copy, /#2 \(0:08\) clicked “this one”/);
    assert.equal(JSON.parse(readFileSync(join(folder, "transcript.json"), "utf8")).by.id, "parakeet-ultra");
  } finally {
    rmSync(folder, { recursive: true, force: true });
  }
});
