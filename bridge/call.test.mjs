import assert from "node:assert/strict";
import { test } from "node:test";
import { callJob, pageOf, ROW_SET } from "./call.mjs";
import { eventually, fakeMind, until } from "./fake-mind.test-helper.mjs";
import { mindLink } from "./mind.mjs";

const AGENT = "/agents/meet/2026-11-25-1000-standup";

/** A fake call facet: each call it hears, with its connection; `refuse` makes a method throw. */
function fakeCall(mind) {
  const calls = [];
  const refuse = {};
  mind.facets = {
    call: (path, connection) => {
      const record = (method, args) => {
        calls.push({ path, method, args: JSON.parse(JSON.stringify(args)), connection });
        if (refuse[method]) throw new Error(refuse[method]);
      };
      return {
        async join(page, input) {
          record("join", [page, input]);
          return { iceServers: [{ urls: "turn:turn.example:3478", username: "u", credential: "c" }], ttlS: 14_400, admission: input?.admit ?? input?.admission };
        },
        async signal(page, step, admission) {
          record("signal", [page, step, admission]);
          return "publish" in step ? { sdp: "v=0 answer" } : {};
        },
        async leave(page, admission) {
          record("leave", [page, admission]);
        },
      };
    },
  };
  return { calls, refuse };
}

const start = (mind) => {
  const said = [];
  const say = (line) => said.push(line);
  const link = mindLink({ name: "jonas.mac", connect: mind.connect, sleep: mind.sleep, say });
  const job = callJob({ link, say });
  return { job, said, link };
};
const of = (said, key) => said.filter((line) => key in line);

test("a publication joins the call as a page of its own, publishes its offer, and leaves", async () => {
  const mind = fakeMind();
  const { calls } = fakeCall(mind);
  const { job, said, link } = start(mind);
  await job.take({ publication: "p1", join: { context: AGENT, kind: "screen", as: "sub-page1", device: "jonas.mac" } });
  const page = job.pageOf("p1");
  assert.equal(page, "mac-call-jonas-mac-p1");
  assert.match(page, /^[A-Za-z0-9_-]+$/, "a row's name is one segment");
  // the row on the agent's context comes before the join: the facet knows a page by it
  const row = mind.subscriptions.find((s) => s.name === page);
  assert.ok(row?.alive);
  assert.deepEqual(row.consumes, [ROW_SET]);
  const [join] = calls;
  assert.equal(join.path, AGENT);
  assert.equal(join.method, "join");
  assert.equal(join.args[0], page);
  assert.equal(join.args[1].seq, 1);
  const admission = join.args[1].admit;
  assert.ok(admission);
  assert.deepEqual(of(said, "joined")[0].joined, { iceServers: [{ urls: "turn:turn.example:3478", username: "u", credential: "c" }], ttlS: 14_400, page });

  await job.take({ publication: "p1", offer: { sdp: "v=0 offer", mid: "0" } });
  assert.deepEqual(calls[1].args, [page, { publish: "screen", sdp: "v=0 offer", mid: "0" }, admission]);
  assert.deepEqual(of(said, "answer")[0], { publication: "p1", answer: { sdp: "v=0 answer" } });

  await job.take({ publication: "p1", leave: "a browser screen was chosen" });
  assert.deepEqual(
    calls.slice(2).map((c) => [c.method, c.args]),
    [
      ["signal", [page, { unpublish: "screen", mid: "0" }, admission]],
      ["leave", [page, admission]],
    ],
  );
  assert.equal(row.alive, false, "the row goes with it");
  assert.equal(of(said, "left")[0].left, "a browser screen was chosen");
  await job.end();
  link.stop();
});

test("the page that asked leaves: its row's un-set ends the publication", async () => {
  const mind = fakeMind();
  fakeCall(mind);
  const { job, said, link } = start(mind);
  await job.take({ publication: "p2", join: { context: AGENT, kind: "camera", as: "sub-asker", device: "jonas.mac" } });
  // another row's un-set changes nothing
  mind.deliver([{ type: ROW_SET, payload: { name: "sub-other", target: null } }]);
  assert.equal(of(said, "gone").length, 0);
  mind.deliver([{ type: ROW_SET, payload: { name: "sub-asker", target: null } }]);
  assert.deepEqual(of(said, "gone")[0], { publication: "p2", gone: "the page that asked for it left the call" });
  await job.end();
  link.stop();
});

