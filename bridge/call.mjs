// call.mjs: the job `call` of mind.mjs: this Mac as a participant of a call on an agent's context
// (README, "A call's camera or screen from this Mac"). The call facet (`call.ts` of the mind's
// config) makes every SFU call; this job calls its person methods `join`, `signal` and `leave` as
// a member's page does, on the connection of mind.mjs (the person's own sign-in). The picture goes
// from the app's own peer connection to Cloudflare's SFU; only the signalling passes here.
//
// The facet knows a page by its subscription row on the agent's context, held by the asker and
// lent now. So each publication holds a row of its own, `mac-call-<device>-<id>` (a row's name is
// one segment of `[A-Za-z0-9_-]`, so the dots of the device's name become dashes), and the call
// shows it as a page of its own, with the person's name: "Jonas's Mac" (the kit reads the prefix).
// The row also hears its asking page leave: an un-set of the row `as` (`itx/subscription-configured`
// with no target) ends the publication, so a page that closes takes its Mac out with it.
//
// Lines of the app, each with its `publication` id:
//   { join: { context, kind, as?, device } }  the row, then the facet's join; says
//                                             { joined: { iceServers, ttlS, page } }
//   { offer: { sdp, mid } }                   the facet's `signal` publish; says { answer: { sdp } }
//   { leave: why }                            unpublish, leave, the row goes; says { left: why }
//   { signal: step }                          any other step of the facet's `signal` for this page
//                                             (a subscribe, a renegotiate); says { signaled }
// A join with `listen: true` and no kind is a page that only receives (`call-run`'s receiver).
// It also says { iceServers } at three quarters of their life (a `join` again with the admission),
// { gone: why } when the asking page left or the connection the publication was made on ended (the
// mind un-sets its row then, and the call takes it out), and { failed } with the reason.
import { randomUUID } from "node:crypto";

/** The un-set of a row: its page left. */
export const ROW_SET = "events.iterate.com/itx/subscription-configured";
/** The prefix of a Mac's page in a call; the kit names such a page "<name>'s Mac". */
export const PAGE_PREFIX = "mac-call-";
const KINDS = ["camera", "screen"];
/** An agent's path, as the facet's catalog has it. */
const CONTEXT = /^\/[\w.@+-]+(?:\/[\w.@+-]+){0,9}$/;

const describe = (error) => String(error?.message ?? error).slice(0, 300);
const within = (promise, ms, what) =>
  Promise.race([
    promise,
    new Promise((_, reject) => setTimeout(() => reject(new Error(`${what}: no answer in ${ms / 1000} s`)), ms).unref()),
  ]);

/** The page's name: the prefix, the device, a short id. A row's name is one segment,
 *  `[A-Za-z0-9_-]+` (and the facet takes `[\w:.@-]{1,200}`). */
export function pageOf(device, id) {
  const safe = String(device).replace(/[^A-Za-z0-9_-]/g, "-").slice(0, 80);
  return `${PAGE_PREFIX}${safe}-${String(id).replace(/[^A-Za-z0-9_-]/g, "").slice(0, 12)}`;
}

