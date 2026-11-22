// mind-connection.mjs: a connection to the mind that lasts, for the bridges that hold one for as
// long as the Mac is lent (device-live.mjs, device-events.mjs).
//
// `connect()` makes one connection (`connectMind`: `{ itx, closed, [Symbol.dispose] }`), and each
// new connection reads the stored sign-in again, so a session that ended after its 4 hours comes
// back with a renewed one. `connected(link)` runs on each new connection before anyone gets it
// (subscribe, ask for the ICE servers); when it throws, the connection is no good. A connection
// ends when its `closed` resolves (the socket closed: 1008 from the mind, or the heartbeat found
// no answer), or when a user says so with `broke(link)` (a call failed with a closed connection, a
// subscription that hears nothing). Then it connects again after a wait of 1 s, twice as long
// after each failure, at most 60 s; the wait starts at 1 s again after a connection that lasted a
// minute. It never gives up. stdout hears `{ connected: true }` and `{ connected: false, failed }`.

const describe = (error) => String(error?.message ?? error?.reason ?? error).slice(0, 300);
const pause = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/** Whether a failed call says the connection is gone, not that the mind refused the call. */
export const isConnectionError = (error) =>
  /\b1008\b|closed|disposed|shut down|broken|WebSocket|no answer|timed out|ECONN|ENOTFOUND|EAI_AGAIN|socket/i.test(
    describe(error),
  );

export function lastingConnection({
  connect,
  connected = async () => {},
  say = () => {},
  sleep = pause,
  now = Date.now,
  giveUpAfterMs = 60_000,
}) {
  let current;
  let ended = false;
  let waiters = [];
  let endCurrent = () => {};

  (async () => {
    let wait = 1000;
    while (!ended) {
      let link;
      let upAt;
      let timer;
      try {
        const attempt = (async () => {
          link = await connect();
          await connected(link);
          return link;
        })();
        // a connection that hangs is given up; one that comes after that is closed
        await Promise.race([
          attempt,
          new Promise((_, reject) => {
            timer = setTimeout(() => {
              attempt.then(dispose, () => {});
              reject(new Error(`no connection in ${giveUpAfterMs / 1000} s`));
            }, giveUpAfterMs);
          }),
        ]).finally(() => clearTimeout(timer));
        if (ended) {
          dispose(link);
          break;
        }
        const broken = new Promise((resolve) => (endCurrent = resolve));
        upAt = now();
        current = link;
        say({ connected: true });
        for (const waiter of waiters.splice(0)) waiter.resolve(link);
        const why = await Promise.race([link.closed, broken]);
        current = undefined;
        // `closed` answers { code, reason }: 1008 is a session whose sign-in ended
        say({ connected: false, failed: why?.code ? `${why.code} ${why.reason}` : describe(why) });
      } catch (error) {
        current = undefined;
        say({ connected: false, failed: describe(error) });
      }
      dispose(link);
      if (ended) break;
      if (upAt !== undefined && now() - upAt >= 60_000) wait = 1000;
      await sleep(wait);
      wait = Math.min(60_000, wait * 2);
    }
  })();

  return {
    /** The connection that is up, or none. */
    current: () => current,
    /** The connection that is up, or the next one. */
    now: () =>
      current
        ? Promise.resolve(current)
        : ended
          ? Promise.reject(new Error("ended"))
          : new Promise((resolve, reject) => waiters.push({ resolve, reject })),
    /** `link` is no good (a call on it failed with a closed connection): connect again. */
    broke(link, why) {
      if (link && link === current) endCurrent(why ?? "broken");
    },
    stop() {
      ended = true;
      for (const waiter of waiters.splice(0)) waiter.reject(new Error("ended"));
      endCurrent("stopped");
      dispose(current);
      current = undefined;
    },
  };
}

function dispose(link) {
  try {
    link?.[Symbol.dispose]?.();
  } catch {}
}
