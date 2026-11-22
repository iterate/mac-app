// A fake mind for the bridges' tests: connections that end as the mind ends them (1008), that
// fail to connect, subscriptions that end with no word, appends that fail.
export const SIGN_IN_ENDED = "1008 the sign-in for this session ended: authenticate again";

export function fakeMind() {
  const mind = {
    connections: [],
    subscriptions: [],
    appended: [],
    refuseConnects: 0,
    failNextAppend: undefined,
    waits: [],
    clock: 0,
  };
  mind.sleep = (ms) => {
    mind.waits.push(ms);
    return new Promise((resolve) => setImmediate(resolve));
  };
  mind.now = () => mind.clock;
  mind.deliver = (events, from) => {
    for (const s of mind.subscriptions)
      if (s.alive && s.connection.isOpen && (!from || s.connection === from))
        s.target(events.filter((event) => s.consumes.includes(event.type)));
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
    connection.itx = {
      cd: (path) => ({
        path,
        async append(...events) {
          if (!connection.isOpen) throw new Error(`Peer closed WebSocket: ${SIGN_IN_ENDED}`);
          if (mind.failNextAppend) {
            const error = mind.failNextAppend;
            mind.failNextAppend = undefined;
            throw error;
          }
          mind.appended.push(...events);
          mind.deliver(events, connection);
          return events;
        },
        async subscribe({ name, consumes, target }) {
          const subscription = { name, consumes, target, connection, alive: true };
          mind.subscriptions.push(subscription);
          return { [Symbol.dispose]: () => (subscription.alive = false) };
        },
        facets: {
          get: () => ({ iceServers: async () => ({ iceServers: [{ urls: "stun:test" }], ttlSeconds: 3600 }) }),
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
