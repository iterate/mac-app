#!/usr/bin/env node
// mind.mjs: this Mac's one process for a mind, with one connection to it, as the person (the
// iterate CLI's own sign-in: the Mac's key lends and does nothing else; `iterate provide` of
// mac-endpoint.ts is that other identity, and a process of its own).
//
//   node mind.mjs <mind> --name <name> --iterate <iterate.js>
//
// The app (Sources/VoiceMeetMac/MindBridge.swift) starts one for the mind it is lent to, for as
// long as it is, and a short one for another mind while a job of that mind runs (a capture that
// began before a switch, an input or a word list for a mind the Mac is not lent to). The
// connection lasts (mind-connection.mjs): it connects again when it ends, and a session whose
// sign-in ended after its 4 hours (1008) comes back with a renewed one. Every job is on it:
//
//   events   what this Mac tells its mind about itself, and the acts read back  (events.mjs)
//   live     the signalling of live                                             (live.mjs)
//   record   the recorder's spool into the mind                                 (record.mjs)
//   capture  one capture into the mind, by its id                               (capture.mjs)
//   input    one input into the mind, by its id                                 (input.mjs)
//   words    the mind's word list into a file                                   (words.mjs)
//   openai   sockets of OpenAI's realtime transcription through the mind, by id  (openai.mjs)
//
// stdin and stdout are JSON lines, each with its `job`: `{ job, … }`. `events`, `live` and
// `record` run from `{ job, start: true }` (record's also names `spool`) to `{ job, stop: true }`,
// and record hears `{ job, slot: <t> }` for each slot the recorder seals;
// a capture's lines name it (`capture`), an input's line names it (`input`), and an OpenAI
// socket's lines name it (`socket`), and what each says names it again. A line with no `job` is the
// process's own: `{ connected: true }`, `{ connected: false, failed }`, and `{ failed }` for the
// app's log. When stdin closes (the app is
// gone, or no job of this mind is left), the jobs end: the events that wait go, the last byes of
// live, the record's slot; the inputs, word lists and captures' ends that run are awaited.
import { realpathSync } from "node:fs";
import { dirname, join } from "node:path";
import { createInterface } from "node:readline";
import { fileURLToPath, pathToFileURL } from "node:url";
import { parseArgs } from "node:util";
import { captureUpload } from "./capture.mjs";
import { deviceEvents } from "./events.mjs";
import { inputJob } from "./input.mjs";
import { deviceLive } from "./live.mjs";
import { lastingConnection } from "./mind-connection.mjs";
import { openaiSockets } from "./openai.mjs";
import { recordUploads } from "./record.mjs";
import { wordsJob } from "./words.mjs";

/** The lasting connection, each with `device`: the context /devices/<name>. */
export const mindLink = ({ name, connect, say, sleep, now }) =>
  lastingConnection({
    connect,
    say,
    sleep,
    now,
    connected: async (connection) => {
      connection.device = connection.itx.cd(`/devices/${name}`);
    },
  });

/** The jobs on one connection: `take(line)` takes a line of the app; `end()` ends them all. */
export function mindBridge({ mind, name, connect, say, sleep, now, record: recordOptions = {} }) {
  const link = mindLink({ name, connect, say, sleep, now });
  const running = new Set();
  /** A promise of a job that the end awaits. */
  const track = (promise) => {
    if (!promise?.then) return;
    const settled = promise.catch((error) => say({ failed: describe(error) })).finally(() => running.delete(settled));
    running.add(settled);
  };
  /** The jobs that run from `start` to `stop`. */
  const standing = {
    events: (tell) => deviceEvents({ link, say: tell }),
    live: (tell) => deviceLive({ link, say: tell }),
    record: (tell, line) => recordUploads({ link, spool: line.spool, maxBytes: line.maxBytes, say: tell, ...recordOptions }),
  };
  const started = {};
  const captures = new Map();
  const openai = openaiSockets({ link, say: (said) => say({ job: "openai", ...said }) });

  function takeOne(line) {
    const { job } = line;
    if (job in standing) {
      if (line.start && !started[job]) started[job] = standing[job]((said) => say({ job, ...said }), line);
      const running = started[job];
      if (line.stop) {
        delete started[job];
        return track(running?.end());
      }
      if (job === "events" && line.event) return running?.add(line.event);
      if (job === "events" && line.log) return running?.log(line);
      if (job === "live") return track(running?.take(line));
      if (job === "record" && line.slot !== undefined) return running?.sealed(Number(line.slot));
      return;
    }
    if (job === "capture") {
      const id = String(line.capture);
      let capture = captures.get(id);
      if (!capture) {
        // a late line of a capture that ended (its last words after its `finish`) fails nothing
        if (!line.folder) return say({ failed: `capture ${id}: a line after its end` });
        capture = captureUpload({
          link,
          mind,
          capture: id,
          folder: line.folder,
          heardBy: line.heardBy,
          // a capture first heard of at its end stayed on this Mac
          kept: Boolean(line.finish),
          say: (said) => {
            if (said.done || said.failed || said.discarded) captures.delete(id);
            say({ job, capture: id, ...said });
          },
        });
        captures.set(id, capture);
      }
      return track(capture.take(line));
    }
    if (job === "input")
      return track(inputJob({ line, name, link, say: (said) => say({ job, input: line.input, ...said }) }));
    if (job === "words") return track(wordsJob({ line, link, say: (said) => say({ job, ...said }) }));
    if (job === "openai") return track(openai.take(line));
    throw new Error(`no job "${job}"`);
  }

  return {
    link,
    take(line) {
      try {
        takeOne(line);
      } catch (error) {
        // one bad line fails its own job, never the process
        const of = Object.fromEntries(["job", "capture", "input", "socket"].filter((key) => key in line).map((key) => [key, line[key]]));
        say({ ...of, failed: describe(error) });
      }
    },
    /** Every job ends; then the connection. */
    async end() {
      for (const job of Object.keys(started)) takeOne({ job, stop: true });
      // the OpenAI sockets close first: one that still opens closes when it comes
      openai.end();
      while (running.size) await Promise.all(running);
      link.stop();
    },
  };
}

const describe = (error) => String(error?.message ?? error).slice(0, 300);

if (process.argv[1] && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const { positionals, values } = parseArgs({
    allowPositionals: true,
    options: { name: { type: "string" }, iterate: { type: "string" } },
  });
  const mind = positionals[0];
  if (!mind || !values.name || !values.iterate) throw new Error("node mind.mjs <mind> --name <name> --iterate <iterate.js>");
  const say = (line) => process.stdout.write(`${JSON.stringify(line)}\n`);
  // a job's failure that no one caught is a line for the log, not the end of every job
  process.on("unhandledRejection", (error) => say({ failed: describe(error) }));
  const { addressOf, connectMind } = await import(pathToFileURL(join(dirname(dirname(values.iterate)), "dist/node.mjs")).href);
  const bridge = mindBridge({
    mind,
    name: values.name,
    connect: () => connectMind({ address: addressOf(mind), signIn: false }),
    say,
  });
  for await (const text of createInterface({ input: process.stdin })) {
    if (!text) continue;
    let line;
    try {
      line = JSON.parse(text);
    } catch {
      say({ failed: `not a JSON line: ${text.slice(0, 100)}` });
      continue;
    }
    bridge.take(line);
  }
  // stdin closed: the app is gone, or no job of this mind is left
  await bridge.end();
  process.exit(0);
}
