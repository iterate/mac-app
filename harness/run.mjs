#!/usr/bin/env node
// run.mjs: the app, started and driven with no hand, in a home of its own (README, "Testing with
// no hand").
//
//   node harness/run.mjs <scenario|ci|all> [--app .build/debug/VoiceMeetMac] [--keep]
//
// It builds nothing: it runs the app that `swift build` made. Each scenario makes a new home in the
// temporary folder, starts the app there with `--home <home>`, drives the control socket
// (and the endpoint's, as a mind would), waits for each thing with a deadline, and quits the app.
// A scenario that needs a mind gets the bridges' fake mind (bridge/fake-mind.test-helper.mjs) as
// its iterate CLI. stdout is one JSON line for each scenario, `{ scenario, ok, seconds, error? }`
// (a failed one has its home and the last lines of the app's log);
// the exit is 1 when one failed. `ci` is every scenario not marked local; `all` is every one.
// `--keep` keeps each home, with the app's log in <home>/logs/app.log. Every copy it started is
// killed when it ends: after a scenario, after a failure, an exception, Ctrl-C or SIGTERM.
import { execFileSync, spawn } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { createConnection } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { parseArgs } from "node:util";

const root = join(import.meta.dirname, "..");
const MIND = "example.com";
const NAME = "harness.mac";

/** One request on a socket of the app: one line out, one line back. Its `error` is thrown. */
function ask(socket, method, parameters = {}) {
  return new Promise((resolve, reject) => {
    const connection = createConnection(socket);
    let text = "";
    connection.on("connect", () => connection.write(`${JSON.stringify({ method, ...parameters })}\n`));
    connection.on("data", (chunk) => (text += chunk));
    connection.on("error", reject);
    connection.on("end", () => {
      try {
        const answer = JSON.parse(text);
        if ("error" in answer) reject(new Error(`${method}: ${answer.error}`));
        else resolve(answer.ok);
      } catch {
        reject(new Error(`${method}: no answer`));
      }
    });
  });
}

/** Asks `check` every 200 ms until it answers something true; throws `what` after `seconds`. */
async function until(what, seconds, check) {
  const deadline = Date.now() + seconds * 1000;
  let last;
  while (Date.now() < deadline) {
    try {
      const value = await check();
      if (value) return value;
    } catch (error) {
      last = error;
    }
    await new Promise((resolve) => setTimeout(resolve, 200));
  }
  throw new Error(`gave up after ${seconds} s waiting for ${what}${last ? ` (last: ${last.message})` : ""}`);
}

/** Every node of `ui.tree`, depth first. */
function* nodes(tree) {
  for (const node of tree.windows ?? tree.children ?? []) {
    yield node;
    yield* nodes(node);
  }
}

/** The config of a home with these minds, the first active, as the CLI writes it: by a rename. */
function writeConfig(home, iterate, minds, active = minds[0].mind) {
  const file = join(home, "config.json");
  writeFileSync(
    `${file}.new`,
    JSON.stringify({
      spec: "@iterate-com/mac-app",
      node: process.execPath,
      iterateBin: join(iterate, "bin/iterate.js"),
      bridge: join(root, "bridge/mac-endpoint.ts"),
      version: "0.0.0-harness",
      minds: minds.map(({ mind, name }) => ({ mind, name, keyFile: join(home, "keys", `${mind}.key`) })),
      active,
    }),
  );
  renameSync(`${file}.new`, file);
}

/**
 * A home with config.json, whose iterate CLI is the fake mind: what it is sent is in `mind.jsonl`,
 * each event with the mind (`mind`) and the path it reached. Every mind is the same fake mind.
 */
function withMind(home, minds = [{ mind: MIND, name: NAME }]) {
  const iterate = join(home, "fake-iterate");
  mkdirSync(join(iterate, "bin"), { recursive: true });
  mkdirSync(join(iterate, "dist"), { recursive: true });
  writeFileSync(join(iterate, "bin/iterate.js"), "// the bridges import ../dist/node.mjs beside this file\n");
  // the bridges' own fake mind; each append is kept in a file the scenario reads
  writeFileSync(
    join(iterate, "dist/node.mjs"),
    `import { appendFileSync } from "node:fs";
import { fakeMind } from ${JSON.stringify(join(root, "bridge/fake-mind.test-helper.mjs"))};
const mind = fakeMind();
export const addressOf = (mind) => mind;
export async function connectMind({ address }) {
  const connection = await mind.connect();
  const cd = connection.itx.cd;
  connection.itx.cd = (path) => ({
    ...cd(path),
    async append(...events) {
      for (const event of events) appendFileSync(${JSON.stringify(join(home, "mind.jsonl"))}, JSON.stringify({ mind: address, path, ...event }) + "\\n");
      return cd(path).append(...events);
    },
  });
  return connection;
}
`,
  );
  writeConfig(home, iterate, minds);
  return () =>
    existsSync(join(home, "mind.jsonl"))
      ? readFileSync(join(home, "mind.jsonl"), "utf8").trim().split("\n").map((line) => JSON.parse(line))
      : [];
}

