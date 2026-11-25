// node --test bridge/openai.test.mjs — a 60 s token for OpenAI, minted with the mind's own key.
import assert from "node:assert/strict";
import { test } from "node:test";
import { fakeMind } from "./fake-mind.test-helper.mjs";
import { mindBridge, mindLink } from "./mind.mjs";
import { CLIENT_SECRETS, openaiTokenJob, redacted } from "./openai.mjs";

const answer = (status, body) => new Response(typeof body === "string" ? body : JSON.stringify(body), { status });

async function run(mind, options = {}) {
  const link = mindLink({ name: "test", connect: mind.connect, sleep: mind.sleep, say: () => {} });
  const said = [];
  try {
    await openaiTokenJob({ line: { openaiToken: 7 }, link, say: (line) => said.push(line), ...options });
  } finally {
    link.stop();
  }
  return said;
}

test("the token comes through itx.fetch, with the vault's placeholder and not a key", async () => {
  const mind = fakeMind();
  mind.fetch = async () => answer(200, { value: "ek_secret123456", expires_at: 1_790_000_060, session: {} });
  assert.deepEqual(await run(mind), [{ openaiToken: 7, value: "ek_secret123456", expiresAt: 1_790_000_060_000 }]);
  const [request] = mind.fetched;
  assert.equal(request.url, CLIENT_SECRETS);
  assert.equal(request.method, "POST");
  assert.equal(request.headers.get("authorization"), 'Bearer getSecret("/secrets/openai")');
  const body = await request.json();
  assert.deepEqual(body.expires_after, { anchor: "created_at", seconds: 60 });
  assert.equal(body.session.type, "transcription");
  assert.equal(body.session.audio.input.transcription.model, "gpt-live-transcribe");
  assert.equal(body.session.audio.input.turn_detection, null);
});

test("an answer with no expires_at expires 60 s from now", async () => {
  const mind = fakeMind();
  mind.fetch = async () => answer(200, { value: "ek_abcdef" });
  assert.deepEqual(await run(mind, { now: () => 1000 }), [{ openaiToken: 7, value: "ek_abcdef", expiresAt: 61_000 }]);
});

test("a mind with no /secrets/openai is a refusal: the app knows the mind cannot mint", async () => {
  const [line] = await run(fakeMind());
  assert.equal(line.openaiToken, 7);
  assert.equal(line.refused, true);
  assert.match(line.failed, /no stored mind secret/);
  assert.equal("value" in line, false);
});

test("OpenAI's no is a refusal, and its words lose any key", async () => {
  const mind = fakeMind();
  mind.fetch = async () => answer(401, { error: { message: "Incorrect API key provided: sk-proj-abcdefghijkl1234" } });
  const [line] = await run(mind);
  assert.equal(line.refused, true);
  assert.equal(line.failed, "OpenAI answered 401: Incorrect API key provided: sk…");
});

test("an error of OpenAI's servers may pass: a failure, not a refusal", async () => {
  const mind = fakeMind();
  mind.fetch = async () => answer(503, "upstream unavailable");
  assert.deepEqual(await run(mind), [{ openaiToken: 7, failed: "OpenAI answered 503: upstream unavailable" }]);
});

test("no answer within the bound is a failure, not a refusal", async () => {
  const mind = fakeMind();
  mind.fetch = () => new Promise(() => {});
  const started = Date.now();
  assert.deepEqual(await run(mind, { withinMs: 50 }), [{ openaiToken: 7, failed: "no token from the mind in 0.05 s" }]);
  assert.ok(Date.now() - started < 1000);
});

test("no connection within the bound is a failure, not a refusal", async () => {
  const mind = fakeMind();
  mind.refuseConnects = Infinity;
  const [line] = await run(mind, { withinMs: 50 });
  assert.equal(line.openaiToken, 7);
  assert.equal(line.refused, undefined);
  assert.match(line.failed, /no (connection|token)/);
});

test("the redaction cuts tokens, keys and Bearer values", () => {
  assert.equal(redacted("ek_1234567890 and sk-abcd1234 and Bearer xyz"), "ek… and sk… and Bearer …");
});

test("the bridge runs the job by its line and names the job and the id", async () => {
  const mind = fakeMind();
  mind.fetch = async () => answer(200, { value: "ek_zzzzzz", expires_at: 2 });
  const said = [];
  const bridge = mindBridge({ mind: "example.com", name: "test", connect: mind.connect, sleep: mind.sleep, say: (line) => said.push(line) });
  bridge.take({ job: "openai", openaiToken: "a1" });
  await bridge.end();
  assert.deepEqual(said.filter((line) => line.job), [{ job: "openai", openaiToken: "a1", value: "ek_zzzzzz", expiresAt: 2000 }]);
});
