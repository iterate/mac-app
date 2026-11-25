// A fake mind for the bridges' tests: connections that end as the mind ends them (1008), that
// fail to connect, subscriptions that end with no word, appends that fail or whose answer is lost
// (`dropNextAnswer`), idempotency keys (the same event once; another one with the key is
// IDEMPOTENCY_CONFLICT). Each appended event gets
// an offset and a time; `readEvents` reads the kept ones of a path, a page at a time, and each
// read is in `reads` as `{ after, events }`. A subscription to "*" gets every kept event, as the
// mind's does (no ephemeral one).
//
// Its files: `itx.r2.presign` answers a link to a server of its own on 127.0.0.1 (started at the
// first link), whose PUT stores the bytes and answers `{ size }`, or the status `failSignedPuts`;
// `itx.r2.put` stores bytes through the connection. Each file is in `files` by its key, as
// `{ bytes, contentType, via }`, and `stored(key, file)` hears it. `order` has "file <key>" and
// "event <type>" in the order they came. Its config repo is `repo`: `{ tip, files, reads }`.
// `itx.fetch` goes to `mind.fetch(request)` (by default the vault's no: no stored secret).
// `mind.facets[name](path, connection)` answers a facet of a context, when a test sets one.
import { createServer } from "node:http";

export const SIGN_IN_ENDED = "1008 the sign-in for this session ended: authenticate again";