/** Every copy of the app that runs now. */
const running = new Set();

/** Kills every copy that still runs, at once: for an end that cannot wait. */
function killAll() {
  for (const child of running) child.kill("SIGKILL");
}
process.on("exit", killAll);
for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"]) {
  process.on(signal, () => {
    killAll();
    process.exit(130);
  });
}

/** The app in `home`, until `quit`. */
async function start(app, home, env = {}) {
  const child = spawn(app, ["--home", home], { env: { ...process.env, ...env }, stdio: ["ignore", "ignore", "ignore"] });
  running.add(child);
  const ended = new Promise((resolve) => child.on("exit", resolve)).then(() => running.delete(child));
  const control = (method, parameters) => ask(join(home, "control.sock"), method, parameters);
  const endpoint = (method, parameters) => ask(join(home, "endpoint.sock"), method, parameters);
  const quit = async () => {
    if (!running.has(child)) return;
    // SIGTERM quits as the Quit button does
    child.kill("SIGTERM");
    const timer = setTimeout(() => child.kill("SIGKILL"), 5000);
    await ended;
    clearTimeout(timer);
  };
  try {
    await until("the control socket", 30, () => control("ui.state"));
  } catch (error) {
    await quit();
    throw error;
  }
  return { control, endpoint, quit, state: () => control("ui.state") };
}

