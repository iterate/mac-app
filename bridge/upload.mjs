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

/** The largest file that may go through the connection: below the 12 MB `r2.put` that the mind
 *  once refused, printing its bytes into the error, which reset a Durable Object's isolate (21 Nov
 *  2026). A record slot's files measured 0.03 to 2 MB. */
export const MOST_THROUGH_CONNECTION = 8 * 1024 * 1024;

/** A PUT that has had no byte go or come for this long is given up. */
const IDLE_MS = 110_000;

/** One file to its signed link, streamed from disk. `said(bytes)` hears each piece that went. */
function putBySignedLink(url, path, contentType, size, said) {
  return new Promise((resolve, reject) => {
    const sending = (url.startsWith("https:") ? httpsRequest : httpRequest)(
      url,
      { method: "PUT", headers: { "content-type": contentType, "content-length": size } },
      (answer) => {
        let text = "";
        answer.setEncoding("utf8").on("data", (chunk) => (text += chunk));
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
    sending.setTimeout(IDLE_MS, () => sending.destroy(new Error("the upload timed out")));
    createReadStream(path)
      .on("error", reject)
      .on("data", (chunk) => said(chunk.length))
      .pipe(sending);
  });
}

/**
 * Puts the file at `path` on this Mac into the mind's files as `key` (no leading slash). `r2` is
 * `itx.r2` of the connection; `url` is a signed link asked for before (else it is asked for here).
 * `fellBack()` is told when the file goes through the connection. Throws the reason.
 */
export async function putFile({ r2, key, path, contentType, url, said = () => {}, fellBack = () => {} }) {
  const size = statSync(path).size;
  const link = url ?? (await r2.presign({ key, method: "PUT", expiresInSeconds: 600 })).url;
  try {
    await putBySignedLink(link, path, contentType, size, said);
  } catch (error) {
    if (!(error?.status >= 500) || size > MOST_THROUGH_CONNECTION) throw error;
    fellBack();
    const stored = await r2.put(key, readFileSync(path), { httpMetadata: { contentType } });
    if (stored?.size !== size) throw new Error(`the mind has ${stored?.size ?? "no"} bytes, not ${size}`);
    said(size);
  }
}