export function fakeMind({ stored = () => {} } = {}) {
  let server;
  const mind = {
    files: new Map(),
    failSignedPuts: undefined,
    order: [],
    repo: { tip: async () => "abc", files: {}, reads: [] },
    connections: [],
    subscriptions: [],
    appended: [],
    refuseConnects: 0,
    failNextAppend: undefined,
    waits: [],
    clock: 0,
    offset: 0,
    reads: [],
    fetched: [],
    fetch: async () => Promise.reject(new Error("itx.fetch: no stored mind secret for getSecret(\"/secrets/openai\") in the header authorization")),
  };
  mind.sleep = (ms) => {
    mind.waits.push(ms);
    return new Promise((resolve) => setImmediate(resolve));
  };
  mind.now = () => mind.clock;
  const store = (key, bytes, contentType, via) => {
    const file = { bytes, contentType, via };
    mind.files.set(key, file);
    mind.order.push(`file ${key}`);
    stored(key, file);
  };
  /** The signed links' server: a PUT of /<key> stores its body. */
  const serve = () =>
    (server ??= new Promise((resolve) => {
      const http = createServer((request, answer) => {
        const chunks = [];
        request.on("data", (chunk) => chunks.push(chunk));
        request.on("end", () => {
          if (mind.failSignedPuts) return answer.writeHead(mind.failSignedPuts, { connection: "close" }).end("error code: 1101");
          const bytes = Buffer.concat(chunks);
          store(decodeURIComponent(request.url.slice(1)), bytes, request.headers["content-type"], "signed");
          answer.writeHead(200, { "content-type": "application/json", connection: "close" }).end(JSON.stringify({ size: bytes.length }));
        });
      });
      http.unref();
      http.listen(0, "127.0.0.1", () => resolve(`http://127.0.0.1:${http.address().port}`));
    }));
  mind.deliver = (events, from) => {
    for (const s of mind.subscriptions)
      if (s.alive && s.connection.isOpen && (!from || s.connection === from))
        s.target(events.filter((event) => s.consumes.includes(event.type) || (s.consumes.includes("*") && !event.ephemeral)));
  };
  mind.connect = async () => {
    if (mind.refuseConnects > 0) {
      mind.refuseConnects--;
      throw new Error("connect ECONNREFUSED");
    }
    let close;
    const connection = {
      isOpen: true,
      closed: new Promise((resolve) => (close = resolve)),
      /** The mind ends the session: the socket closes with 1008. */
      end() {
        connection.isOpen = false;
        close({ code: 1008, reason: SIGN_IN_ENDED.slice(5) });
      },
      [Symbol.dispose]() {
        connection.isOpen = false;
        close({ code: 3000, reason: "disposed" });
      },
    };
    const open = () => {
      if (!connection.isOpen) throw new Error(`Peer closed WebSocket: ${SIGN_IN_ENDED}`);
    };
    connection.itx = {
      r2: {
        async presign({ key }) {
          open();
          return { url: `${await serve()}/${encodeURIComponent(key)}` };
        },
        async put(key, bytes, options) {
          open();
          store(key, Buffer.from(bytes), options?.httpMetadata?.contentType, "connection");
          return { size: bytes.length };
        },
        async head(key) {
          open();
          return mind.files.has(key) ? { size: mind.files.get(key).bytes.length } : null;
        },
        async delete(keys) {
          open();
          for (const key of keys) mind.files.delete(key);
        },
      },
      repos: {
        get: (path) => ({
          tip: async () => (open(), mind.repo.reads.push(path), mind.repo.tip()),
          async readFile(file, options) {
            mind.repo.reads.push([file, options?.commitOid]);
            if (!(file in mind.repo.files)) throw new Error("no such file");
            return mind.repo.files[file];
          },
        }),
      },
      ai: { run: async () => Promise.reject(new Error("no model in the fake mind")) },
      /** `itx.fetch`: `mind.fetch(request)` answers it; each request is in `fetched`. */
      async fetch(request) {
        open();
        mind.fetched.push(request);
        return mind.fetch(request);
      },
      cd: (path) => ({
        path,
        async append(...events) {
          if (!connection.isOpen) throw new Error(`Peer closed WebSocket: ${SIGN_IN_ENDED}`);
          if (mind.failNextAppend) {
            const error = mind.failNextAppend;
            mind.failNextAppend = undefined;
            throw error;
          }
          // an idempotency key that the path has: the same event is the one kept, another one a conflict
          for (const event of events) {
            const kept = event.idempotencyKey && mind.appended.find((e) => e.path === path && e.idempotencyKey === event.idempotencyKey);
            if (kept && JSON.stringify(kept.payload) !== JSON.stringify(event.payload))
              throw Object.assign(new Error(`another event has the key ${event.idempotencyKey}`), { code: "IDEMPOTENCY_CONFLICT" });
          }
          events = events.filter((event) => !event.idempotencyKey || !mind.appended.some((e) => e.path === path && e.idempotencyKey === event.idempotencyKey));
          const stored = events.map((event) => ({
            ...event,
            path,
            offset: ++mind.offset,
            createdAt: new Date(Date.UTC(2026, 10, 24, 14) + mind.offset * 1000).toISOString(),
          }));
          mind.appended.push(...stored);
          for (const event of stored) mind.order.push(`event ${event.type}`);
          mind.deliver(stored, connection);
          // the mind keeps the events, and its answer is lost on the way
          if (mind.dropNextAnswer) {
            mind.dropNextAnswer = false;
            throw new Error("Peer closed WebSocket: the answer was lost");
          }
          return stored;
        },
        async readEvents(afterOffset = 0, limit = 1000) {
          const kept = mind.appended.filter((e) => e.path === path && !e.ephemeral && e.offset > afterOffset);
          const events = kept.slice(0, limit);
          mind.reads.push({ after: afterOffset, events: events.length });
          return { events, scannedThroughOffset: events.at(-1)?.offset ?? mind.offset, atHead: events.length === kept.length };
        },
        async subscribe({ name, consumes, target }) {
          const subscription = { name, consumes, target, connection, alive: true };
          mind.subscriptions.push(subscription);
          return { [Symbol.dispose]: () => (subscription.alive = false) };
        },
        facets: {
          // `mind.facets[name]`, when a test gives one (a call's `join`, `signal`, `leave`), called with
          // the path and the connection; else the record's ICE servers
          get: (name) =>
            mind.facets?.[name]?.(path, connection) ?? { iceServers: async () => ({ iceServers: [{ urls: "stun:test" }], ttlSeconds: 3600 }) },
        },
      }),
    };
    mind.connections.push(connection);
    return connection;
  };
  return mind;
}

/** Waits, a turn of the event loop at a time, until `check()` is true. */
export async function until(check, turns = 500) {
  for (let i = 0; i < turns; i++) {
    if (check()) return;
    await new Promise((resolve) => setImmediate(resolve));
  }
  throw new Error(`never true: ${check}`);
}

/** Waits, 10 ms at a time, until `check()` is true; throws after `ms`. */
export async function eventually(check, ms = 5000) {
  for (const deadline = Date.now() + ms; Date.now() < deadline; ) {
    if (check()) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error(`never true: ${check}`);
}