const scenarios = {
  /** The app starts, answers, and its panel opens under the mark in the menu bar. */
  async boot({ app, home }) {
    const run = await start(app, home);
    try {
      const state = await run.state();
      if (realpathSync(state.home) !== realpathSync(home)) throw new Error(`the app's home is ${state.home}`);
      if (state.lend.phase !== "idle") throw new Error(`a home of its own lends nothing, and the lend is ${state.lend.phase}`);
      await run.control("ui.press", { id: "statusItem" });
      await until("the panel", 10, async () => (await run.state()).panel.visible);
      const tree = await run.control("ui.tree");
      const ids = new Set([...nodes(tree)].map((node) => node.id).filter(Boolean));
      // the mark says it is a test copy: the owner never quits the installed app for it
      const mark = [...nodes(tree)].find((node) => node.id === "statusItem");
      if (!mark?.label?.startsWith("iterate test copy:")) throw new Error(`the mark's label is ${JSON.stringify(mark?.label)}`);
      for (const id of ["statusItem", "panel.quit", "panel.copyPrompt", "sharing.commands", "record.screens"])
        if (!ids.has(id)) throw new Error(`ui.tree has no ${id}`);
      // a segment of a sharing control, pressed by its label
      await run.control("ui.press", { id: "sharing.speaker", label: "Shared" });
      await until("the speakers shared", 5, async () => (await run.state()).sharing.speaker === "shared");
    } finally {
      await run.quit();
    }
  },

  /** A text typed into the input bar goes to the mind as one event. */
  async "input-send"({ app, home }) {
    const sent = withMind(home);
    const run = await start(app, home);
    const text = "Open the roadmap and tell Misha why";
    try {
      await run.control("input.toggle");
      await until("the input bar", 10, async () => (await run.state()).input.visible);
      await run.control("ui.type", { id: "input.text", text });
      await until("the text in the bar", 5, async () => (await run.state()).input.text === text);
      await run.control("ui.press", { id: "input.send" });
      const event = await until("the event in the fake mind", 30, () => sent().find((event) => event.type === "device/input-submitted"));
      if (event.path !== `/devices/${NAME}` || event.payload.text !== text) throw new Error(`the mind got ${JSON.stringify(event)}`);
      const line = await until("the bar's last line", 10, async () => (await run.state()).input.lastLine);
      if (!line.startsWith(`Sent to ${MIND}`)) throw new Error(`the bar says ${line}`);
    } finally {
      await run.quit();
    }
  },

  /** A spoken sentence, from a file in place of the microphone, written with the mind's word list. */
  "dictation-fixture": {
    local: "needs the speech model in ~/Library/Application Support/FluidAudio (about 480 MB) and `say`",
    async run({ app, home }) {
      withMind(home);
      const sentence = "Herdr runs on the Beelink with Doppler";
      const fixture = join(home, "fixture.aiff");
      // `say -o` writes a file and plays nothing
      execFileSync("say", ["-o", fixture, sentence]);
      mkdirSync(join(home, "words"), { recursive: true });
      writeFileSync(join(home, "words", `${MIND}.md`), "- Herdr: herder, hurdur, her dr\n- Beelink: bee link, b link\n- Doppler: dopler\n");
      const run = await start(app, home, { ITERATE_MAC_AUDIO_FIXTURE: fixture });
      try {
        await run.control("dictation.start");
        await until("the dictation", 10, async () => (await run.state()).dictation.running);
        // the model loads, the file plays at the clock's pace, then a pause ends the stretch
        await until("the words in the pill", 240, async () => /doppler/i.test((await run.state()).dictation.text));
        await run.control("dictation.stop");
        const said = await until("the dictation's text", 60, async () => (await run.state()).dictation.lastText);
        for (const term of ["Herdr", "Beelink", "Doppler"]) if (!said.includes(term)) throw new Error(`"${said}" has no ${term}`);
      } finally {
        await run.quit();
      }
    },
  },

  /**
   * An act is two events on the device's context, and the log shows it once: the row made at
   * once, then the same row as the context echoes it.
   */
  async activity({ app, home }) {
    const sent = withMind(home);
    execFileSync("defaults", ["write", join(home, "defaults"), "sharing.commands", "shared"]);
    const run = await start(app, home);
    try {
      await until("the session", 10, async () => (await run.state()).session);
      await run.endpoint("run", { argv: ["/bin/echo", "an act"] });
      const started = await until("device/act-started in the fake mind", 30, () => sent().find((e) => e.type === "device/act-started"));
      const { act } = started.payload;
      if (started.path !== `/devices/${NAME}` || started.payload.thing !== "commands" || started.payload.doing !== "Running a command")
        throw new Error(`the mind got ${JSON.stringify(started)}`);
      if (started.idempotencyKey !== `device/act-started/${act}`) throw new Error(`the key is ${started.idempotencyKey}`);
      const ended = await until("device/act-ended in the fake mind", 30, () => sent().find((e) => e.type === "device/act-ended"));
      if (ended.payload.act !== act || ended.payload.did !== "Ran a command" || "failure" in ended.payload)
        throw new Error(`the mind got ${JSON.stringify(ended)}`);
      const activity = await until("the row in the mind", 30, async () => {
        const activity = (await run.state()).activity;
        return activity.entries.some((row) => row.act === act && row.inMind) && activity;
      });
      const rows = activity.entries.filter((row) => row.act === act);
      if (rows.length !== 1 || activity.entries.length !== 1 || rows[0].did !== "Ran a command" || rows[0].running)
        throw new Error(`the activity is ${JSON.stringify(activity.entries)}`);
      if (activity.context !== `/devices/${NAME}`) throw new Error(`the log's context is ${activity.context}`);
    } finally {
      await run.quit();
    }
  },

  /** A use whose choice is Ask waits for the answer: approved, it runs; denied, it is refused. */
  async approval({ app, home }) {
    execFileSync("defaults", ["write", join(home, "defaults"), "sharing.commands", "ask"]);
    const run = await start(app, home);
    try {
      if ((await run.state()).sharing.commands !== "ask") throw new Error("commands are not on Ask");
      for (const allow of [true, false]) {
        const asked = run.endpoint("run", { argv: ["/bin/echo", "approved"] }).then(
          (answer) => ({ answer }),
          (error) => ({ error }),
        );
        const state = await until("the question", 10, async () => (await run.state()).approval);
        if (!/run commands/.test(state.question)) throw new Error(`the question is ${state.question}`);
        await run.control("approval.answer", { allow });
        const { answer, error } = await asked;
        if (allow) {
          if (error) throw error;
          const out = Buffer.from(answer.stdoutBase64, "base64").toString();
          if (out.trim() !== "approved") throw new Error(`the command wrote ${JSON.stringify(out)}`);
        } else if (!/denied/.test(error?.message ?? "")) {
          throw new Error(`a denied use answered ${JSON.stringify(answer ?? error?.message)}`);
        }
      }
      const acts = (await run.state()).activity.entries;
      if (acts.length !== 1 || acts[0].did !== "Ran a command") throw new Error(`the activity is ${JSON.stringify(acts)}`);
    } finally {
      await run.quit();
    }
  },

  /**
   * Another mind ends the first one's authority: an approval for 30 minutes given while lent to A
   * holds for A, and a request after the switch to B asks again; no device event reaches A after
   * the switch, and B gets them.
   */
  async "mind-switch"({ app, home }) {
    const [A, B] = [
      { mind: "a.example.com", name: "harness.mac" },
      { mind: "b.example.com", name: "harness-b.mac" },
    ];
    const sent = withMind(home, [A, B]);
    execFileSync("defaults", ["write", join(home, "defaults"), "sharing.commands", "ask"]);
    const run = await start(app, home);
    const echo = () =>
      run.endpoint("run", { argv: ["/bin/echo", "ran"] }).then(
        (answer) => ({ answer }),
        (error) => ({ error }),
      );
    try {
      const first = await until("the session for A", 10, async () => (await run.state()).session);
      if (first.mind !== A.mind) throw new Error(`the session is ${JSON.stringify(first)}`);
      await until("A's presence", 30, () => sent().find((e) => e.mind === A.mind && e.type === "device/presence-changed"));

      // A: approved for 30 minutes, then a second use runs with no question
      const asked = echo();
      await until("A's question", 10, async () => (await run.state()).approval);
      await run.control("approval.answer", { allow: true, keep: true });
      if ((await asked).error) throw (await asked).error;
      const again = await Promise.race([echo(), new Promise((resolve) => setTimeout(() => resolve({ timedOut: true }), 5000))]);
      if (again.timedOut || again.error) throw new Error(`A's second use did not run on the approval: ${again.error?.message ?? "it waits"}`);

      // the CLI's `use b.example.com`: config.json, replaced
      writeConfig(home, join(home, "fake-iterate"), [A, B], B.mind);
      const second = await until("the session for B", 10, async () => {
        const session = (await run.state()).session;
        return session?.mind === B.mind && session;
      });
      if (second.generation <= first.generation) throw new Error(`B's generation is ${second.generation}, A's ${first.generation}`);
      const toA = sent().filter((e) => e.mind === A.mind).length;

      // B: the approval for A does not hold
      const fromB = echo();
      const state = await until("B's question", 10, async () => (await run.state()).approval);
      if (!/run commands/.test(state.question)) throw new Error(`the question is ${state.question}`);
      await run.control("approval.answer", { allow: false });
      if (!/denied/.test((await fromB).error?.message ?? "")) throw new Error(`B's use answered ${JSON.stringify((await fromB).answer)}`);

      const atB = await until("B's presence", 30, () => sent().find((e) => e.mind === B.mind && e.type === "device/presence-changed"));
      if (atB.path !== `/devices/${B.name}`) throw new Error(`B's event went to ${atB.path}`);
      // past the old 2 s check, when the old code still wrote to A's publisher
      await new Promise((resolve) => setTimeout(resolve, 3000));
      const late = sent().filter((e) => e.mind === A.mind).slice(toA);
      if (late.length) throw new Error(`A got ${late.length} events after the switch: ${late.map((e) => e.type).join(", ")}`);
    } finally {
      await run.quit();
    }
  },
};

