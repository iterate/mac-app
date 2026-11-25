// upload.mjs: one file of this Mac into the mind's files. The record, a capture and an input all
// upload through `putFile`, by the same rules:
//
// 1. A signed PUT (`itx.r2.presign`) that streams the file from disk: no byte of it passes through
//    the connection or a Durable Object. The mind answers `{ size }`, the bytes it stored; another
//    size is a failure.
// 2. When the signed route answers 5xx (seen 22 Nov 2026 from 11:35 UTC: every signed PUT got
//    "error code: 1101" after a platform change to request bodies), a file of at most
//    `MOST_THROUGH_CONNECTION` goes through the connection instead (`itx.r2.put`, as bytes: slower,
//    and it holds the file in memory once on each side), and its stored size is checked too.
//    Larger files fail, and wait for the route.
import { createReadStream, readFileSync, statSync } from "node:fs";
import { request as httpRequest } from "node:http";
import { request as httpsRequest } from "node:https";
import { pipeline } from "node:stream/promises";

/** The largest file that may go through the connection: below the 12 MB `r2.put` that the mind
 *  once refused, printing its bytes into the error, which reset a Durable Object's isolate (21 Nov
 *  2026). A record slot's files measured 0.03 to 2 MB. */
export const MOST_THROUGH_CONNECTION = 8 * 1024 * 1024;

/** A PUT that has had no byte go or come for this long is given up. */
const IDLE_MS = 110_000;

/** One file to its signed link, streamed from disk. `said(bytes)` hears each piece that went. The
 *  file closes however the PUT ends; `signal` ends both. */
function putBySignedLink(url, path, contentType, size, said, signal) {
  return new Promise((resolve, reject) => {
    const sending = (url.startsWith("https:") ? httpsRequest : httpRequest)(
      url,
      { method: "PUT", headers: { "content-type": contentType, "content-length": size }, signal },
      (answer) => {
        let text = "";
        answer.setEncoding("utf8").on("data", (chunk) => (text += chunk));
        answer.on("error", reject);
        answer.on("end", () => {
          if (answer.statusCode >= 300)
            return reject(Object.assign(new Error(`HTTP ${answer.statusCode} ${text.slice(0, 200)}`), { status: answer.statusCode }));
          let stored;
          try {
            stored = JSON.parse(text).size;
          } catch {}
          if (stored !== size) return reject(new Error(`the mind has ${stored ?? "no"} bytes, not ${size}`));
          resolve();
        });
      },
    );
    sending.on("error", reject);
    sending.setTimeout(IDLE_MS, () => sending.destroy(new Error(`the PUT stalled for ${IDLE_MS / 1000} s`)));
    // `pipeline` closes the file when the request fails or ends early, and ends the request when
    // the file fails
    const file = createReadStream(path).on("data", (chunk) => said(chunk.length));
    pipeline(file, sending).catch(reject);
  });
}

/**
 * Puts the file at `path` on this Mac into the mind's files as `key` (no leading slash). `r2` is
 * `itx.r2` of the connection; `url` is a signed link asked for before (else it is asked for here).
 * `fellBack()` is told when the file goes through the connection. `said(bytes)` hears the bytes
 * that went, `size` of them in all however it went. `signal` gives the PUT up. Throws the reason;
 * a reason of the signed PUT has `put: true`: it went beside the connection, which it says nothing of.
 */
export async function putFile({ r2, key, path, contentType, url, said = () => {}, fellBack = () => {}, signal }) {
  const size = statSync(path).size;
  const link = url ?? (await r2.presign({ key, method: "PUT", expiresInSeconds: 600 })).url;
  signal?.throwIfAborted();
  let streamed = 0;
  try {
    await putBySignedLink(link, path, contentType, size, (bytes) => ((streamed += bytes), said(bytes)), signal);
  } catch (error) {
    // a PUT's failure (a reset, a stalled socket) is not the connection's: `put` says so
    if (signal?.aborted || !(error?.status >= 500) || size > MOST_THROUGH_CONNECTION) throw Object.assign(error, { put: true });
    fellBack();
    const stored = await r2.put(key, readFileSync(path), { httpMetadata: { contentType } });
    if (stored?.size !== size) throw new Error(`the mind has ${stored?.size ?? "no"} bytes, not ${size}`);
    // the bytes the failed PUT streamed were told already
    said(Math.max(0, size - streamed));
  }
}
