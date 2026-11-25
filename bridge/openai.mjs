// openai.mjs: the job `openai` of mind.mjs: sockets of OpenAI's realtime transcription opened
// THROUGH the mind, with the mind's own OpenAI key (Sources/VoiceMeetMac/MindSockets.swift,
// README "Dictation").
//
// The mind keeps its key at /secrets/openai and never hands it out. This job opens the socket with
// `itx.fetch` and the header `Upgrade: websocket`, with the placeholder
// `Authorization: Bearer getSecret("/secrets/openai")`: the vault puts the key in on the way to
// api.openai.com, and the mind hands the upstream socket back (iterate/private #1394). The job
// relays its text frames both ways over the bridge's JSON lines. OpenAI's frames are JSON text
// (the sound is base64 inside `input_audio_buffer.append`), so only text is relayed.
//
// The app's lines, each with `socket: <id>`:
//   { open: true }               open one; a frame sent before it is open waits for it
//   { frame: "<text>" }          one text frame to OpenAI
//   { ping: <n> }                `pong: <n>` when the socket is open
//   { close: true, code?, reason? }  close it; nothing more is said of it
// The job's lines, each with `socket: <id>`:
//   { opened: true } · { frame: "<text>" } · { pong: <n> }
//   { closed: true, code, reason }   OpenAI or the mind closed it
//   { failed, refused? }             it did not open, or it broke (an error, the link's drop)
// `refused: true` is the mind's or OpenAI's own no (no /secrets/openai, a key OpenAI does not
// take): the app then knows this mind cannot open one, until its next connection. A failure with
// no `refused` (no connection, no answer within `withinMs`, an error of OpenAI's servers) may
// pass. A drop of the link's connection fails every socket opened on it. Frames are never logged,
// and a failure's words have any key or token in them cut out.

export const REALTIME = "https://api.openai.com/v1/realtime?intent=transcription";
export const SECRET = "/secrets/openai";

/** The request that opens one socket; the vault fills the key in. */
export const upgradeRequest = () =>
  new Request(REALTIME, {
    headers: { Upgrade: "websocket", Connection: "Upgrade", Authorization: `Bearer getSecret("${SECRET}")` },
  });

/** A text with every key and token cut out: `sk-…`, `ek_…`, a Bearer value. */
export const redacted = (text) =>
  String(text)
    .replace(/\b(sk|ek|rk)[-_][A-Za-z0-9_-]{4,}/g, "$1…")
    .replace(/Bearer\s+[^\s"',}]+/gi, "Bearer …")
    .slice(0, 300);

/** A failure that is the mind's or OpenAI's no, not a broken way to it. */
class Refused extends Error {}

const OPEN = 1;
const decoder = new TextDecoder();

/** A frame's text: a string as it is, bytes as UTF-8; anything else (a Blob) is not relayed. */
const textOf = (data) => {
  if (typeof data === "string") return data;
  if (data instanceof ArrayBuffer) return decoder.decode(data);
  if (ArrayBuffer.isView(data)) return decoder.decode(data);
  return undefined;
};

/** Within `ms`, or the failure `words`. */
function within(promise, ms, words) {
  let timer;
  return Promise.race([
    promise,
    new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error(words)), ms);
    }),
  ]).finally(() => clearTimeout(timer));
}

/** One upstream socket through `connection.itx.fetch`, or a failure (`Refused` for a no). */
export async function openUpstream(connection) {
  let answer;
  try {
    answer = await connection.itx.fetch(upgradeRequest());
  } catch (error) {
    // the vault refuses before OpenAI hears anything: "itx.fetch: no stored mind secret for …"
    const text = String(error?.message ?? error);
    if (/secret|refus|forbidden|not allowed|permission/i.test(text)) throw new Refused(text);
    throw error;
  }
  // capnweb gives the 101 as a status-200 Response that holds the socket: test the socket
  if (answer.webSocket) return answer.webSocket;
  const text = await answer.text().catch(() => "");
  let reason = text || "no socket";
  try {
    reason = JSON.parse(text)?.error?.message || reason;
  } catch {}
  const words = `OpenAI answered ${answer.status}: ${reason}`;
  // 4xx is a no (the key, the credit, the request); 429, 5xx and an answer with no socket may pass
  if (answer.status >= 400 && answer.status < 500 && answer.status !== 429) throw new Refused(words);
  throw new Error(words);
}

