#!/usr/bin/env node
// input-send.mjs: one input of the person (Sources/VoiceMeetMac/MindInput.swift: ⌥⇧Space, a text
// and files) into a mind.
//
//   node input-send.mjs <folder> --name <name> --iterate <iterate.js> --mind <address>
//
// `<folder>/input.json` is the input: { id, text, at, files: [{ local, name, contentType }] },
// where `local` is a file's path on this Mac. It connects to the mind as the person (the iterate
// CLI's own sign-in: `iterate login <mind>`; the Mac's key lends and does nothing else). Each file
// goes into the mind's files as /devices/<name>/inputs/<id>/<n>-<name>, by a signed PUT that
// streams it from disk. Then ONE event is appended to the context /devices/<name>:
//
//   device/input-submitted { id, text, at, files: [{ path, name, contentType, bytes }] }
//
// with the idempotency key `device/input-submitted/<id>`: a second send of the same input (the
// answer of the first one was lost) adds no second event. That event is the whole contract: this
// script and the app know no agent and no backend. What a mind does with an input is its config.
//
// stdout is JSON lines for the app: { progress } (0 to 1, of the bytes), then { done: true } or
// { failed } (the reason, in words for the person). It exits 0 after `done`, 1 after `failed`.
import { createReadStream, readFileSync, realpathSync, statSync } from "node:fs";
import { request as httpRequest } from "node:http";
import { request as httpsRequest } from "node:https";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { parseArgs } from "node:util";

export const INPUT_SUBMITTED = "device/input-submitted";

/** The largest file that may go through the connection when the signed route fails
 *  (record-upload.mjs has the reason for the bound). */
const MOST_THROUGH_CONNECTION = 8 * 1024 * 1024;

/** A file's name in the mind: its own name with no slash, no control character and no leading dot,
 *  after its number, so that two files of one name both stay. */
export function mindFileName(index, name) {
  const safe = String(name)
    .replace(/[\u0000-\u001f\u007f/\\]/g, "_")
    .replace(/^\.+/, "")
    .slice(-120);
  return `${index + 1}-${safe || "file"}`;
}

/** One file to its signed link, streamed from disk. `said(bytes)` hears each piece that went. */
function putBySignedLink(url, path, contentType, size, said) {
  return new Promise((resolve, reject) => {
    const sending = (url.startsWith("https:") ? httpsRequest : httpRequest)(
      url,
      { method: "PUT", headers: { "content-type": contentType, "content-length": size } },
      (answer) => {
        let text = "";
        answer.setEncoding("utf8").on("data", (chunk) => (text += chunk));
        answer.on("end", () =>
          answer.statusCode < 300
            ? resolve()
            : reject(new Error(`HTTP ${answer.statusCode} ${text.slice(0, 200)}`)),
        );
      },
    );
    sending.on("error", reject);
    sending.setTimeout(300_000, () => sending.destroy(new Error("the upload timed out")));
    createReadStream(path)
      .on("error", reject)
      .on("data", (chunk) => said(chunk.length))
      .pipe(sending);
  });
}

/**
 * Sends one input. `connect()` answers `{ itx }`; `put` is the signed PUT (a test gives its own).
 * It answers the event's payload, and throws the reason when the input did not go.
 */
export async function sendInput({ input, name, connect, say = () => {}, put = putBySignedLink }) {
  if (!/^[\w.-]+$/.test(String(input.id))) throw new Error("the input has no usable id");
  const files = (input.files ?? []).map((file, index) => ({
    ...file,
    path: `/devices/${name}/inputs/${input.id}/${mindFileName(index, file.name)}`,
    bytes: statSync(file.local).size,
  }));
  const total = files.reduce((sum, file) => sum + file.bytes, 0);
  const { itx } = await connect();
  let sent = 0;
  let saidAt = 0;
  const progressed = (bytes) => {
    sent += bytes;
    if (Date.now() - saidAt < 100) return;
    saidAt = Date.now();
    say({ progress: total ? Math.min(sent / total, 1) : 1 });
  };
  await Promise.all(
    files.map(async (file) => {
      const contentType = file.contentType || "application/octet-stream";
      const key = file.path.slice(1);
      try {
        const link = await itx.r2.presign({ key, method: "PUT", expiresInSeconds: 3600 });
        await put(link.url, file.local, contentType, file.bytes, progressed).catch((error) => {
          // the mind's signed route answers 5xx: a small file goes through the connection instead
          if (!/HTTP 5\d\d/.test(String(error?.message)) || file.bytes > MOST_THROUGH_CONNECTION)
            throw error;
          return itx.r2
            .put(key, readFileSync(file.local), { httpMetadata: { contentType } })
            .then(() => progressed(file.bytes));
        });
      } catch (error) {
        throw new Error(`${file.name} did not go up: ${String(error?.message ?? error)}`);
      }
    }),
  );
  const payload = {
    id: input.id,
    text: String(input.text ?? ""),
    at: input.at,
    files: files.map(({ path, name, contentType, bytes }) => ({
      path,
      name,
      contentType: contentType || "application/octet-stream",
      bytes,
    })),
  };
  try {
    await itx.cd(`/devices/${name}`).append({
      type: INPUT_SUBMITTED,
      payload,
      idempotencyKey: `${INPUT_SUBMITTED}/${input.id}`,
    });
  } catch (error) {
    // the mind has this input's event already: an earlier send whose answer was lost
    if (error?.code !== "IDEMPOTENCY_CONFLICT") throw error;
  }
  return payload;
}

if (process.argv[1] && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const say = (line) => process.stdout.write(`${JSON.stringify(line)}\n`);
  try {
    const { positionals, values } = parseArgs({
      allowPositionals: true,
      options: {
        name: { type: "string" },
        iterate: { type: "string" },
        mind: { type: "string" },
      },
    });
    const folder = positionals[0];
    if (!folder || !values.name || !values.iterate || !values.mind)
      throw new Error(
        "node input-send.mjs <folder> --name <name> --iterate <iterate.js> --mind <address>",
      );
    const { addressOf, connectMind } = await import(
      pathToFileURL(join(dirname(dirname(values.iterate)), "dist/node.mjs")).href
    );
    // A mind that does not answer is given up after 60 s with no sign of life. A piece of a file
    // that went is such a sign, so a long upload is not cut.
    let timer;
    let giveUp;
    const silent = new Promise((_, reject) => (giveUp = reject));
    const alive = () => {
      clearTimeout(timer);
      timer = setTimeout(() => giveUp(new Error("no answer from the mind in 60 s")), 60_000);
    };
    alive();
    const sending = sendInput({
      input: JSON.parse(readFileSync(join(folder, "input.json"), "utf8")),
      name: values.name,
      connect: () => connectMind({ address: addressOf(values.mind), signIn: false }),
      say: (line) => (alive(), say(line)),
    });
    await Promise.race([sending, silent]);
    clearTimeout(timer);
    say({ done: true });
    process.exit(0);
  } catch (error) {
    say({ failed: String(error?.message ?? error).slice(0, 300) });
    process.exit(1);
  }
}