async function main() {
  const { positionals, values } = parseArgs({
    allowPositionals: true,
    options: { app: { type: "string", default: join(root, ".build/debug/VoiceMeetMac") }, keep: { type: "boolean" } },
  });
  const wanted = positionals[0];
  const all = Object.entries(scenarios).map(([name, scenario]) =>
    typeof scenario === "function" ? { name, run: scenario } : { name, ...scenario },
  );
  const chosen = wanted === "all" ? all : wanted === "ci" ? all.filter((s) => !s.local) : all.filter((s) => s.name === wanted);
  if (!chosen.length) {
    console.error(`node harness/run.mjs <${all.map((s) => s.name).join("|")}|ci|all> [--app <path>] [--keep]`);
    process.exit(2);
  }
  if (!existsSync(values.app)) throw new Error(`no app at ${values.app}: run swift build first`);
  let failed = 0;
  for (const scenario of chosen) {
    // a short folder: a Unix socket's path has at most 103 bytes
    const home = mkdtempSync(join(tmpdir(), "itx-"));
    const started = Date.now();
    const result = { scenario: scenario.name };
    try {
      await scenario.run({ app: values.app, home });
      result.ok = true;
    } catch (error) {
      failed++;
      result.ok = false;
      result.error = error.message;
    } finally {
      killAll();
    }
    result.seconds = Math.round((Date.now() - started) / 100) / 10;
    const log = join(home, "logs/app.log");
    if (!result.ok && existsSync(log)) result.log = readFileSync(log, "utf8").trim().split("\n").slice(-15);
    if (values.keep || !result.ok) result.home = home;
    else rmSync(home, { recursive: true, force: true });
    console.log(JSON.stringify(result));
  }
  process.exit(failed ? 1 : 0);
}

await main();