test("a new connection: what was made on the one before is gone", async () => {
  const mind = fakeMind();
  fakeCall(mind);
  const { job, said, link } = start(mind);
  await job.take({ publication: "p3", join: { context: AGENT, kind: "screen", device: "jonas.mac" } });
  mind.connections[0].end();
  await eventually(() => of(said, "gone").length === 1);
  assert.equal(of(said, "gone")[0].gone, "the connection to the mind ended");
  await job.end();
  link.stop();
});

test("a refused publish says why and leaves the call; a bad kind or path is refused before any call", async () => {
  const mind = fakeMind();
  const { calls, refuse } = fakeCall(mind);
  const { job, said, link } = start(mind);
  await job.take({ publication: "x", join: { context: AGENT, kind: "mic", device: "jonas.mac" } });
  await job.take({ publication: "y", join: { context: "agents/../x", kind: "screen", device: "jonas.mac" } });
  assert.equal(calls.length, 0);
  assert.match(of(said, "failed")[0].failed, /camera or a screen/);
  assert.match(of(said, "failed")[1].failed, /no agent's path/);

  await job.take({ publication: "p4", join: { context: AGENT, kind: "screen", device: "jonas.mac" } });
  refuse.signal = "This mind has no Cloudflare Realtime SFU app yet.";
  await job.take({ publication: "p4", offer: { sdp: "v=0", mid: "0" } });
  assert.match(said.find((l) => l.publication === "p4" && l.failed).failed, /no Cloudflare Realtime SFU/);
  assert.equal(calls.at(-1).method, "leave");
  assert.equal(job.pageOf("p4"), undefined);
  await job.end();
  link.stop();
});

test("the TURN credentials are asked for again before they end, with the admission", async () => {
  const mind = fakeMind();
  const { calls } = fakeCall(mind);
  const said = [];
  const link = mindLink({ name: "jonas.mac", connect: mind.connect, sleep: mind.sleep, say: () => {} });
  // the 4 hours of a member's credentials, at 1/600000 of them: 24 ms
  const job = callJob({ link, say: (line) => said.push(line), refreshAt: 1 / 600_000 });
  await job.take({ publication: "p5", join: { context: AGENT, kind: "camera", device: "jonas.mac" } });
  await eventually(() => of(said, "iceServers").length >= 1);
  const again = calls.filter((c) => c.method === "join")[1];
  assert.deepEqual(Object.keys(again.args[1]), ["admission"]);
  await job.end();
  link.stop();
});

test("the end leaves every call, so the process can exit", async () => {
  const mind = fakeMind();
  const { calls } = fakeCall(mind);
  const { job, link } = start(mind);
  await job.take({ publication: "a", join: { context: AGENT, kind: "camera", device: "jonas.mac" } });
  await job.take({ publication: "b", join: { context: AGENT, kind: "screen", device: "jonas.mac" } });
  await job.end();
  assert.equal(calls.filter((c) => c.method === "leave").length, 2);
  await until(() => mind.subscriptions.every((s) => !s.alive));
  link.stop();
});

test("a page that only listens joins with no kind, and passes its own steps to the facet", async () => {
  const mind = fakeMind();
  const { calls } = fakeCall(mind);
  const { job, said, link } = start(mind);
  await job.take({ publication: "rx", join: { context: AGENT, listen: true, device: "call-run" } });
  const page = job.pageOf("rx");
  await job.take({ publication: "rx", signal: { subscribe: ["mac-call-jonas-mac-p1:screen"] } });
  assert.deepEqual(calls[1].args.slice(0, 2), [page, { subscribe: ["mac-call-jonas-mac-p1:screen"] }]);
  assert.deepEqual(of(said, "signaled")[0], { publication: "rx", signaled: {} });
  await job.end();
  link.stop();
});

test("a page's name keeps to the facet's characters", () => {
  assert.equal(pageOf("jane's mac/x", "abc-123"), "mac-call-jane-s-mac-x-abc-123");
});