/** The sockets of one bridge: `take(line)` takes a line of the app; `end()` closes them all. */
export function openaiSockets({ link, say, withinMs = 5_000 }) {
  /** By id: `{ socket?, waiting: [frames], connection? }`; an entry leaves at its end. */
  const sockets = new Map();

  /** The socket's end, once: it leaves the map, and the app hears `line` unless it closed it. */
  const end = (id, entry, line) => {
    if (sockets.get(id) !== entry) return false;
    sockets.delete(id);
    if (line) say({ socket: id, ...line });
    return true;
  };

  async function open(id, entry) {
    let socket;
    try {
      const connection = await link.now(withinMs);
      const upstream = openUpstream(connection);
      socket = await within(upstream, withinMs, `no socket from the mind in ${withinMs / 1000} s`).catch((error) => {
        // one that comes after the bound is closed when it comes
        upstream.then((late) => (late.accept?.(), close(late, 1000, "came too late")), () => {});
        throw error;
      });
      // the app closed it while it opened
      if (sockets.get(id) !== entry) {
        socket.accept?.();
        return socket.close(1000, "closed while it opened");
      }
      entry.socket = socket;
      entry.connection = connection;
      socket.addEventListener("message", (event) => {
        if (sockets.get(id) !== entry) return;
        const text = textOf(event.data);
        if (text !== undefined) say({ socket: id, frame: text });
      });
      socket.addEventListener("close", (event) => {
        end(id, entry, { closed: true, code: event.code ?? 1005, reason: redacted(event.reason ?? "") });
      });
      socket.addEventListener("error", (event) => {
        if (end(id, entry, { failed: redacted(`the socket failed: ${event?.message ?? event?.error?.message ?? "an error"}`) })) close(socket, 1011);
      });
      // a drop of the link's connection ends every socket on it
      connection.closed?.then?.(() => {
        if (end(id, entry, { failed: "the connection to the mind ended" })) close(socket, 1001);
      });
      say({ socket: id, opened: true });
      socket.accept?.();
      for (const frame of entry.waiting.splice(0)) socket.send(frame);
    } catch (error) {
      if (socket) close(socket, 1011);
      end(id, entry, { failed: redacted(error?.message ?? error), ...(error instanceof Refused ? { refused: true } : {}) });
    }
  }

  const close = (socket, code, reason = "") => {
    try {
      socket.close(code, reason);
    } catch {}
  };

  return {
    /** One line of the app; a promise while a socket opens. */
    take(line) {
      const id = String(line.socket);
      const entry = sockets.get(id);
      if (line.open) {
        if (entry) return say({ socket: id, failed: `socket ${id} is open already` });
        const made = { waiting: [] };
        sockets.set(id, made);
        return open(id, made);
      }
      // a line of a socket that ended (a frame on its way as it closed) is nothing
      if (!entry) return;
      if (typeof line.frame === "string") {
        if (entry.socket) entry.socket.send(line.frame);
        else entry.waiting.push(line.frame);
      } else if (line.ping !== undefined) {
        // one that still opens is not pinged: the app pings only an open one
        if (entry.socket && (entry.socket.readyState ?? OPEN) === OPEN) say({ socket: id, pong: line.ping });
      } else if (line.close) {
        sockets.delete(id);
        if (entry.socket) close(entry.socket, Number(line.code) || 1000, String(line.reason ?? ""));
      }
    },
    /** How many sockets are open or opening. */
    get size() {
      return sockets.size;
    },
    /** Every socket closes; the app hears each fail. */
    end() {
      for (const [id, entry] of [...sockets]) {
        end(id, entry, { failed: "the mind's process ends" });
        if (entry.socket) close(entry.socket, 1001, "the bridge ends");
      }
    },
  };
}
