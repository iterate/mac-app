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
// It says { progress } (0 to 1, of the bytes), then { done: true } or { failed } (the reason, in
// words for the person).
import { readFileSync, statSync } from "node:fs";
import { join } from "node:path";
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

/**
 * Sends one input on `link` (mind.mjs), for the device `name`. It answers the event's payload, and
 * throws the reason when the input did not go. With no connection in `silentMs` it fails with the
 * reason the connection did not come; then a mind that does not answer is given up after
 * `silentMs` with no sign of life. A piece of a file that went is such a sign, so a long upload is
 * not cut.
 */
export async function sendInput({ input, name, link, say = () => {}, silentMs = 60_000 }) {
  if (!/^[\w.-]+$/.test(String(input.id))) throw new Error("the input has no usable id");
  const files = (input.files ?? []).map((file, index) => ({
    ...file,
    contentType: file.contentType || "application/octet-stream",
    path: `/devices/${name}/inputs/${input.id}/${mindFileName(index, file.name)}`,
    bytes: statSync(file.local).size,
  }));
  const total = files.reduce((sum, file) => sum + file.bytes, 0);
  const { itx, device } = await link.now(silentMs);
  let timer;
  let giveUp;
  const silent = new Promise((_, reject) => (giveUp = reject));
  const alive = () => {
    clearTimeout(timer);
    timer = setTimeout(() => giveUp(new Error(`no answer from the mind in ${silentMs / 1000} s`)), silentMs);
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
        putFile({ r2: itx.r2, key: file.path.slice(1), path: file.local, contentType: file.contentType, said: progressed }).catch(
          (error) => {
            throw new Error(`${file.name} did not go up: ${String(error?.message ?? error)}`);
          },
        ),
      ),
    );
    const payload = {
      id: input.id,
      text: String(input.text ?? ""),
      at: input.at,
      files: files.map(({ path, name, contentType, bytes }) => ({ path, name, contentType, bytes })),
    };
    try {
      await device.append({ type: INPUT_SUBMITTED, payload, idempotencyKey: `${INPUT_SUBMITTED}/${input.id}` });
    } catch (error) {
      // the mind has this input's event already: an earlier send whose answer was lost
      if (error?.code !== "IDEMPOTENCY_CONFLICT") throw error;
    }
    return payload;
  };
  alive();
  try {
    return await Promise.race([send(), silent]);
  } finally {
    clearTimeout(timer);
  }
}

/** The line `{ input, folder }` of the app: the input of `<folder>/input.json`, then `done` or `failed`. */
export async function inputJob({ line, name, link, say }) {
  try {
    const input = JSON.parse(readFileSync(join(line.folder, "input.json"), "utf8"));
    await sendInput({ input, name, link, say });
    say({ done: true });
  } catch (error) {
    say({ failed: String(error?.message ?? error).slice(0, 300) });
  }
}
