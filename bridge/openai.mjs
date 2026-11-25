// openai.mjs: the job `openai` of mind.mjs: a token of 60 s that opens ONE socket of OpenAI's
// realtime transcription with the MIND's OpenAI key (Sources/VoiceMeetMac/MindToken.swift, README
// "Dictation").
//
// The mind keeps its key at /secrets/openai and never hands it out: this job puts the placeholder
// `getSecret("/secrets/openai")` in the Authorization header of `itx.fetch`, and the vault puts the
// key in on the way to api.openai.com (as the mind's own Meet captions do: the runtime's
// `configs/default/call/outbound.ts`, `transcriptionStart`). OpenAI answers a client secret
// (`ek_…`) that opens a socket within 60 s; the app then configures the session itself
// (`session.update`, with its keywords), as with a key of its own.
//
// The app sends `{ job: "openai", openaiToken: <id> }`. The job says
// `{ openaiToken: id, value: "ek_…", expiresAt: <ms since 1970> }`, or
// `{ openaiToken: id, failed, refused? }` within `withinMs` (5 s). `refused: true` is the mind's
// or OpenAI's own no (no /secrets/openai, a key OpenAI does not take, no credit): the app then
// knows this mind cannot mint, until its next connection. A failure with no `refused` (no
// connection, no answer in time, an error of OpenAI's servers) may pass. The token is never
// logged, and a failure's words have any key or token in them cut out.

export const CLIENT_SECRETS = "https://api.openai.com/v1/realtime/client_secrets";
export const SECRET = "/secrets/openai";
/** The seconds a token may open a socket: OpenAI's own bound for a client secret is 10 to 7200. */
export const TOKEN_SECONDS = 60;

/** The session the token is for: the app's `session.update` sets the rest (keywords, prompt). */
export const SESSION = {
  type: "transcription",
  audio: {
    input: {
      format: { type: "audio/pcm", rate: 24000 },
      transcription: { model: "gpt-live-transcribe" },
      turn_detection: null,
    },
  },
};

/** The request that mints one token; the vault fills the key in. */
export const mintRequest = () =>
  new Request(CLIENT_SECRETS, {
    method: "POST",
    headers: { Authorization: `Bearer getSecret("${SECRET}")`, "Content-Type": "application/json" },
    body: JSON.stringify({ expires_after: { anchor: "created_at", seconds: TOKEN_SECONDS }, session: SESSION }),
  });

/** A text with every key and token cut out: `sk-…`, `ek_…`, a Bearer value. */
export const redacted = (text) =>
  String(text)
    .replace(/\b(sk|ek|rk)[-_][A-Za-z0-9_-]{4,}/g, "$1…")
    .replace(/Bearer\s+[^\s"',}]+/gi, "Bearer …")
    .slice(0, 300);

/** A failure that is the mind's or OpenAI's no, not a broken way to it. */
class Refused extends Error {}

/** One token through `connection.itx.fetch`: `{ value, expiresAt }`. `now` is the clock, in ms. */
export async function mint(connection, now = Date.now) {
  let response;
  try {
    response = await connection.itx.fetch(mintRequest());
  } catch (error) {
    // the vault refuses before OpenAI hears anything: "itx.fetch: no stored mind secret for …"
    const text = String(error?.message ?? error);
    if (/secret|refus|forbidden|not allowed|permission/i.test(text)) throw new Refused(text);
    throw error;
  }
  const text = await response.text();
  let json;
  try {
    json = JSON.parse(text);
  } catch {
    json = undefined;
  }
  if (!response.ok || typeof json?.value !== "string") {
    const reason = json?.error?.message || text || "no answer";
    const words = `OpenAI answered ${response.status}: ${reason}`;
    // 4xx is a no (the key, the credit, the request); 429 and 5xx may pass
    if (response.ok || (response.status >= 400 && response.status < 500 && response.status !== 429)) throw new Refused(words);
    throw new Error(words);
  }
  const at = Number(json.expires_at);
  return { value: json.value, expiresAt: Number.isFinite(at) && at > 0 ? at * 1000 : now() + TOKEN_SECONDS * 1000 };
}

/** The line `{ openaiToken }` of the app: one token, or a failure, within `withinMs`. */
export async function openaiTokenJob({ line, link, say, withinMs = 5_000, now = Date.now }) {
  const id = line.openaiToken;
  let timer;
  try {
    const token = await Promise.race([
      link.now(withinMs).then((connection) => mint(connection, now)),
      new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error(`no token from the mind in ${withinMs / 1000} s`)), withinMs);
      }),
    ]);
    say({ openaiToken: id, value: token.value, expiresAt: token.expiresAt });
  } catch (error) {
    say({ openaiToken: id, failed: redacted(error?.message ?? error), ...(error instanceof Refused ? { refused: true } : {}) });
  } finally {
    clearTimeout(timer);
  }
}
