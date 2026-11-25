// input.mjs: the job `input` of mind.mjs: one input of the person (Sources/VoiceMeetMac/MindInput.swift:
// ⌥⇧Space, a text and files) into a mind.
//
// The app sends `{ job: "input", input: <id>, folder }`. `<folder>/input.json` is the input:
// { id, text, at, files: [{ local, name, contentType }] }, where `local` is a file's path on this
// Mac. It goes on the connection of mind.mjs, as the person (the iterate CLI's own sign-in:
// `iterate login <mind>`; the Mac's key lends and does nothing else). Each file goes into the
// mind's files as /devices/<name>/inputs/<id>/<n>-<name> (upload.mjs). Then ONE event is appended
// to the context /devices/<name>:
//
//   device/input-submitted { id, text, at, files: [{ path, name, contentType, bytes }] }
//
// with the idempotency key `device/input-submitted/<id>`: a second send of the same input (the
// answer of the first one was lost) adds no second event. That event is the whole contract: this
// job and the app know no agent and no backend. What a mind does with an input is its config.
//
// An input whose answer was lost is sent again with the same id. Just before its append the job
// writes `<folder>/sent.json`, the digest of the text and the files' bytes it sends. A send again
// with the same digest is the same input: its key is the same, and a conflict of it means the mind
// has it. A send again with another digest (the person changed the text or the files after the
// failure) may follow an event that the mind has: it goes as the id `<id>-<digest>`, under its
// own files, so it neither replaces the files of the event before nor is taken for it.
//
// It says { progress } (0 to 1, of the bytes), then { done: true } or { failed } (the reason, in
// words for the person). A send given up (no answer) is aborted: its PUTs end, and it appends
// nothing after that.
import { createHash } from "node:crypto";
import { createReadStream, existsSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { pipeline } from "node:stream/promises";
import { putFile } from "./upload.mjs";

export const INPUT_SUBMITTED = "device/input-submitted";

/** A file's name in the mind: its own name with no slash, no control character and no leading dot,
 *  after its number, so that two files of one name both stay. */
export function mindFileName(index, name) {
  const safe = String(name)
    .replace(/[\u0000-\u001f\u007f/\\]/g, "_")
    .replace(/^\.+/, "")
    .slice(-120);
  return `${index + 1}-${safe || "file"}`;
}

/** The digest of what an input says: its text and each file's name, type and bytes; not its time. */
export async function digestOf(input) {
  const hash = createHash("sha256").update(JSON.stringify([String(input.text ?? ""), (input.files ?? []).map((file) => [file.name, file.contentType ?? ""])]));
  for (const file of input.files ?? []) {
    hash.update("\0");
    await pipeline(createReadStream(file.local), hash, { end: false });
  }
  return hash.digest("hex").slice(0, 16);
}

/**
 * Sends one input on `link` (mind.mjs), for the device `name`. `folder` keeps `sent.json` (above). It answers the event's payload, and
 * throws the reason when the input did not go. With no connection in `silentMs` it fails with the
 * reason the connection did not come; then a mind that does not answer is given up after
 * `silentMs` with no sign of life. A piece of a file that went is such a sign, so a long upload is
 * not cut.
 */
export async function sendInput({ input, name, link, folder, say = () => {}, silentMs = 60_000 }) {
  if (!/^[\w.-]+$/.test(String(input.id))) throw new Error("the input has no usable id");
  const digest = await digestOf(input);
  const marker = folder && join(folder, "sent.json");
  let sentBefore;
  try {
    sentBefore = marker && existsSync(marker) ? JSON.parse(readFileSync(marker, "utf8")).digest : undefined;
  } catch {}
  const id = sentBefore && sentBefore !== digest ? `${input.id}-${digest}` : input.id;
  const files = (input.files ?? []).map((file, index) => ({
    ...file,
    contentType: file.contentType || "application/octet-stream",
    path: `/devices/${name}/inputs/${id}/${mindFileName(index, file.name)}`,
    bytes: statSync(file.local).size,
  }));
  const total = files.reduce((sum, file) => sum + file.bytes, 0);
  const { itx, device } = await link.now(silentMs);
  let timer;
  let giveUp;
  const silent = new Promise((_, reject) => (giveUp = reject));
  // the end of every PUT of this send, and of its append, when it is given up
  const attempt = new AbortController();
  const alive = () => {
    clearTimeout(timer);
    timer = setTimeout(() => {
      const error = new Error(`no answer from the mind in ${silentMs / 1000} s`);
      attempt.abort(error);
      giveUp(error);
    }, silentMs);
  };
  let sent = 0;
  let saidAt = 0;
  const progressed = (bytes) => {
    alive();
    sent += bytes;
    if (Date.now() - saidAt < 100) return;
    saidAt = Date.now();
    say({ progress: total ? Math.min(sent / total, 1) : 1 });
  };
  const send = async () => {
    await Promise.all(
      files.map((file) =>
        putFile({ r2: itx.r2, key: file.path.slice(1), path: file.local, contentType: file.contentType, said: progressed, signal: attempt.signal }).catch(
          (error) => {
            throw new Error(`${file.name} did not go up: ${String(error?.message ?? error)}`);
          },
        ),
      ),
    );
    attempt.signal.throwIfAborted();
    const payload = {
      id,
      text: String(input.text ?? ""),
      at: input.at,
      files: files.map(({ path, name, contentType, bytes }) => ({ path, name, contentType, bytes })),
    };
    if (marker && !sentBefore) writeFileSync(marker, JSON.stringify({ digest }));
    try {
      await device.append({ type: INPUT_SUBMITTED, payload, idempotencyKey: `${INPUT_SUBMITTED}/${id}` });
    } catch (error) {
      // the mind has this input's event already: an earlier send whose answer was lost
      if (error?.code !== "IDEMPOTENCY_CONFLICT") throw error;
    }
    return payload;
  };
  alive();
  try {
    return await Promise.race([send(), silent]);
  } catch (error) {
    // a PUT that failed ends the others
    attempt.abort(error);
    throw error;
  } finally {
    clearTimeout(timer);
  }
}

/** The line `{ input, folder }` of the app: the input of `<folder>/input.json`, then `done` or `failed`. */
export async function inputJob({ line, name, link, say }) {
  try {
    const input = JSON.parse(readFileSync(join(line.folder, "input.json"), "utf8"));
    await sendInput({ input, name, link, folder: line.folder, say });
    say({ done: true });
  } catch (error) {
    say({ failed: String(error?.message ?? error).slice(0, 300) });
  }
}
