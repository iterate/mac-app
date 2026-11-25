// pages.mjs: this Mac's pages, served through the lend as `itx.<name>.http(request)` (README,
// "This Mac's pages"). It imports nothing but Node.
//
//   http({ method, path, query, headers }) → { status, headers, body }
//
// `body` is a string, bytes, or a ReadableStream of bytes (capnweb carries it across the
// connection). The routes:
//
//   /             pages/index.html: the page, with no build step
//   /state.json   what the app knows: this Mac's name, the lend, the record, the newest acts
//   /live.mjpeg   multipart/x-mixed-replace of JPEG frames of a display (`?display=0`, the main one)
//
// Every route is a use of the thing Pages under the owner's choice (Off, Ask, Shared); the live
// view is a use of the display too. The app decides both (PagePowers.swift); this file asks it on
// its socket and turns its refusal into a status with the app's words.
//
// The live view's bounds: at most MOST_STREAMS at once; each ends after STREAM_MS; at most
// FRAMES_PER_SECOND frames, each at most MAX_WIDTH pixels wide. A frame is made only when the
// reader has taken the one before (a pull with no queue), so a slow reader makes the frames
// between its reads drop, and no more than one frame is ever held. A cancel of the stream (the
// reader went away) ends the view in the app at once.
import { readFile } from "node:fs/promises";
import { extname, join, normalize } from "node:path";

export const MOST_STREAMS = 2;
export const STREAM_MS = 10 * 60 * 1000;
export const FRAMES_PER_SECOND = 4;
export const MAX_WIDTH = 1280;
export const BOUNDARY = "frame";

const TYPES = {
  ".html": "text/html; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".svg": "image/svg+xml",
  ".png": "image/png",
};

/** The words the app refuses with when it does not run (mac-endpoint.ts). */
const NOT_RUNNING = /not running on this Mac/;

const text = (status, words) => ({
  status,
  headers: { "content-type": "text/plain; charset=utf-8", "cache-control": "no-store" },
  body: `${words}\n`,
});

/** A refusal of the app as a status: 503 when the app does not answer, else 403. */
function refused(error) {
  const words = error instanceof Error ? error.message : String(error);
  return text(NOT_RUNNING.test(words) ? 503 : 403, words);
}

/**
 * The pages, on `ask` (one question to the app: `(method, parameters) => Promise<answer>`).
 * `folder` holds the files; `now` and `sleep` are the clock, for the tests.
 */
export function pages({
  ask,
  folder = join(import.meta.dirname, "..", "pages"),
  now = () => Date.now(),
  sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
} = {}) {
  /** The live views this bridge serves now. */
  const streams = new Set();

  async function file(name) {
    const path = normalize(join(folder, name));
    if (!path.startsWith(folder)) return text(404, "No such page.");
    try {
      const body = await readFile(path);
      return {
        status: 200,
        headers: { "content-type": TYPES[extname(path)] ?? "application/octet-stream", "cache-control": "no-store" },
        body: new Uint8Array(body),
      };
    } catch {
      return text(404, "No such page.");
    }
  }

  /** One multipart part: its head, the JPEG, and the line end before the next boundary. */
  function part(jpeg) {
    const head = `--${BOUNDARY}\r\nContent-Type: image/jpeg\r\nContent-Length: ${jpeg.length}\r\n\r\n`;
    const bytes = new Uint8Array(head.length + jpeg.length + 2);
    bytes.set(new TextEncoder().encode(head), 0);
    bytes.set(jpeg, head.length);
    bytes.set([13, 10], head.length + jpeg.length);
    return bytes;
  }

  async function live(query) {
    if (streams.size >= MOST_STREAMS)
      return text(429, `At most ${MOST_STREAMS} live views of this Mac run at once: close one first.`);
    const display = query.display === undefined ? 0 : Number(query.display);
    if (!Number.isInteger(display) || display < 0) return text(400, "display is a number of state.json's displays, from 0.");
    const view = { stopped: false };
    streams.add(view);
    let started;
    try {
      started = await ask("pages.live.start", { display, maxWidth: MAX_WIDTH });
    } catch (error) {
      streams.delete(view);
      return refused(error);
    }
    const deadline = now() + STREAM_MS;
    const gap = 1000 / FRAMES_PER_SECOND;
    let last = 0;
    const stop = (why) => {
      if (view.stopped) return;
      view.stopped = true;
      streams.delete(view);
      ask("pages.live.stop", { stream: started.stream, why }).catch(() => {});
    };
    const body = new ReadableStream(
      {
        // called only while a read waits: no frame is made ahead of the reader
        async pull(controller) {
          if (view.stopped) return;
          if (now() >= deadline) {
            stop(`it ran for ${STREAM_MS / 60000} minutes`);
            controller.enqueue(new TextEncoder().encode(`--${BOUNDARY}--\r\n`));
            return controller.close();
          }
          const wait = last + gap - now();
          if (wait > 0) await sleep(wait);
          if (view.stopped) return;
          let frame;
          try {
            frame = await ask("pages.live.frame", { stream: started.stream });
          } catch (error) {
            // the app ended the view (a choice turned Off, its time, another mind): the end
            stop(error instanceof Error ? error.message : String(error));
            controller.enqueue(new TextEncoder().encode(`--${BOUNDARY}--\r\n`));
            return controller.close();
          }
          last = now();
          // a cancel while the frame was made: the frame goes nowhere
          if (view.stopped) return;
          controller.enqueue(part(new Uint8Array(Buffer.from(String(frame.jpegBase64 || ""), "base64"))));
        },
        cancel() {
          stop("the reader went away");
        },
      },
      { highWaterMark: 0 },
    );
    return {
      status: 200,
      headers: {
        "content-type": `multipart/x-mixed-replace; boundary=${BOUNDARY}`,
        "cache-control": "no-store",
        "x-iterate-live-seconds": String(STREAM_MS / 1000),
      },
      body,
    };
  }

  /** The lent function. */
  async function http(request = {}) {
    const method = String(request.method ?? "GET").toUpperCase();
    if (method !== "GET") {
      const answer = text(405, "This Mac's pages answer GET alone.");
      return { ...answer, headers: { ...answer.headers, allow: "GET" } };
    }
    const path = String(request.path ?? "/");
    const query = request.query && typeof request.query === "object" ? request.query : {};
    if (path === "/live.mjpeg") return live(query);
    if (path !== "/" && path !== "/index.html" && path !== "/state.json")
      return text(404, "No such page. This Mac has /, /state.json and /live.mjpeg.");
    // the page is a use too: Off refuses it with the owner's words
    let state;
    try {
      state = await ask("pages.state");
    } catch (error) {
      return refused(error);
    }
    if (path !== "/state.json") return file("index.html");
    return {
      status: 200,
      headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" },
      body: JSON.stringify(state),
    };
  }

  return { http, streams };
}
