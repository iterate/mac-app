// openai.mjs: OpenAI's realtime transcription over a WebSocket
// (https://developers.openai.com/api/docs/guides/realtime-transcription), as the app could stream
// to it: `wss://api.openai.com/v1/realtime?intent=transcription`, a `transcription` session of
// 24 kHz pcm16 with no turn detection, the clip in 0.1 s pieces at the pace of the clock, and a
// commit at its end. The word list's terms are its `keywords`.
//
// - `gpt-live-transcribe` writes deltas while the audio streams in; `delay` trades their lead for
//   accuracy (two engines: low and medium). $0.017 a minute (its model page, 24 Nov 2026).
// - `gpt-transcribe` starts on the committed turn. $0.0045 a minute.
//
// Each clip gets a connection of its own, opened and configured before its audio starts: the
// app's case when it keeps one open (or opens it at fn down; then the setup is in front of the
// first partial). The connect and the session's setup are measured on their own. Only the bench's
// clips go to OpenAI. The key is OPENAI_API_KEY in the environment (run.mjs reads it from
// Doppler); it is never printed or written.
import { mkdirSync } from "node:fs";
import { join } from "node:path";
import { paced, readWav, resampled } from "../lib.mjs";

const URL = "wss://api.openai.com/v1/realtime?intent=transcription";
const PROMPT = "A software engineer dictating to a coding agent about the iterate platform.";

/** Opens a socket and configures the session: `{ socket, events, connectMs, sessionMs }`. */
async function open(transcription) {
  const key = process.env.OPENAI_API_KEY;
  if (!key) throw new Error("no OPENAI_API_KEY");
  const started = performance.now();
  const socket = new WebSocket(URL, { headers: { Authorization: `Bearer ${key}` } });
  const listeners = new Set();
  const events = {
    on: (listener) => listeners.add(listener),
    off: (listener) => listeners.delete(listener),
    next: (match, ms = 15000) =>
      new Promise((resolve, reject) => {
        const timer = setTimeout(() => done(new Error(`no ${match} after ${ms} ms`)), ms);
        const listener = (event) => {
          if (event.type === "error") done(new Error(event.error?.message ?? "error"));
          else if (event.type === match) done(null, event);
        };
        const done = (error, event) => {
          clearTimeout(timer);
          events.off(listener);
          error ? reject(error) : resolve(event);
        };
        events.on(listener);
      }),
  };
  socket.onmessage = (message) => {
    const event = JSON.parse(String(message.data));
    for (const listener of [...listeners]) listener(event);
  };
  await new Promise((resolve, reject) => {
    socket.onopen = resolve;
    socket.onerror = () => reject(new Error("the WebSocket did not open"));
  });
  const connectMs = performance.now() - started;
  const configured = performance.now();
  const updated = events.next("session.updated");
  socket.send(
    JSON.stringify({
      type: "session.update",
      session: {
        type: "transcription",
        audio: { input: { format: { type: "audio/pcm", rate: 24000 }, transcription, turn_detection: null } },
      },
    }),
  );
  await updated;
  return { socket, events, connectMs, sessionMs: performance.now() - configured };
}

function engine(id, name, model, costPerMinute, extra = {}) {
  return {
    id,
    name,
    runtime: "OpenAI, over a WebSocket",
    streaming: model === "gpt-live-transcribe",
    online: true,
    costPerMinute,
    async run(clips, { entries, log, scratch }) {
      const folder = join(scratch, "24k");
      mkdirSync(folder, { recursive: true });
      const transcription = { model, prompt: PROMPT, keywords: entries.map(({ term }) => term), languages: ["en"], ...extra };
      const results = [];
      const connects = [];
      const sessions = [];
      for (const [index, clip] of clips.entries()) {
        try {
          const { samples } = readWav(resampled(clip.wav, 24000, folder));
          const { socket, events, connectMs, sessionMs } = await open(transcription);
          connects.push(connectMs);
          sessions.push(sessionMs);
          const partials = [];
          let said = "";
          let item;
          let streamStarted = 0;
          let failed;
          const finals = new Map();
          events.on((event) => {
            if (event.type === "input_audio_buffer.committed") item = event.item_id;
            if (event.type === "conversation.item.input_audio_transcription.delta") {
              said += event.delta;
              if (said.trim()) partials.push({ t: Math.round(performance.now() - streamStarted), text: said });
            }
            if (event.type === "conversation.item.input_audio_transcription.completed") finals.set(event.item_id, event.transcript);
            if (event.type === "conversation.item.input_audio_transcription.failed") failed = event.error?.message ?? "failed";
            if (event.type === "error") failed = event.error?.message ?? "error";
          });
          streamStarted = performance.now();
          const ended = await paced(samples, 24000, (piece) => {
            socket.send(JSON.stringify({ type: "input_audio_buffer.append", audio: Buffer.from(piece.buffer, piece.byteOffset, piece.byteLength).toString("base64") }));
          });
          socket.send(JSON.stringify({ type: "input_audio_buffer.commit" }));
          const final = await new Promise((resolve, reject) => {
            const timer = setTimeout(() => reject(new Error("no final after 30 s")), 30000);
            const check = () => {
              if (failed) return clearTimeout(timer), reject(new Error(failed));
              if (item && finals.has(item)) return clearTimeout(timer), resolve(finals.get(item));
            };
            events.on(check);
            check();
          });
          const endToFinalMs = performance.now() - ended;
          socket.close();
          results.push({ text: final.trim(), partials, firstPartialMs: partials[0]?.t, endToFinalMs, connectMs, sessionMs });
        } catch (error) {
          results.push({ error: error.message });
        }
        log(`${id} ${index + 1}/${clips.length}`);
      }
      const median = (list) => [...list].sort((a, b) => a - b)[Math.floor(list.length / 2)] / 1000;
      return {
        // cold: a new connection and its session, before the first word can go; warm: one kept open and configured
        setup: { coldSeconds: median(connects) + median(sessions), connectSeconds: median(connects), sessionSeconds: median(sessions), warmSeconds: 0 },
        clips: results,
      };
    },
  };
}

export default [
  engine("gpt-live-transcribe-low", "gpt-live-transcribe, delay low", "gpt-live-transcribe", 0.017, { delay: "low" }),
  engine("gpt-live-transcribe-medium", "gpt-live-transcribe, delay medium", "gpt-live-transcribe", 0.017, { delay: "medium" }),
  engine("gpt-transcribe", "gpt-transcribe, committed turn", "gpt-transcribe", 0.0045),
];