/** The job on `link` (mind.mjs): `say` tells the app, `take(line)` takes a line of the app. */
export function callJob({ link, say, refreshAt = 0.75 }) {
  /** Each publication: its connection, row, page, admission, kind, mid, timer. */
  const publications = new Map();
  const tell = (id, said) => say({ publication: id, ...said });

  // A new connection: what was made on the one before is gone (its rows went with it).
  const unhook = link.each((connection) => {
    for (const [id, p] of publications)
      if (p.connection && p.connection !== connection) end(id, "the connection to the mind ended");
  });

  function end(id, why) {
    const p = publications.get(id);
    if (!p) return;
    publications.delete(id);
    clearTimeout(p.timer);
    try {
      p.row?.[Symbol.dispose]?.();
    } catch {}
    tell(id, { gone: why });
  }

  const facetOf = (p) => p.connection.itx.cd(p.context).facets.get("call");

  async function join(id, input) {
    const kind = String(input?.kind ?? "");
    const context = String(input?.context ?? "");
    if (!(input?.listen === true && !kind) && !KINDS.includes(kind)) throw new Error(`a call takes a camera or a screen, not "${kind}"`);
    if (!CONTEXT.test(context)) throw new Error(`"${context.slice(0, 100)}" is no agent's path`);
    const connection = await link.now(20_000);
    const page = pageOf(input.device ?? "mac", id);
    const admission = randomUUID();
    const p = { connection, context, kind, page, admission, as: input.as ? String(input.as) : undefined };
    publications.set(id, p);
    // the row first: the facet knows a page by it
    p.row = await within(
      connection.itx.cd(context).subscribe({
        name: page,
        consumes: [ROW_SET],
        target: (batch) => {
          for (const event of JSON.parse(JSON.stringify(batch))) {
            const payload = event?.payload;
            if (event?.type === ROW_SET && payload?.target === null && p.as && payload.name === p.as)
              end(id, "the page that asked for it left the call");
          }
        },
      }),
      10_000,
      "the call's row",
    );
    if (publications.get(id) !== p) return p.row?.[Symbol.dispose]?.();
    const answer = await within(facetOf(p).join(page, { admit: admission, seq: 1 }), 15_000, "the call's join");
    const joined = JSON.parse(JSON.stringify(answer ?? {}));
    p.admission = joined.admission || admission;
    refresh(id, joined.ttlS);
    tell(id, { joined: { iceServers: joined.iceServers ?? [], ttlS: joined.ttlS, page } });
  }

  /** The TURN credentials again, at `refreshAt` of their life: a join with the admission. */
  function refresh(id, ttlS) {
    const p = publications.get(id);
    if (!p) return;
    clearTimeout(p.timer);
    p.timer = setTimeout(async () => {
      const now = publications.get(id);
      if (!now) return;
      try {
        const answer = JSON.parse(JSON.stringify(await within(facetOf(now).join(now.page, { admission: now.admission }), 15_000, "the call's join")));
        tell(id, { iceServers: answer.iceServers ?? [] });
        refresh(id, answer.ttlS);
      } catch (error) {
        tell(id, { failed: `fresh TURN credentials: ${describe(error)}` });
        refresh(id, 60);
      }
    }, Math.max(60, Number(ttlS) || 0) * 1000 * refreshAt);
    p.timer.unref?.();
  }

  async function offer(id, input) {
    const p = publications.get(id);
    if (!p) throw new Error("no such publication: join first");
    const sdp = String(input?.sdp ?? "");
    const mid = String(input?.mid ?? "");
    if (!sdp || !mid) throw new Error("an offer has an sdp and a mid");
    const answer = await within(facetOf(p).signal(p.page, { publish: p.kind, sdp, mid }, p.admission), 15_000, "the call's publish");
    if (publications.get(id) !== p) return;
    p.mid = mid;
    tell(id, { answer: { sdp: String(answer?.sdp ?? "") } });
  }

  async function step(id, input) {
    const p = publications.get(id);
    if (!p) throw new Error("no such publication: join first");
    const answer = await within(facetOf(p).signal(p.page, input, p.admission), 15_000, "the call's signal");
    tell(id, { signaled: JSON.parse(JSON.stringify(answer ?? {})) });
  }

  async function leave(id, why) {
    const p = publications.get(id);
    if (!p) return tell(id, { left: String(why ?? "") });
    publications.delete(id);
    clearTimeout(p.timer);
    const facet = facetOf(p);
    if (p.mid) await within(facet.signal(p.page, { unpublish: p.kind, mid: p.mid }, p.admission), 10_000, "unpublish").catch(() => {});
    await within(facet.leave(p.page, p.admission), 10_000, "leave").catch((error) => tell(id, { failed: `leave: ${describe(error)}` }));
    try {
      p.row?.[Symbol.dispose]?.();
    } catch {}
    tell(id, { left: String(why ?? "") });
  }

  return {
    /** A line of the app: one publication's step. A failure says `{ publication, failed }`; a
     *  failed join or offer ends the publication. */
    async take(line) {
      const id = String(line.publication ?? "");
      if (!id) return say({ failed: "a call's line names its publication" });
      try {
        if (line.join) return await join(id, line.join);
        if (line.offer) return await offer(id, line.offer);
        if (line.signal) return await step(id, line.signal);
        if ("leave" in line) return await leave(id, line.leave);
      } catch (error) {
        tell(id, { failed: describe(error) });
        if (line.join || line.offer) await leave(id, "failed");
      }
    },
    /** Every publication leaves the call, for at most `ms`. */
    async end(ms = 5000) {
      unhook();
      await within(Promise.all([...publications.keys()].map((id) => leave(id, "the Mac stopped"))), ms, "the leaves").catch(() => {});
    },
    /** For tests: the page of a publication. */
    pageOf: (id) => publications.get(id)?.page,
  };
}
