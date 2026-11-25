// mind-connection.mjs: a connection to the mind that lasts: the one connection of mind.mjs, which
// every job of that process shares.
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
// `each(hook)` runs `hook(link)` on the connection that is up and on each new one, after
// `connected` (a job's subscription); `now(ms)` waits at most `ms` for a connection, and its
// failure names the last reason a connection did not come.

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
  let lastFailure;
  // a Set iterates over what is added while it iterates: a hook added during `connected` runs too
  const hooks = new Set();

  (async () => {
    let wait = 1000;
    while (!ended) {
      let link;
      let upAt;
      let timer;
      // a connection that hangs is given up; one that comes after that is closed, and runs no hook:
      // a hook on it would undo the hooks of the connection that is up by then
      let isGivenUp = false;
      const late = () => {
        if (isGivenUp) throw new Error("a connection that came after it was given up");
      };
      try {
        const attempt = (async () => {
          const made = await connect();
          if (isGivenUp) return dispose(made);
          link = made;
          await connected(link);
          late();
          for (const hook of hooks) {
            await hook(link);
            late();
          }
          return link;
        })();
        await Promise.race([
          attempt,
          new Promise((_, reject) => {
            timer = setTimeout(() => {
              isGivenUp = true;
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
        lastFailure = undefined;
        say({ connected: true });
        for (const waiter of waiters.splice(0)) waiter.resolve(link);
        const why = await Promise.race([link.closed, broken]);
        current = undefined;
        // `closed` answers { code, reason }: 1008 is a session whose sign-in ended
        lastFailure = why?.code ? `${why.code} ${why.reason}` : describe(why);
        say({ connected: false, failed: lastFailure });
      } catch (error) {
        current = undefined;
        lastFailure = describe(error);
        say({ connected: false, failed: lastFailure });
      }
      dispose(link);
      if (ended) break;
      if (upAt !== undefined && now() - upAt >= 60_000) wait = 1000;
      await sleep(wait);
      wait = Math.min(60_000, wait * 2);
    }
  })();

  const lasting = {
    /** The connection that is up, or none. */
    current: () => current,
    /** The connection that is up, or the next one; with `withinMs`, a failure after that long. */
    now(withinMs) {
      if (current) return Promise.resolve(current);
      if (ended) return Promise.reject(new Error("ended"));
      return new Promise((resolve, reject) => {
        let timer;
        const waiter = {
          resolve: (link) => (clearTimeout(timer), resolve(link)),
          reject: (error) => (clearTimeout(timer), reject(error)),
        };
        waiters.push(waiter);
        if (!withinMs) return;
        timer = setTimeout(() => {
          waiters = waiters.filter((other) => other !== waiter);
          reject(new Error(`no connection to the mind in ${withinMs / 1000} s${lastFailure ? `: ${lastFailure}` : ""}`));
        }, withinMs);
        timer.unref?.();
      });
    },
    /** `hook(link)` on the connection that is up and on each new one; answers its removal. A hook
     *  that throws ends the connection. */
    each(hook) {
      hooks.add(hook);
      const link = current;
      if (link) Promise.resolve().then(() => hook(link)).catch((error) => lasting.broke(link, error));
      return () => hooks.delete(hook);
    },
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
  return lasting;
}

function dispose(link) {
  try {
    link?.[Symbol.dispose]?.();
  } catch {}
}
