#!/usr/bin/env node
// run.mjs: the app, started and driven with no hand, in a home of its own (README, "Testing with
// no hand").
//
//   node harness/run.mjs <scenario|ci|all> [--app .build/debug/VoiceMeetMac] [--keep] [--on-screen]
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
// A copy shows nothing to the person at the Mac (Sources/VoiceMeetMac/OffScreen.swift): while a
// scenario runs, the window server's list is read every 200 ms (harness/on-screen.js), and the
// scenario fails when a window of a copy shows on a display, a copy is the active app, or
// `ui.state` has a window of it that is key. `--on-screen` starts the copies with that flag: they
// show themselves as the installed app does, and each scenario fails on what it showed.
import { execFile, execFileSync, spawn } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { createConnection } from "node:net";
import { homedir, tmpdir } from "node:os";
import { dirname, join } from "node:path";
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

/** The config of a home with these minds, the first active, as the CLI writes it: by a rename. Its
 *  `cli` is this checkout's cli.mjs, which Settings runs (`set`), and it has a key at the top and
 *  one in each mind that no version knows: `set` must keep them. */
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
      cli: join(root, "cli.mjs"),
      harnessUnknown: "kept",
      minds: minds.map(({ mind, name }) => ({ mind, name, keyFile: join(home, "keys", `${mind}.key`), harnessUnknown: "kept" })),
      active,
    }),
  );
  renameSync(`${file}.new`, file);
}

/**
 * A home with config.json, whose iterate CLI is the fake mind: what it is sent is in `mind.jsonl`,
 * each event with the mind (`mind`) and the path it reached, and each file it stored as
 * `{ file, bytes, via }`. Every mind is the same fake mind; `words` is its word list (words.md),
 * and `seed` the events its context `/devices/<NAME>` holds before the app connects (as an earlier
 * run of the app left them).
 */
/** The word list of the speech fixtures: the owner's forms of Beelink (25 November 2026) among them. */
const WORDS = "- Herdr: herder, hurdur, her dr\n- Beelink: b-link, be link, bee link, b link\n- Doppler: dopler\n";
/** Oruk Fourier's files, as the app finds them (`FourierRuntime`): `ready.json` says they are all there. */
const FOURIER = process.env.ITERATE_MAC_FOURIER_FOLDER || join(homedir(), "Library/Application Support/iterate-speech/oruk-fourier-2b");
const hasFourier = () => existsSync(join(FOURIER, "ready.json"));
/** A heard form of Beelink, with any separator (`WordList.separators`). */
const WRONG_BEELINK = /(?<![\p{L}\p{N}])(?:b|be|bee)[\s\-\u2010-\u2015\u2212_]+link(?![\p{L}\p{N}])/iu;

function withMind(home, minds = [{ mind: MIND, name: NAME }], { words, seed } = {}) {
  const iterate = join(home, "fake-iterate");
  mkdirSync(join(iterate, "bin"), { recursive: true });
  mkdirSync(join(iterate, "dist"), { recursive: true });
  // the bridges import ../dist/node.mjs beside this file; `provide` (a copy started with --lend)
  // says the state in provide.json beside it, and stays (live) or ends (exit) as it says
  writeFileSync(
    join(iterate, "bin/iterate.js"),
    `import { existsSync, readFileSync } from "node:fs";
if (process.argv[2] === "provide") {
  const file = ${JSON.stringify(join(iterate, "provide.json"))};
  const { exit, ...state } = existsSync(file) ? JSON.parse(readFileSync(file, "utf8")) : { state: "live", again: false };
  const at = process.argv.indexOf("--mind"), named = process.argv.indexOf("--name");
  console.log(JSON.stringify({ mind: process.argv[at + 1], name: process.argv[named + 1], ...state }));
  if (exit !== undefined) process.exit(exit);
  setInterval(() => {}, 1 << 30);
}
`,
  );
  writeFileSync(join(iterate, "seed.json"), JSON.stringify(seed ?? []));
  if (words) {
    // the mind's list, and the copy the app keeps of it: dictation has it from the start
    writeFileSync(join(iterate, "words.md"), words);
    mkdirSync(join(home, "words"), { recursive: true });
    for (const { mind } of minds) writeFileSync(join(home, "words", `${mind}.md`), words);
  }
  // the bridges' own fake mind; each append is kept in a file the scenario reads
  writeFileSync(
    join(iterate, "dist/node.mjs"),
    `import { appendFileSync, existsSync, readFileSync } from "node:fs";
import { fakeMind } from ${JSON.stringify(join(root, "bridge/fake-mind.test-helper.mjs"))};
const mind = fakeMind({
  stored: (key, file) => appendFileSync(${JSON.stringify(join(home, "mind.jsonl"))}, JSON.stringify({ file: key, bytes: file.bytes.length, via: file.via }) + "\\n"),
});
const words = ${JSON.stringify(join(iterate, "words.md"))};
if (existsSync(words)) mind.repo.files["words.md"] = readFileSync(words, "utf8");
const seed = JSON.parse(readFileSync(${JSON.stringify(join(iterate, "seed.json"))}, "utf8"));
if (seed.length) await (await mind.connect()).itx.cd(${JSON.stringify(`/devices/${NAME}`)}).append(...seed);
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

/** Arguments of every copy: `--on-screen` when the harness has it. */
const copyArgs = [];

/** What the person at the Mac saw of the copies while the scenario ran: one line each. */
let sightings = [];
const seen = new Set();

function saw(what) {
  if (seen.has(what)) return;
  seen.add(what);
  sightings.push(what);
}

/** Reads the window server's list every 200 ms until `stop()`, for the copies that run. */
function watchScreens() {
  let stopped = false;
  const look = () => {
    const pids = [...running].map((child) => child.pid).filter(Boolean);
    if (stopped) return;
    if (!pids.length) return void setTimeout(look, 200);
    execFile("/usr/bin/osascript", ["-l", "JavaScript", join(root, "harness/on-screen.js"), ...pids.map(String)], { timeout: 10000 }, (error, stdout) => {
      // osascript may end with no error and no output (a busy window server): no look this time
      const seenNow = error ? null : (() => { try { return JSON.parse(stdout); } catch { return null; } })();
      if (seenNow) {
        const { windows, front } = seenNow;
        for (const w of windows)
          saw(`window ${w.number} "${w.name}" (layer ${w.layer}, alpha ${w.alpha}) at ${w.frame.X},${w.frame.Y} ${w.frame.Width}×${w.frame.Height}`);
        if (front) saw(`the copy (pid ${front}) is the active app`);
      }
      if (!stopped) setTimeout(look, 200);
    });
  };
  look();
  return () => (stopped = true);
}

/** The app in `home`, until `quit`. */
async function start(app, home, env = {}, args = []) {
  const child = spawn(app, ["--home", home, ...copyArgs, ...args], { env: { ...process.env, ...env }, stdio: ["ignore", "ignore", "ignore"] });
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
  const state = async () => {
    const answer = await control("ui.state");
    for (const window of answer.windows ?? []) if (window.key) saw(`its ${window.kind} "${window.title}" is key`);
    return answer;
  };
  return { control, endpoint, quit, pid: child.pid, state };
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/**
 * Waits until the copy's start is over: a second with at most 5 wake-ups, at most 30 s. macOS
 * starts an AppKit app with work of its own on the main thread, which no code of the app asks
 * for: on a GitHub runner (macOS 15 in a virtual machine) about 60 wake-ups a second for its
 * first 8 to 10 s, in AppKit alone too (harness/launch-baseline.swift, 25 Nov 2026); on a Mac
 * none. An idle window that starts in those seconds measures macOS, not the app. The answer is
 * the seconds waited.
 */
async function settled(run) {
  const started = Date.now();
  let last = (await run.state()).perf;
  while (Date.now() - started < 30000) {
    await sleep(1000);
    const now = (await run.state()).perf;
    if (now.interruptWakeups - last.interruptWakeups <= 5) break;
    last = now;
  }
  return Math.round((Date.now() - started) / 100) / 10;
}

/** What changed in `perf` (ui.state) from `a` to `b`: the CPU, the wake-ups and the counters. */
function perfDelta(a, b) {
  const counters = {};
  for (const [name, n] of Object.entries(b.counters ?? {})) counters[name] = n - (a.counters?.[name] ?? 0);
  return {
    cpuMs: Math.round((b.cpuSeconds - a.cpuSeconds) * 1000),
    idleWakeups: b.idleWakeups - a.idleWakeups,
    interruptWakeups: b.interruptWakeups - a.interruptWakeups,
    rssMB: Math.round(b.rss / 1e5) / 10,
    openFiles: b.openFiles,
    threads: b.threads,
    counters,
  };
}

/** Throws when a figure is over its limit, with every figure in the message. */
function overLimits(figures, limits) {
  return Object.entries(limits).filter(([name, limit]) => (figures[name] ?? figures.counters?.[name] ?? 0) > limit);
}

/** Where the app's threads spend `seconds` (`sample`), for a failed idle check: the call graph, cut. */
function sampleOf(pid, home, seconds) {
  const file = join(home, "idle.sample.txt");
  try {
    execFileSync("/usr/bin/sample", [String(pid), String(seconds), "-mayDie", "-file", file], { stdio: "ignore", timeout: 60000 });
    const text = readFileSync(file, "utf8");
    const graph = text.slice(text.indexOf("Call graph:"), text.indexOf("Total number in stack"));
    const log = readFileSync(join(home, "logs/app.log"), "utf8").trim().split("\n").slice(-60).join("\n");
    return `--- sample of the idle app (pid ${pid}) ---\n${graph.split("\n").slice(0, 1500).join("\n")}\n--- its log ---\n${log}\n--- end of sample ---\n`;
  } catch (error) {
    return `--- no sample: ${error.message} ---\n`;
  }
}

/** A copy's figures each second for its first 30 s, and its log: when a start's cost begins and ends. */
async function launchSeries(app, minds, args) {
  const home = mkdtempSync(join(tmpdir(), "itx-"));
  withMind(home, minds);
  const t0 = Date.now();
  const run = await start(app, home, {}, args);
  const lines = [];
  let runLoop = "";
  try {
    let last = (await run.state()).perf;
    let threads = new Map();
    while (Date.now() - t0 < 30000) {
      await sleep(1000);
      const state = await run.state();
      const d = perfDelta(last, state.perf);
      last = state.perf;
      // each thread that worked in the second, by its name (or its id), and its milliseconds
      const answer = await run.control("perf.threads");
      const now = new Map((answer.threads ?? []).map((t) => [t.id, t]));
      // the main run loop's timers in the third second: what wakes the main thread then
      if (lines.length === 2) {
        const timers = new Map();
        for (const line of (answer.mainRunLoop ?? "").split("\n")) {
          const timer = line.match(/<CFRunLoopTimer (0x[0-9a-f]+)/);
          if (timer) timers.set(timer[1], line.replace(/^.*?\{/, "").replace(/, context = .*$/, "").slice(0, 300));
        }
        runLoop = [...timers.values()].join("\n");
      }
      const worked = [...now.values()]
        .map((t) => [t.name || `#${t.id}`, t.cpuMs - (threads.get(t.id)?.cpuMs ?? 0), !threads.has(t.id)])
        .filter(([, ms, isNew]) => ms >= 0.5 || isNew)
        .map(([name, ms, isNew]) => `${isNew ? "+" : ""}${name}:${ms.toFixed(1)}`);
      const gone = [...threads.values()].filter((t) => !now.has(t.id)).map((t) => `-${t.name || `#${t.id}`}`);
      threads = now;
      lines.push(`${((Date.now() - t0) / 1000).toFixed(1)}s ${state.lend.phase} ${d.cpuMs}ms ${d.interruptWakeups}w ${d.idleWakeups}i th${state.perf.threads} fd${state.perf.openFiles} ${JSON.stringify(Object.fromEntries(Object.entries(d.counters).filter(([, n]) => n)))} ${[...worked, ...gone].join(" ")}`);
    }
  } finally {
    await run.quit();
  }
  const log = readFileSync(join(home, "logs/app.log"), "utf8").trim().split("\n").slice(-80).join("\n");
  return `--- the start of a copy (${args.join(" ") || "no lend"}), from ${new Date(t0).toISOString()} ---\n${lines.join("\n")}\n--- its main run loop in the third second ---\n${runLoop}\n--- its log ---\n${log}\n${systemLog(run.pid, t0)}--- end ---\n`;
}

/** The same seconds of a start of AppKit with nothing of the app (harness/launch-baseline.swift):
 * whether a cost of the start is the app's or every app's on this Mac. */
function launchBaseline(home) {
  const binary = join(home, "launch-baseline");
  try {
    execFileSync("swiftc", ["-O", "-o", binary, join(root, "harness/launch-baseline.swift")], { stdio: "ignore", timeout: 300000 });
    const lines = ["plain", "status", "swiftui"].map((variant) => execFileSync(binary, [variant], { encoding: "utf8", timeout: 60000 }).trim());
    return `--- a start of AppKit alone, each second ---\n${lines.join("\n")}\n--- end ---\n`;
  } catch (error) {
    return `--- no start of AppKit alone: ${error.message} ---\n`;
  }
}

/** What macOS's own log has of process `pid` from `t0`: its lines each second, by subsystem in
 * the first 12 s, and the lines of its fifth second. */
function systemLog(pid, t0) {
  let text;
  try {
    text = execFileSync("/usr/bin/log", ["show", "--predicate", `processID == ${pid}`, "--last", "2m", "--style", "compact", "--info", "--debug"], { encoding: "utf8", maxBuffer: 64 << 20, timeout: 60000 });
  } catch (error) {
    return `--- no system log: ${error.message} ---\n`;
  }
  const perSecond = {}, kinds = {}, fifth = [];
  for (const line of text.split("\n")) {
    const at = line.match(/^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{3})/);
    if (!at) continue;
    const second = Math.floor((new Date(at[1].replace(" ", "T")).getTime() - t0) / 1000);
    perSecond[second] = (perSecond[second] ?? 0) + 1;
    const kind = line.match(/\] (\[[^\]]+\]|\([^)]+\))/)?.[1] ?? "?";
    if (second >= 2 && second < 12) kinds[kind] = (kinds[kind] ?? 0) + 1;
    if (second === 4 && fifth.length < 150) fifth.push(line.slice(0, 260));
  }
  const top = Object.entries(kinds).sort((a, b) => b[1] - a[1]).slice(0, 25).map(([k, n]) => `${n} ${k}`);
  return `--- the system log: lines each second ---\n${JSON.stringify(perSecond)}\n--- by subsystem, seconds 2 to 12 ---\n${top.join("\n")}\n--- second 4 ---\n${fifth.join("\n")}\n`;
}

function within(what, figures, limits) {
  const over = overLimits(figures, limits);
  if (over.length) throw new Error(`${what}: ${over.map(([name, limit]) => `${name} ${figures[name] ?? figures.counters?.[name]} > ${limit}`).join(", ")}; ${JSON.stringify(figures)}`);
}

/** The limits of the idle scenarios, over their windows: what an idle copy may cost. */
// Measured on 25 Nov 2026 (M-series, debug build), 20 s live: 41 ms and 47 wake-ups before the
// fixes (a ticker each second, the window's title each second, presence and the record each 2 s),
// 15 ms and 7 after. 10 s refused: 10 state changes and 10 writes of the mark before, 0 after.
const IDLE_LIMITS = { cpuMs: 35, interruptWakeups: 20, stateChanges: 0, statusWrites: 0, panelBodies: 0, presenceLooks: 1, recordLooks: 0 };
const REFUSED_LIMITS = { interruptWakeups: 12, stateChanges: 0, statusWrites: 0, panelBodies: 0, lendTicks: 0 };
// 5 s open, a countdown showing: 10 bodies of the panel and 5 state changes before, 0 and 0 after
// (the countdown's own row is drawn each second: `lendTicks`).
const PANEL_LIMITS = { panelBodies: 1, stateChanges: 0, lendTicks: 6 };

const scenarios = {
  /**
   * What a copy costs while nothing happens: lent to the fake mind (live), every switch off, the
   * panel closed, 20 s. Then a lend the mind refuses (its next try in 5 minutes), 10 s: nothing
   * changes, so the mark and the panel are not touched. The figures are in the result (`perf`);
   * the main queue's longest delay is read over 3 s with its watch on.
   */
  async idle({ app, home }) {
    const A = { mind: MIND, name: NAME }, B = { mind: "other.example.com", name: NAME };
    withMind(home, [A, B]);
    const run = await start(app, home, {}, ["--lend"]);
    try {
      await until("the lend live", 20, async () => (await run.state()).lend.phase === "live");
      await until("the session", 10, async () => (await run.state()).session);
      // the start's own work ends: the bridges, the word lists, and macOS's start of the app
      await sleep(4000);
      const settleSeconds = await settled(run);
      await run.control("perf.reset");
      const before = (await run.state()).perf;
      await sleep(20000);
      const live = perfDelta(before, (await run.state()).perf);
      // over a limit: 10 s more in steps of 2 s (does the cost stay?) and where the threads are.
      // Each `ui.state` costs some milliseconds itself, so the steps are not in the window above.
      const series = [];
      let liveSample = "";
      if (overLimits(live, IDLE_LIMITS).length) {
        let step = (await run.state()).perf;
        for (let i = 0; i < 5; i++) {
          await sleep(2000);
          const now = (await run.state()).perf;
          const d = perfDelta(step, now);
          series.push(`${d.cpuMs}ms/${d.interruptWakeups}w${Object.keys(d.counters).length ? " " + JSON.stringify(d.counters) : ""}`);
          step = now;
        }
        liveSample = sampleOf(run.pid, home, 3);
        // the cost may be the start's and over by now: two more copies, with the lend and
        // without, their figures each second from the start beside their logs
        for (const args of [["--lend"], []]) liveSample += await launchSeries(app, [A, B], args);
        liveSample += launchBaseline(home);
      }

      // a refused key: provide says so and ends; the next try is in 5 minutes
      writeFileSync(join(home, "fake-iterate/provide.json"), JSON.stringify({ state: "notAllowed", why: "No member has allowed this key yet.", waiting: false, exit: 1 }));
      writeConfig(home, join(home, "fake-iterate"), [A, B], B.mind);
      await until("the lend refused", 20, async () => (await run.state()).lend.phase === "not allowed");
      await sleep(2000);
      await run.control("perf.reset");
      const refusedBefore = (await run.state()).perf;
      await sleep(10000);
      const refused = perfDelta(refusedBefore, (await run.state()).perf);

      await run.control("perf.reset", { watchMain: true });
      await sleep(3000);
      const stall = (await run.state()).perf.mainStallMaxMs;
      await run.control("perf.reset", { watchMain: false });
      const result = { live, refused, mainStallMaxMs: stall, settleSeconds, series };
      try {
        within("idle, live", live, IDLE_LIMITS);
        within("idle, refused", refused, REFUSED_LIMITS);
        if (stall > 100) throw new Error(`the main queue waited ${stall} ms while idle`);
      } catch (error) {
        if (liveSample) process.stderr.write(liveSample);
        throw new Error(`${error.message.split(";")[0]}; ${JSON.stringify(result)}`);
      }
      return result;
    } finally {
      await run.quit();
    }
  },

  /**
   * The panel open for 5 s while the lend waits for its next try (a countdown shows): the panel's
   * body is drawn once at most, the countdown's own row ticks, and nothing else changes.
   */
  async "panel-open"({ app, home }) {
    withMind(home);
    writeFileSync(join(home, "fake-iterate/provide.json"), JSON.stringify({ state: "notAllowed", why: "No member has allowed this key yet.", waiting: false, exit: 1 }));
    const run = await start(app, home, {}, ["--lend"]);
    try {
      await until("the lend refused", 20, async () => (await run.state()).lend.phase === "not allowed");
      await run.control("ui.press", { id: "statusItem" });
      await until("the panel", 10, async () => (await run.state()).panel.visible);
      // the open restarts a refused lend: it is refused again
      await until("the lend refused again", 20, async () => (await run.state()).lend.phase === "not allowed");
      await sleep(1500);
      await settled(run);
      await run.control("perf.reset", { watchMain: true });
      const before = (await run.state()).perf;
      await sleep(5000);
      const after = (await run.state()).perf;
      await run.control("perf.reset", { watchMain: false });
      const open = { ...perfDelta(before, after), mainStallMaxMs: after.mainStallMaxMs };
      within("panel open", open, PANEL_LIMITS);
      if (!(open.counters.lendTicks >= 3)) throw new Error(`the countdown did not tick: ${JSON.stringify(open)}`);
      return { open };
    } finally {
      await run.quit();
    }
  },

  /**
   * The app starts, answers, and its panel opens under the mark in the menu bar. The home has a
   * mind (the panel shows the choices only then), and lends nothing without --lend.
   */
  async boot({ app, home }) {
    withMind(home);
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
      for (const id of ["statusItem", "panel.quit", "panel.copyPrompt", "panel.settings", "sharing.commands", "record.screens"])
        if (!ids.has(id)) throw new Error(`ui.tree has no ${id}`);
      // the panel's Settings button, then Settings › Dictation, with every model of the app
      await run.control("ui.press", { id: "panel.settings" });
      await until("the Settings window", 10, async () => (await run.state()).settings.visible);
      await run.control("ui.press", { id: "settings.page.dictation" });
      await until("the list of speech models", 5, async () => {
        const open = new Set([...nodes(await run.control("ui.tree"))].map((node) => node.id));
        return open.has("speech.model.parakeet-v3") && open.has("speech.model.parakeet-ultra");
      });
      // a segment of a sharing control, pressed by its label (the panel again: Settings took it away)
      if (!(await run.state()).panel.visible) await run.control("ui.press", { id: "statusItem" });
      await until("the panel again", 10, async () => (await run.state()).panel.visible);
      await run.control("ui.press", { id: "sharing.speaker", label: "Shared" });
      await until("the speakers shared", 5, async () => (await run.state()).sharing.speaker === "shared");
    } finally {
      await run.quit();
    }
  },

  /**
   * Settings opens from the panel's button, with This Mac's pages and one for each mind. A changed
   * choice is in the home's defaults (`approval.minutes`), and a value of config.json goes through
   * `cli.mjs set`, which keeps the keys it does not know. A mind's own word-list expression runs at
   * once in the mind's process, and its answer is the app's copy of the list.
   */
  async settings({ app, home }) {
    withMind(home);
    const run = await start(app, home);
    const ids = async () => new Set([...nodes(await run.control("ui.tree"))].map((node) => node.id).filter(Boolean));
    const config = () => JSON.parse(readFileSync(join(home, "config.json"), "utf8"));
    try {
      await run.control("ui.press", { id: "statusItem" });
      await until("the panel", 10, async () => (await run.state()).panel.visible);
      await run.control("ui.press", { id: "panel.settings" });
      await until("the Settings window", 10, async () => (await run.state()).settings.visible);
      await until("the sidebar", 5, async () => {
        const shown = await ids();
        return ["settings.page.general", "settings.page.dictation", `settings.page.mind.${MIND}`, "settings.addMind", "settings.approvalMinutes"].every((id) => shown.has(id));
      });
      if ((await run.state()).settings.page !== "general") throw new Error(`Settings opened on ${(await run.state()).settings.page}`);

      // An approval can last: 60 minutes, kept in the home's defaults
      await run.control("ui.press", { id: "settings.approvalMinutes", label: "1 hour" });
      await until("approval.minutes at 60", 5, async () => (await run.state()).choices.approvalMinutes === 60);
      const stored = execFileSync("defaults", ["read", join(home, "defaults"), "approval.minutes"], { encoding: "utf8" }).trim();
      if (stored !== "60") throw new Error(`the stored approval.minutes is ${stored}`);

      // Open at login: config.json's `login`, written by cli.mjs set, with the unknown keys kept
      await run.control("ui.press", { id: "settings.login" });
      await until("login in config.json", 15, () => config().login === true);
      const written = config();
      if (written.harnessUnknown !== "kept" || written.minds[0].harnessUnknown !== "kept")
        throw new Error(`cli.mjs set dropped a key it does not know: ${JSON.stringify(written)}`);

      // a mind's page, and its own word-list expression through cli.mjs set
      await run.control("ui.press", { id: `settings.page.mind.${MIND}` });
      await until("the mind's page", 5, async () => (await run.state()).settings.page === `mind:${MIND}` && (await ids()).has("settings.mind.wordsSource"));
      await run.control("ui.press", { id: "settings.mind.wordsSource", label: "Its own" });
      await until("the field of its own", 5, async () => (await ids()).has("settings.mind.expression"));
      // an expression of its own, with itx in scope: its answer is the list
      const own = 'itx.repos.get("/repos/config").tip().then((tip) => `- Harness: ${tip}`)';
      await run.control("ui.type", { id: "settings.mind.expression", text: own, replace: true });
      await until("the Save button", 5, async () => (await ids()).has("settings.mind.expression.save"));
      await run.control("ui.press", { id: "settings.mind.expression.save" });
      await until("the mind's expression in config.json", 15, () => config().minds[0].wordsExpression);
      const mind = config().minds[0];
      if (mind.harnessUnknown !== "kept" || mind.wordsExpression !== own)
        throw new Error(`the mind's entry is ${JSON.stringify(mind)}`);
      // the new expression fetches the list at once, through the job words of the mind's process
      const copy = join(home, "words", `${MIND}.md`);
      await until("the list of its own expression", 15, () => existsSync(copy) && readFileSync(copy, "utf8") === "- Harness: abc");
    } finally {
      await run.quit();
    }
  },

  /** "All" shows the Activity page in place of the panel's middle, and its back button the main page again. */
  async "panel-pages"({ app, home }) {
    withMind(home);
    const run = await start(app, home);
    const ids = async () => new Set([...nodes(await run.control("ui.tree"))].map((node) => node.id).filter(Boolean));
    try {
      await run.control("ui.press", { id: "statusItem" });
      await until("the panel", 10, async () => (await run.state()).panel.visible);
      await until("the main page", 5, async () => {
        const shown = await ids();
        return shown.has("activity.all") && shown.has("sharing.commands") && !shown.has("activity.context");
      });
      await run.control("ui.press", { id: "activity.all" });
      await until("the Activity page", 5, async () => {
        const shown = await ids();
        return (await run.state()).panel.page === "activity" && shown.has("activity.back") && shown.has("activity.context") && shown.has("activity.showsPill") && !shown.has("sharing.commands");
      });
      await run.control("ui.press", { id: "activity.back" });
      await until("the main page again", 5, async () => {
        const shown = await ids();
        return (await run.state()).panel.page === "main" && shown.has("activity.all") && shown.has("record.screens") && !shown.has("activity.back");
      });
    } finally {
      await run.quit();
    }
  },

  /**
   * The Activity window on a context that holds mixed events: "Open in a Window" reads the newest
   * page of every kept type (no ephemeral key), a scroll to the end reads the page below, a new act
   * comes in as it happens, and the window's close lets go of every event.
   */
  async "log-window"({ app, home }) {
    const kinds = [
      (n) => ({ type: "device/app-focused", payload: { app: "Ghostty", title: `window ${n}` } }),
      (n) => ({ type: "device/presence-changed", payload: { state: n % 4 ? "active" : "idle", idleSeconds: 120 } }),
      (n) => ({ type: "device/window-read", payload: { app: "Ghostty", title: `window ${n}`, trigger: "click", text: "x".repeat(30_000) } }),
      (n) => ({ type: "record/slot-stored", payload: { t: 1764000000 + n * 30, tracks: { "mic-0": { kind: "audio" } } } }),
      (n) => ({ type: "device/key-pressed", payload: { key: "a", keyCode: 0, n } }),
      (n) => ({ type: "device/key-pressed", ephemeral: true, payload: { key: "b", keyCode: 11, n } }),
      (n) => ({ type: "device/live-watch-ended", payload: { watcher: "w1", who: "Misha", seconds: n, why: "the watcher left" } }),
      (n) => ({ type: "device/input-submitted", payload: { id: `i${n}`, text: `input ${n}`, at: "2026-11-24T14:00:00Z", files: [] } }),
    ];
    // 315 kept events and 45 ephemeral keys, which no log keeps
    const seed = Array.from({ length: 360 }, (_, n) => kinds[n % kinds.length](n));
    withMind(home, undefined, { seed });
    execFileSync("defaults", ["write", join(home, "defaults"), "sharing.commands", "shared"]);
    const run = await start(app, home);
    const log = async () => (await run.state()).log;
    try {
      await until("the session", 10, async () => (await run.state()).session);
      if ((await log()).held !== 0) throw new Error("the log is read before its window opens");
      await run.control("ui.press", { id: "statusItem" });
      await until("the panel", 10, async () => (await run.state()).panel.visible);
      await run.control("ui.press", { id: "activity.all" });
      await until("the Activity page's button", 5, async () => [...nodes(await run.control("ui.tree"))].some((node) => node.id === "activity.window"));
      await run.control("ui.press", { id: "activity.window" });
      const first = await until("the newest page", 30, async () => {
        const state = await log();
        // a page of 100, and the app's own events that came beside it
        return state.visible && state.read && state.held >= 100 && state.held < 110 && state.hasOlder && state;
      });
      const types = new Set(first.types);
      for (const type of ["device/app-focused", "device/presence-changed", "device/window-read", "record/slot-stored", "device/key-pressed", "device/input-submitted"])
        if (!types.has(type)) throw new Error(`the newest page has no ${type}: ${[...types].join(", ")}`);
      // keys and mouse are many: shown only when the person turns them on
      if (first.shown >= first.held) throw new Error(`the list shows ${first.shown} of ${first.held}, keys among them`);
      await run.control("ui.press", { id: "log.filter.keys" });
      await until("the keys shown", 5, async () => (await log()).shown === (await log()).held);

      // a scroll to the end of the list reads the page below
      await run.control("ui.scroll", { id: "log.list" });
      const near = (count) => async () => {
        const held = (await log()).held;
        return held >= count && held < count + 10;
      };
      await until("the second page", 15, near(200));
      await run.control("ui.scroll", { id: "log.list" });
      await until("the third page", 15, near(300));
      // the 315 seeded and the app's own events since it connected (its presence)
      let last;
      const all = await until("the start of the context", 15, async () => {
        await run.control("ui.scroll", { id: "log.list" });
        last = await log();
        return last.held >= 315 && last.held < 325 && !last.hasOlder && last;
      }).catch((error) => {
        throw new Error(`${error.message}; the log: ${JSON.stringify({ ...last, types: undefined })}`);
      });
      if (all.failure) throw new Error(`the log failed: ${all.failure}`);

      // an act of now comes in as it happens, through the subscription
      await run.endpoint("run", { argv: ["/bin/echo", "an act"] });
      await until("the act in the window", 30, async () => (await log()).types.slice(0, 4).includes("device/act-ended"));

      // the close lets go of the events and ends the read
      await run.control("ui.press", { id: "log.close" });
      await until("the window closed and its events gone", 10, async () => {
        const state = await log();
        return !state.visible && state.held === 0;
      });
    } finally {
      await run.quit();
    }
  },

  /**
   * A banner shown at once after the last one's button: the last one's fade does not take the new
   * one from the screen (Fable 10). Its buttons have ids (`banner.button.<n>`). No sound.
   */
  async banner({ app, home }) {
    withMind(home);
    execFileSync("defaults", ["write", join(home, "defaults"), "sharing.banners", "shared"]);
    const run = await start(app, home);
    const show = (title) => run.endpoint("banner.show", { title, body: "From the harness", buttons: [{ label: "OK" }], sound: "none", seconds: 30 });
    try {
      await until("the session", 10, async () => (await run.state()).session);
      const first = show("First");
      await until("the first banner", 10, async () => (await run.state()).banner?.title === "First");
      await run.control("ui.press", { id: "banner.button.0" });
      const answer = await first;
      if (answer.pressed !== "OK") throw new Error(`the first banner answered ${JSON.stringify(answer)}`);
      await sleep(50);
      const second = show("Second");
      // its call ends with the app when a step fails
      second.catch(() => {});
      await sleep(500);
      const state = await run.state();
      if (state.banner?.title !== "Second") throw new Error(`the banner is ${JSON.stringify(state.banner)}`);
      if (!state.windows.some((window) => window.kind === "KeyablePanel")) throw new Error(`the second banner is not on the screen: ${JSON.stringify(state.windows)}`);
      await run.control("ui.press", { id: "banner.button.0" });
      if ((await second).pressed !== "OK") throw new Error("the second banner's button did not answer");
    } finally {
      await run.quit();
    }
  },

  /**
   * The keys, as the keyboard sends them (`ui.key`): Tab in the input bar chooses the next mind and
   * ⇧Tab the one before (two minds with lists of their own); ⌘W closes the Add a Mind form, through
   * the app's one Edit and Window menu (Carbon 11).
   */
  async keys({ app, home }) {
    const A = { mind: MIND, name: NAME }, B = { mind: "other.example.com", name: NAME };
    withMind(home, [A, B]);
    mkdirSync(join(home, "words"), { recursive: true });
    writeFileSync(join(home, "words", `${A.mind}.md`), "- Herdr: herder\n");
    writeFileSync(join(home, "words", `${B.mind}.md`), "- Beelink: bee link\n");
    const run = await start(app, home);
    const input = async () => (await run.state()).input;
    try {
      await run.control("input.toggle");
      await until("the input bar", 10, async () => (await input()).visible);
      const first = (await input()).mind;
      const other = first === A.mind ? B.mind : A.mind;
      await run.control("ui.key", { key: "tab" });
      await until(`Tab to ${other}`, 5, async () => (await input()).mind === other);
      await run.control("ui.key", { key: "tab", shift: true });
      await until(`⇧Tab back to ${first}`, 5, async () => (await input()).mind === first);
      await run.control("ui.key", { key: "escape" });
      await until("the bar closed by Esc", 5, async () => !(await input()).visible);

      // ⌘W closes a form, which has no key handling of its own
      await run.control("ui.press", { id: "statusItem" });
      await until("the panel", 10, async () => (await run.state()).panel.visible);
      await run.control("ui.press", { id: "panel.settings" });
      await until("the Settings window", 10, async () => (await run.state()).settings.visible);
      await until("Add a Mind", 5, async () => [...nodes(await run.control("ui.tree"))].some((node) => node.id === "settings.addMind"));
      await run.control("ui.press", { id: "settings.addMind" });
      const form = () => run.state().then((state) => state.windows.find((window) => window.title === "Add a Mind"));
      await until("the form", 10, async () => await form());
      await run.control("ui.key", { key: "w", command: true });
      await until("the form closed by ⌘W", 5, async () => !(await form()));
    } finally {
      await run.quit();
    }
  },

  /** A log of 25 MB from an earlier run is set aside at the start, and a new one begins (Fable 16). */
  async "log-bound"({ app, home }) {
    withMind(home);
    mkdirSync(join(home, "logs"), { recursive: true });
    const old = join(home, "logs/app.log");
    writeFileSync(old, Buffer.alloc(25 * 1024 * 1024, "x"));
    const run = await start(app, home);
    try {
      const previous = join(home, "logs/app.previous.log");
      if (!existsSync(previous) || statSync(previous).size !== 25 * 1024 * 1024) throw new Error("the old log was not set aside");
      const size = statSync(old).size;
      if (size > 1024 * 1024) throw new Error(`the new log has ${size} bytes`);
      if (!readFileSync(old, "utf8").includes("==== run start")) throw new Error("the new log has no start line");
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
      withMind(home, undefined, { words: WORDS });
      const sentence = "Herdr runs on the Beelink with Doppler";
      const fixture = join(home, "fixture.aiff");
      // `say -o` writes a file and plays nothing
      execFileSync("say", ["-o", fixture, sentence]);
      const started = Date.now();
      const run = await start(app, home, { ITERATE_MAC_AUDIO_FIXTURE: fixture });
      try {
        await run.control("dictation.start");
        await until("the dictation", 10, async () => (await run.state()).dictation.running);
        // the model loads, the file plays at the clock's pace, then a pause ends the stretch
        let firstWord;
        await until("the words in the pill", 240, async () => {
          const text = (await run.state()).dictation.text ?? "";
          if (text.trim() && firstWord === undefined) firstWord = (Date.now() - started) / 1000;
          return /doppler/i.test(text);
        });
        await run.control("dictation.stop");
        const said = await until("the dictation's text", 60, async () => (await run.state()).dictation.lastText);
        for (const term of ["Herdr", "Beelink", "Doppler"]) if (!said.includes(term)) throw new Error(`"${said}" has no ${term}`);
        // the written text has the terms alone: no heard form of the list, with any separator
        if (WRONG_BEELINK.test(said)) throw new Error(`"${said}" has a heard form of Beelink`);
        // a test copy makes no sound: the start and the written text are counted silent
        const { sounds } = await run.state();
        if (sounds.played !== 0 || sounds.silenced !== 2) throw new Error(`the sounds: ${JSON.stringify(sounds)}`);
        // Core ML compiles the model for the Neural Engine once for each build of the app (its
        // cache, ~/Library/Caches/<bundle or process>/com.apple.e5rt.e5bundlecache, is the
        // build's): the first run after a build waits 12 to 24 s for the model, every later
        // process of it a fraction of a second
        const ready = /is ready after ([\d.]+) s/.exec(readFileSync(join(home, "logs/app.log"), "utf8"));
        return { firstWordSeconds: Math.round(firstWord * 10) / 10, modelReadySeconds: ready ? Number(ready[1]) : null };
      } finally {
        await run.quit();
      }
    },
  },

  /**
   * The history of transcripts (README, "Dictation"), with no speech model: a file as the app
   * writes it, with an entry of 40 days ago and a broken line. The copy reads it (the old entry
   * goes, the broken line is skipped and its file kept beside it); `listen.write` (⌥⇧W, "Paste the
   * last transcript") writes the newest entry, a stretch of Always listen; the Activity window's
   * Dictations mode lists the entries newest first, searches them, and its Paste writes a row's
   * text. Settings › Dictation, "Clear History…", asks once and empties the file, also after a restart.
   */
  "dictation-history": async ({ app, home }) => {
    withMind(home);
    const now = Date.now() / 1000;
    const entry = (id, kind, outcome, ago, text, more = {}) => JSON.stringify({ id, kind, outcome, at: now - ago, text, words: text.split(" ").length, seconds: 2, ...more });
    const texts = {
      old: "This one is forty days old",
      cancelled: "Tell Misha the roadmap moved to Friday",
      written: "Restart the bridge on the Beelink box",
      stretch: "so the panel opens on the mind first",
    };
    const file = join(home, "dictation-history.jsonl");
    writeFileSync(
      file,
      [
        entry("h0", "dictation", "written", 40 * 86400, texts.old, { app: "Notes", bundle: "com.apple.Notes" }),
        entry("h1", "dictation", "cancelled", 600, texts.cancelled, { app: "Slack", bundle: "com.tinyspeck.slackmacgap" }),
        "{ not an entry",
        entry("h2", "dictation", "written", 300, texts.written, { app: "Ghostty", bundle: "com.mitchellh.ghostty", model: "parakeet-v3" }),
        entry("h3", "stretch", "heard", 60, texts.stretch, { model: "parakeet-v3" }),
      ].join("\n") + "\n",
    );
    let run = await start(app, home);
    const tree = async () => JSON.stringify(await run.control("ui.tree"));
    try {
      const history = await until("the history read", 10, async () => (await run.state()).history.read && (await run.state()).history);
      if (history.entries !== 3 || history.newest?.text !== texts.stretch || history.newest.kind !== "stretch" || !history.keeps)
        throw new Error(`the history: ${JSON.stringify(history)}`);
      if (!existsSync(join(home, "dictation-history.broken.jsonl"))) throw new Error("the broken file is not kept beside the history");
      if (!/1 line of the file was no entry/.test(readFileSync(join(home, "logs/app.log"), "utf8"))) throw new Error("the log does not say that a line was broken");
      const lines = readFileSync(file, "utf8").trim().split("\n");
      if (lines.length !== 3 || lines.some((line) => line.includes(texts.old))) throw new Error(`the file is not written again: ${lines.length} lines`);

      // ⌥⇧W: the newest entry, a stretch, whichever ended last
      await run.control("listen.write");
      const written = await until("the pasted transcript", 10, async () => (await run.state()).dictation.lastText);
      if (written !== texts.stretch) throw new Error(`listen.write wrote "${written}"`);

      // the Dictations view, newest first
      await run.control("ui.press", { id: "statusItem" });
      await until("the panel", 10, async () => (await run.state()).panel.visible);
      await run.control("ui.press", { id: "activity.all" });
      await until("the Activity page's button", 5, async () => [...nodes(await run.control("ui.tree"))].some((node) => node.id === "activity.window"));
      await run.control("ui.press", { id: "activity.window" });
      await until("the Activity window", 10, async () => (await run.state()).log.visible);
      await run.control("ui.press", { id: "log.mode", label: "Dictations" });
      const listed = await until("the Dictations view", 10, async () => {
        const log = (await run.state()).log;
        return log.mode === "dictations" && log.dictations.length === 3 && log.dictations;
      });
      if (JSON.stringify(listed) !== JSON.stringify([texts.stretch, texts.written, texts.cancelled])) throw new Error(`the view lists ${JSON.stringify(listed)}`);
      await until("the rows in the tree", 10, async () => {
        const shown = await tree();
        return [texts.stretch, texts.written, texts.cancelled, "dictations.paste"].every((text) => shown.includes(text));
      });
      // the search, then the row's Paste
      await run.control("ui.type", { id: "log.search", text: "beelink" });
      await until("the search", 10, async () => JSON.stringify((await run.state()).log.dictations) === JSON.stringify([texts.written]));
      await until("one row", 10, async () => !(await tree()).includes(texts.cancelled));
      await run.control("ui.press", { id: "dictations.paste" });
      await until("the row's text pasted", 10, async () => (await run.state()).dictation.lastText === texts.written);
      await run.control("ui.press", { id: "log.close" });
      await until("the window closed", 10, async () => !(await run.state()).log.visible);

      // Settings › Dictation: Clear History… asks once, in the page
      await run.control("ui.press", { id: "statusItem" });
      await until("the panel", 10, async () => (await run.state()).panel.visible);
      await run.control("ui.press", { id: "panel.settings" });
      await until("the Settings window", 10, async () => (await run.state()).settings.visible);
      await run.control("ui.press", { id: "settings.page.dictation" });
      await until("Clear History…", 10, async () => (await tree()).includes("settings.clearHistory"));
      await run.control("ui.press", { id: "settings.clearHistory" });
      await until("the question", 10, async () => (await tree()).includes("settings.clearHistory.confirm"));
      if ((await run.state()).history.entries !== 3) throw new Error("the history went before the person said yes");
      await run.control("ui.press", { id: "settings.clearHistory.confirm" });
      await until("the history cleared", 10, async () => (await run.state()).history.entries === 0);
      await until("the file emptied", 10, () => readFileSync(file, "utf8") === "");
      await run.quit();

      run = await start(app, home);
      await until("the history read again", 10, async () => (await run.state()).history.read);
      if ((await run.state()).history.entries !== 0) throw new Error("the cleared history came back after a restart");
      await run.control("listen.write");
      const line = await until("the line", 10, async () => (await run.state()).dictation.lastLine);
      if (!/^No transcript to paste/.test(line)) throw new Error(`with no history, listen.write says "${line}"`);
    } finally {
      await run.quit();
    }
  },

  /**
   * The fixture dictated into the history, then a restart: `listen.write` ("Paste the last
   * transcript") writes the same text from the history, and the Dictations view lists it.
   */
  "dictation-history-fixture": {
    local: "needs the speech model in ~/Library/Application Support/FluidAudio and `say`",
    async run({ app, home }) {
      withMind(home, undefined, { words: WORDS });
      const fixture = join(home, "fixture.aiff");
      execFileSync("say", ["-o", fixture, "Herdr runs on the Beelink with Doppler"]);
      let run = await start(app, home, { ITERATE_MAC_AUDIO_FIXTURE: fixture });
      try {
        await run.control("dictation.start");
        await until("the words in the pill", 240, async () => /doppler/i.test((await run.state()).dictation.text ?? ""));
        await run.control("dictation.stop");
        const said = await until("the dictation's text", 60, async () => (await run.state()).dictation.lastText);
        const kept = await until("the entry", 10, async () => (await run.state()).history.newest);
        if (kept.text !== said || kept.kind !== "dictation" || kept.outcome !== "written") throw new Error(`the history keeps ${JSON.stringify(kept)}`);
        const line = readFileSync(join(home, "dictation-history.jsonl"), "utf8").trim().split("\n").map((text) => JSON.parse(text)).at(-1);
        if (line.text !== said || !line.model || !(line.seconds > 0) || line.words !== said.split(/\s+/).length) throw new Error(`the file's line: ${JSON.stringify(line)}`);
        await run.quit();

        run = await start(app, home);
        await until("the history read", 10, async () => (await run.state()).history.read);
        await run.control("listen.write");
        const written = await until("the pasted transcript", 10, async () => (await run.state()).dictation.lastText);
        if (written !== said) throw new Error(`after the restart listen.write wrote "${written}", the dictation was "${said}"`);
        await run.control("ui.press", { id: "statusItem" });
        await until("the panel", 10, async () => (await run.state()).panel.visible);
        await run.control("ui.press", { id: "activity.all" });
        await until("the Activity page's button", 5, async () => [...nodes(await run.control("ui.tree"))].some((node) => node.id === "activity.window"));
        await run.control("ui.press", { id: "activity.window" });
        await run.control("ui.press", { id: "log.mode", label: "Dictations" });
        await until("the dictation in the view", 10, async () => (await run.state()).log.dictations[0] === said);
        if (!JSON.stringify(await run.control("ui.tree")).includes(said)) throw new Error("ui.tree has no row with the dictation's text");
      } finally {
        await run.quit();
      }
    },
  },

  /**
   * The fn key's ways (`DictationKey`), with the fixture in place of the microphone: a tap that
   * times out, a hold, a double tap that locks and fn to finish, and a lock that Esc cancels.
   */
  "dictation-fn": {
    local: "needs the speech model in ~/Library/Application Support/FluidAudio and `say`",
    async run({ app, home }) {
      withMind(home, undefined, { words: WORDS });
      const fixture = join(home, "fixture.aiff");
      execFileSync("say", ["-o", fixture, "Herdr runs on the Beelink with Doppler"]);
      const run = await start(app, home, { ITERATE_MAC_AUDIO_FIXTURE: fixture });
      const fn = (down) => run.control("dictation.fn", { down });
      const dictation = async () => (await run.state()).dictation;
      const pause = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
      try {
        // a tap alone listens until the window ends, then throws the sound away with no line
        await fn(true);
        await fn(false);
        const tapped = await dictation();
        if (!tapped.running || tapped.key !== "tapped") throw new Error(`a tap: ${JSON.stringify(tapped)}`);
        await until("the tap's end", 5, async () => !(await dictation()).running && (await dictation()).key === "idle");
        if ((await dictation()).ends !== 0) throw new Error(`a tap left a line: ${(await dictation()).lastLine}`);
        // held: it listens while fn is down, and writes at the release
        await fn(true);
        await until("the hold", 5, async () => (await dictation()).key === "pressed");
        await until("the words in the pill", 240, async () => /doppler/i.test((await dictation()).text));
        await fn(false);
        const ended = async (count) => {
          const state = await dictation();
          return !state.running && state.ends === count && state;
        };
        const held = (await until("the held dictation's text", 60, () => ended(1))).lastText;
        for (const term of ["Herdr", "Beelink", "Doppler"]) if (!held.includes(term)) throw new Error(`held: "${held}" has no ${term}`);
        // tapped twice: locked, it listens with fn up, until the next press of fn
        await pause(600);
        for (const down of [true, false, true, false]) await fn(down);
        await until("the lock", 5, async () => (await dictation()).locked && (await dictation()).key === "locked");
        await until("the words in the pill", 60, async () => /doppler/i.test((await dictation()).text));
        if (!(await dictation()).running) throw new Error("locked ended with fn up");
        await fn(true);
        const free = (await until("the locked text", 60, () => ended(2))).lastText;
        if (!/Doppler/.test(free)) throw new Error(`locked: "${free}" has no Doppler`);
        // the release of the press that finished does nothing
        await fn(false);
        await pause(600);
        if ((await dictation()).running) throw new Error("the release after the finish started a dictation");
        // locked, then Esc: nothing is written
        for (const down of [true, false, true, false]) await fn(down);
        await until("the second lock", 5, async () => (await dictation()).key === "locked");
        await run.control("dictation.esc");
        const cancelled = (await until("Esc's end", 10, () => ended(3))).lastLine;
        if (!/^Cancelled at /.test(cancelled)) throw new Error(`Esc: the line is "${cancelled}"`);
        // Astra 16: a hold again at once, before the last words of the one before came. Those come
        // once; the new hold keeps its key and its pill, and its own release writes it.
        await pause(600);
        await fn(true);
        await until("a hold's words", 60, async () => /doppler/i.test((await dictation()).text));
        await fn(false);
        await fn(true);
        const again = await dictation();
        if (!again.running || again.key !== "pressed") throw new Error(`the second hold: ${JSON.stringify(again)}`);
        await until("the first hold's end", 60, async () => (await dictation()).ends === 4);
        const during = await dictation();
        if (!during.running || during.key !== "pressed" || during.phase !== "listening")
          throw new Error(`the second hold after the first one's words: ${JSON.stringify(during)}`);
        await pause(800);
        await fn(false);
        const second = await until("the second hold's end", 60, () => ended(5));
        if (!/^(Heard|Wrote)/.test(second.lastLine)) throw new Error(`the second hold: the line is "${second.lastLine}"`);
        // a test copy makes no sound: each cue (the starts, the written texts, Esc) is counted silent
        const { sounds, choices } = await run.state();
        if (!choices.sounds || sounds.played !== 0 || sounds.silenced < 6) throw new Error(`the sounds: ${JSON.stringify(sounds)}`);
      } finally {
        await run.quit();
      }
    },
  },

  /**
   * Always listen (README, "Listening"), with the fixture in place of the microphone and no key:
   * the sentence after 1.5 s of silence is one stretch, put into words by the one transcriber with
   * the word list. The rule picks the local model: the fake mind refuses OpenAI and the copy has no
   * key (a stretch that comes before the mind said no tries it, is refused, and falls back); `listen.write` (⌥⇧W, "write what I just said") writes it; the stretch reaches the fake
   * mind as one line of the record's `transcript` track. Then 20 s of the fixture's silence with
   * Always listen on: its figures are in the result (`perf.on`).
   */
  "listen-always": {
    local: "needs the speech model in ~/Library/Application Support/FluidAudio and `say`; Silero VAD downloads there at its first use",
    async run({ app, home }) {
      const sent = withMind(home, undefined, { words: WORDS });
      const fixture = join(home, "fixture.aiff");
      execFileSync("say", ["-o", fixture, "[[slnc 1500]] Herdr runs on the Beelink with Doppler"]);
      execFileSync("defaults", ["write", join(home, "defaults"), "listen.always", "-bool", "true"]);
      const started = Date.now();
      const run = await start(app, home, { ITERATE_MAC_AUDIO_FIXTURE: fixture });
      try {
        await until("Always listen on", 20, async () => (await run.state()).listening.always);
        const last = await until("the stretch's words", 240, async () => (await run.state()).listening.last);
        const stretchSeconds = Math.round((Date.now() - started) / 100) / 10;
        for (const term of ["Herdr", "Beelink", "Doppler"]) if (!last.text.includes(term)) throw new Error(`"${last.text}" has no ${term}`);
        if (WRONG_BEELINK.test(last.text)) throw new Error(`"${last.text}" has a heard form of Beelink`);
        if (!/^listen-\d+$/.test(last.stretch)) throw new Error(`the stretch is ${last.stretch}`);
        await sleep(1500);
        const { listening, dictation } = await run.state();
        if (listening.stretches !== 1 || listening.listenSegments !== 1) throw new Error(`the fixture is one stretch: ${JSON.stringify(listening)}`);
        if (dictation.ends !== 0) throw new Error(`no key was held, and a dictation ended: ${dictation.lastLine}`);
        // write what I just said: the stretch, though no key was held while it was said
        await run.control("listen.write");
        const written = await until("the written stretch", 10, async () => (await run.state()).dictation.lastText);
        if (written !== last.text) throw new Error(`wrote "${written}", the stretch is "${last.text}"`);
        // the record's transcript track: its slot seals a second after the slot's end
        const event = await until("the transcript in the mind", 45, () =>
          sent().find((e) => e.type === "record/slot-stored" && e.payload?.tracks?.transcript),
        );
        const track = event.payload.tracks.transcript;
        if (track.kind !== "transcript" || track.segments !== 1 || !/\/record\/transcript\/.*\.jsonl$/.test(track.file))
          throw new Error(`the slot's transcript: ${JSON.stringify(track)}`);
        if (!sent().some((line) => line.file === track.file.slice(1) && line.bytes === track.bytes)) throw new Error(`the mind has no ${track.file}`);
        if (Object.keys(event.payload.tracks).length !== 1) throw new Error(`Always listen records no sound: ${Object.keys(event.payload.tracks)}`);
        // the mark says it
        const tree = JSON.stringify(await run.control("ui.tree"));
        if (!tree.includes("Always listen: the microphone is open")) throw new Error("the mark's label does not say that Always listen is on");
        // what Always listen costs in silence
        await sleep(2000);
        await run.control("perf.reset");
        const before = (await run.state()).perf;
        await sleep(20000);
        const on = perfDelta(before, (await run.state()).perf);
        const log = readFileSync(join(home, "logs/app.log"), "utf8");
        const detector = /always listen: listens: (.+)/.exec(log)?.[1] ?? null;
        const timing = /always listen: stretch \d+: ([\d.]+ s, \d+ words[^\n]+)/.exec(log)?.[1] ?? null;
        // who heard it follows the rule: no OpenAI here, so the local model
        if (!/, by (oruk-fourier-2b|parakeet-v3|parakeet-ultra)$/.test(timing ?? "")) throw new Error(`the stretch was not heard by the local model: ${timing}`);
        return { on, detector, timing, stretchSeconds };
      } finally {
        await run.quit();
      }
    },
  },

  /**
   * A capture's voice, as pushed buffers with their times: the fixture, with 2 s of silence first,
   * through the local provider of the transcriber (speech-bench's recognizer: what hears a capture
   * when OpenAI cannot be reached or fails), gives timed segments with the terms.
   */
  "capture-transcript-fixture": {
    local: "needs the speech model in ~/Library/Application Support/FluidAudio and `say`",
    async run({ app, home }) {
      const bench = join(dirname(app), "speech-bench");
      if (!existsSync(bench)) throw new Error(`no ${bench}: run swift build`);
      const fixture = join(home, "fixture.aiff");
      execFileSync("say", ["-o", fixture, "[[slnc 2000]] Herdr runs on the Beelink with Doppler"]);
      const words = join(home, "words.md");
      writeFileSync(words, WORDS);
      const lines = execFileSync(bench, ["--model", "parakeet-v3", "--words", words, fixture], { encoding: "utf8", timeout: 300_000, stdio: ["ignore", "pipe", "ignore"] })
        .trim()
        .split("\n")
        .map((line) => JSON.parse(line));
      const segments = lines.at(-1).segments ?? [];
      const text = segments.map((segment) => segment.text).join(" ");
      for (const term of ["Herdr", "Beelink", "Doppler"]) if (!text.includes(term)) throw new Error(`"${text}" has no ${term}`);
      if (WRONG_BEELINK.test(text)) throw new Error(`"${text}" has a heard form of Beelink`);
      // the words start after the silence, on the capture's clock
      if (!(segments[0].t >= 1500 && segments[0].t < 3500 && segments.at(-1).to > segments[0].t))
        throw new Error(`the segments' times are ${JSON.stringify(segments.map(({ t, to }) => [t, to]))}`);
    },
  },

  /**
   * Oruk Fourier 2B, chosen, hears the dictation fixture in a test copy: the pill has words before
   * the end (a pass at most once a second, `PacedEngine`), and the text has the list's terms.
   */
  "dictation-fourier": {
    local: "needs Oruk Fourier's files (2.85 GB, `FourierRuntime`: ~/Library/Application Support/iterate-speech/oruk-fourier-2b or ITERATE_MAC_FOURIER_FOLDER) and `say`",
    async run({ app, home }) {
      if (!hasFourier()) return { skipped: `no Oruk Fourier files in ${FOURIER}: the model's first use downloads them (2.68 GB)` };
      withMind(home, undefined, { words: WORDS });
      execFileSync("defaults", ["write", join(home, "defaults"), "speechModel", "oruk-fourier-2b"]);
      const fixture = join(home, "fixture.aiff");
      execFileSync("say", ["-o", fixture, "Herdr runs on the Beelink with Doppler, and the words come while I talk"]);
      const started = Date.now();
      const run = await start(app, home, { ITERATE_MAC_AUDIO_FIXTURE: fixture });
      try {
        if ((await run.state()).speech.model !== "oruk-fourier-2b") throw new Error(`the model is ${(await run.state()).speech.model}`);
        await run.control("dictation.start");
        await until("the dictation", 10, async () => (await run.state()).dictation.running);
        // the words before the end: the pill shows a partial pass's text while the file plays
        const seen = [];
        let firstWord;
        await until("the words in the pill", 120, async () => {
          const text = (await run.state()).dictation.text ?? "";
          if (text.trim() && seen.at(-1) !== text) seen.push(text);
          if (text.trim() && firstWord === undefined) firstWord = (Date.now() - started) / 1000;
          return /talk/i.test(text);
        });
        await run.control("dictation.stop");
        const said = await until("the dictation's text", 60, async () => (await run.state()).dictation.lastText);
        for (const term of ["Herdr", "Beelink", "Doppler"]) if (!said.includes(term)) throw new Error(`"${said}" has no ${term}`);
        if (WRONG_BEELINK.test(said)) throw new Error(`"${said}" has a heard form of Beelink`);
        if (seen.length < 2) throw new Error(`the pill had one text only before the end: ${JSON.stringify(seen)}`);
        const log = readFileSync(join(home, "logs/app.log"), "utf8");
        if (!/listening 1 starts with oruk-fourier-2b/.test(log)) throw new Error("the log has no listening with oruk-fourier-2b");
        const ready = /oruk-fourier-2b is ready after ([\d.]+) s/.exec(log);
        return { firstWordSeconds: Math.round(firstWord * 10) / 10, modelReadySeconds: ready ? Number(ready[1]) : null, pillTexts: seen.length };
      } finally {
        await run.quit();
      }
    },
  },

  /** The model picker of Settings › Dictation, through ui.press: the choice is stored in the home's defaults. */
  "speech-model": {
    local: "needs Parakeet v3 and Ultra in ~/Library/Application Support/FluidAudio (else a choice downloads)",
    async run({ app, home }) {
      const run = await start(app, home);
      try {
        const speech = async () => (await run.state()).speech;
        // the default is Oruk Fourier once its files are on this Mac; until then Parakeet v3 stands in
        const local = hasFourier() ? "oruk-fourier-2b" : "parakeet-v3";
        if ((await speech()).model !== local) throw new Error(`the default model is ${(await speech()).model}, not ${local}`);
        if (!(await speech()).models.filter((model) => model.id.startsWith("parakeet")).every((model) => model.onDisk)) throw new Error("a Parakeet model is not on this Mac");
        await run.control("ui.press", { id: "statusItem" });
        await until("the panel", 10, async () => (await run.state()).panel.visible);
        await run.control("ui.press", { id: "panel.settings" });
        await until("the Settings window", 10, async () => (await run.state()).settings.visible);
        await run.control("ui.press", { id: "settings.page.dictation" });
        await until("the list", 5, async () => [...nodes(await run.control("ui.tree"))].some((node) => node.id === "speech.model.parakeet-ultra"));
        await run.control("ui.press", { id: "speech.model.parakeet-ultra" });
        await until("Ultra chosen", 10, async () => (await speech()).model === "parakeet-ultra");
        const stored = execFileSync("defaults", ["read", join(home, "defaults"), "speechModel"], { encoding: "utf8" }).trim();
        if (stored !== "parakeet-ultra") throw new Error(`the stored choice is ${stored}`);
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

  /**
   * A slot that waits in the spool (as the recorder seals it) goes into the mind: its file first,
   * then `record/slot-stored`, and it leaves the spool. The spool is the device's
   * (`record/<mind>/itx.<name>/`). An earlier version's spool, one for the mind, is split by the
   * name each slot was recorded as: this name's slot goes up, another name's waits in its own
   * spool and is never published as this device (Astra 11).
   */
  async "record-upload"({ app, home }) {
    const sent = withMind(home);
    const old = join(home, "record", MIND);
    const spool = join(old, `itx.${NAME}`);
    const t = 1764000000;
    const file = `/devices/${NAME}/record/mic-0/2025-11-24/16/00-00.mp4`;
    const slot = (folder, t, file, bytes) => {
      mkdirSync(dirname(join(folder, file)), { recursive: true });
      writeFileSync(join(folder, file), Buffer.alloc(bytes, 1));
      mkdirSync(join(folder, "slots"), { recursive: true });
      const payload = { t, tracks: { "mic-0": { kind: "audio", file, bytes } } };
      writeFileSync(join(folder, "slots", `${t}.json`), JSON.stringify(payload));
      return payload;
    };
    const payload = slot(old, t, file, 4321);
    const renamed = `/devices/old.mac/record/mic-0/2025-11-24/15/59-30.mp4`;
    slot(old, t - 30, renamed, 99);
    const run = await start(app, home);
    try {
      const event = await until("record/slot-stored in the fake mind", 30, () => sent().find((e) => e.type === "record/slot-stored"));
      if (event.path !== `/devices/${NAME}` || event.idempotencyKey !== `record/slot-stored/${t}` || JSON.stringify(event.payload) !== JSON.stringify(payload))
        throw new Error(`the mind got ${JSON.stringify(event)}`);
      const lines = sent();
      const stored = lines.findIndex((line) => line.file === file.slice(1));
      if (stored === -1 || lines[stored].bytes !== 4321) throw new Error(`the mind has no ${file} of 4321 bytes: ${JSON.stringify(lines[stored])}`);
      if (stored > lines.findIndex((line) => line.type === "record/slot-stored")) throw new Error("the event came before its file");
      await until("the slot gone from the spool", 10, () => !existsSync(join(spool, "slots", `${t}.json`)) && !existsSync(join(spool, file)));
      await until("no slot waiting", 10, async () => (await run.endpoint("record.state")).waitingSlots === 0);
      const other = join(old, "itx.old.mac");
      if (!existsSync(join(other, "slots", `${t - 30}.json`)) || !existsSync(join(other, renamed)))
        throw new Error("the slot of the old name is not in its own spool");
      if (sent().some((e) => e.type === "record/slot-stored" && e.payload?.t === t - 30)) throw new Error("the old name's slot went up as this device");
      if (existsSync(join(old, "slots", `${t}.json`))) throw new Error("the old spool still holds this name's slot");
    } finally {
      await run.quit();
    }
  },

  /**
   * A use whose choice is Ask waits for the answer, and its panel shows with the three answers:
   * approved and denied through the socket, then through the panel's buttons (`ui.press`), and
   * "Approve for N Minutes" lets the next use run with no question.
   */
  /**
   * This Mac's pages (bridge/pages.mjs on the endpoint): Pages at Off refuses `/state.json`; at
   * Shared, with the display Shared and a frame fixture (no screen capture), `/live.mjpeg` gives 3
   * JPEG parts between multipart boundaries, and its cancel ends the view in the app.
   */
  async "pages-live"({ app, home }) {
    const { pages, BOUNDARY } = await import("../bridge/pages.mjs");
    const env = { ITERATE_MAC_FRAME_FIXTURE: "synthetic" };
    let run = await start(app, home, env);
    let screens;
    try {
      const off = await pages({ ask: run.endpoint }).http({ path: "/state.json" });
      if (off.status !== 403 || !/off/.test(off.body)) throw new Error(`Pages at Off answered ${off.status} ${off.body}`);
      screens = (await run.endpoint("state")).things.filter((t) => t.kind === "screen").map((t) => t.thing);
    } finally {
      await run.quit();
    }
    if (!screens.length) throw new Error("this Mac has no display");
    for (const thing of ["pages", ...screens]) execFileSync("defaults", ["write", join(home, "defaults"), `sharing.${thing}`, "shared"]);
    run = await start(app, home, env);
    try {
      const { http } = pages({ ask: run.endpoint });
      const answer = await http({ method: "GET", path: "/live.mjpeg", query: {}, headers: {} });
      if (answer.status !== 200) throw new Error(`/live.mjpeg answered ${answer.status} ${answer.body}`);
      if (answer.headers["content-type"] !== `multipart/x-mixed-replace; boundary=${BOUNDARY}`) throw new Error(`its type is ${answer.headers["content-type"]}`);
      const reader = answer.body.getReader();
      let bytes = Buffer.alloc(0);
      const parts = [];
      while (parts.length < 3) {
        const { value, done } = await reader.read();
        if (done) throw new Error(`the stream ended after ${parts.length} parts`);
        bytes = Buffer.concat([bytes, value]);
        // one part: the boundary, its head, the JPEG of Content-Length bytes, CRLF
        const head = new RegExp(`^--${BOUNDARY}\r\nContent-Type: image/jpeg\r\nContent-Length: (\\d+)\r\n\r\n`).exec(bytes.toString("latin1"));
        if (!head) throw new Error(`no boundary at the start of part ${parts.length + 1}: ${JSON.stringify(bytes.subarray(0, 60).toString("latin1"))}`);
        const end = head[0].length + Number(head[1]);
        if (bytes.length < end + 2) continue;
        const jpeg = bytes.subarray(head[0].length, end);
        if (jpeg[0] !== 0xff || jpeg[1] !== 0xd8 || jpeg.at(-2) !== 0xff || jpeg.at(-1) !== 0xd9) throw new Error(`part ${parts.length + 1} is no JPEG`);
        if (bytes.subarray(end, end + 2).toString("latin1") !== "\r\n") throw new Error(`part ${parts.length + 1} has no CRLF before the next boundary`);
        parts.push(jpeg.length);
        bytes = bytes.subarray(end + 2);
      }
      if ((await run.endpoint("pages.state")).live.pageViews !== 1) throw new Error("the app does not count the view");
      await reader.cancel();
      await until("the view's end in the app", 5, async () => (await run.endpoint("pages.state")).live.pageViews === 0);
      const row = (await run.endpoint("pages.state")).acts.find((act) => /live in a page/.test(act.title));
      if (!row || row.running) throw new Error(`the view's act is ${JSON.stringify(row)}`);
    } finally {
      await run.quit();
    }
  },
  async approval({ app, home }) {
    // a mind session: an approval for N minutes holds in a session only
    withMind(home);
    execFileSync("defaults", ["write", join(home, "defaults"), "sharing.commands", "ask"]);
    const run = await start(app, home);
    const ids = async () => new Set([...nodes(await run.control("ui.tree"))].map((node) => node.id).filter(Boolean));
    const echo = () =>
      run.endpoint("run", { argv: ["/bin/echo", "approved"] }).then(
        (answer) => ({ answer }),
        (error) => ({ error }),
      );
    const ran = ({ answer, error }) => {
      if (error) throw error;
      const out = Buffer.from(answer.stdoutBase64, "base64").toString();
      if (out.trim() !== "approved") throw new Error(`the command wrote ${JSON.stringify(out)}`);
    };
    const denied = ({ answer, error }) => {
      if (!/denied/.test(error?.message ?? "")) throw new Error(`a denied use answered ${JSON.stringify(answer ?? error?.message)}`);
    };
    try {
      if ((await run.state()).sharing.commands !== "ask") throw new Error("commands are not on Ask");
      await until("the session", 10, async () => (await run.state()).session);
      const answers = [
        [(r) => r.control("approval.answer", { allow: true }), ran],
        [(r) => r.control("approval.answer", { allow: false }), denied],
        [(r) => r.control("ui.press", { id: "approval.once" }), ran],
        [(r) => r.control("ui.press", { id: "approval.deny" }), denied],
        // the keys of the question's panel: Return approves once, Esc denies. A test copy's panel
        // is never key (OffScreen.swift): `ui.key` gives them to the front window, whose SwiftUI
        // shortcuts take them (`by: "window"`). Else the socket answers, and the result says so.
        [(r) => byKey(r, "return", true), ran],
        [(r) => byKey(r, "escape", false), denied],
      ];
      let keysSkipped = false;
      const byKey = async (r, key, allow) => {
        const pressed = await r.control("ui.key", { key });
        if (pressed.title === "Ask" && pressed.by === "window") return pressed;
        keysSkipped = true;
        return r.control("approval.answer", { allow });
      };
      for (const [answer, check] of answers) {
        const asked = echo();
        const state = await until("the question", 10, async () => (await run.state()).approval);
        if (!/run commands/.test(state.question)) throw new Error(`the question is ${state.question}`);
        if (!/\/bin\/echo approved/.test(state.question)) throw new Error(`the question shows no command: ${state.question}`);
        await until("the question's panel", 5, async () => {
          const shown = await ids();
          return ["approval.once", "approval.minutes", "approval.deny"].every((id) => shown.has(id));
        });
        await answer(run);
        check(await asked);
        await until("the panel gone", 5, async () => !(await ids()).has("approval.once"));
      }
      // approved for approval.minutes: the next use runs with no question
      const kept = echo();
      await until("the question", 10, async () => (await run.state()).approval);
      await until("the panel's second button", 5, async () => (await ids()).has("approval.minutes"));
      await run.control("ui.press", { id: "approval.minutes" });
      ran(await kept);
      const again = await Promise.race([echo(), new Promise((resolve) => setTimeout(() => resolve({ timedOut: true }), 5000))]);
      if (again.timedOut) throw new Error("the use after Approve for 30 Minutes waits for a question");
      ran(again);
      const acts = (await run.state()).activity.entries;
      // the uses that ran: two by the socket and the buttons, one by Return, two after the time was approved
      if (acts.length !== 5 || acts.some((act) => act.did !== "Ran a command")) throw new Error(`the activity is ${JSON.stringify(acts)}`);
      if (keysSkipped) return { skipped: "Return and Esc: the question's panel did not take them through ui.key" };
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

      // B: two uses wait, the first on its question, the second behind it; the switch back to A
      // ends both, and neither runs, nor asks A (Astra 1)
      const queued = [echo(), echo()];
      await until("B's question again", 10, async () => (await run.state()).approval);
      writeConfig(home, join(home, "fake-iterate"), [A, B], A.mind);
      for (const { answer, error } of await Promise.all(queued)) {
        if (answer) throw new Error("a use of B ran after the switch to A");
        if (!/mind changed|no longer lent/.test(error?.message ?? "")) throw new Error(`a use of B ended with ${error?.message}`);
      }
      await until("the session for A again", 10, async () => (await run.state()).session?.mind === A.mind);
      if ((await run.state()).approval) throw new Error("a question of B is still asked under A");
    } finally {
      await run.quit();
    }
  },
};

async function main() {
  const { positionals, values } = parseArgs({
    allowPositionals: true,
    options: {
      app: { type: "string", default: join(root, ".build/debug/VoiceMeetMac") },
      keep: { type: "boolean" },
      "on-screen": { type: "boolean" },
    },
  });
  if (values["on-screen"]) copyArgs.push("--on-screen");
  const wanted = positionals[0];
  const all = Object.entries(scenarios).map(([name, scenario]) =>
    typeof scenario === "function" ? { name, run: scenario } : { name, ...scenario },
  );
  const chosen = wanted === "all" ? all : wanted === "ci" ? all.filter((s) => !s.local) : all.filter((s) => s.name === wanted);
  if (!chosen.length) {
    console.error(`node harness/run.mjs <${all.map((s) => s.name).join("|")}|ci|all> [--app <path>] [--keep] [--on-screen]`);
    process.exit(2);
  }
  if (!existsSync(values.app)) throw new Error(`no app at ${values.app}: run swift build first`);
  let failed = 0;
  for (const scenario of chosen) {
    // a short folder: a Unix socket's path has at most 103 bytes
    const home = mkdtempSync(join(tmpdir(), "itx-"));
    const started = Date.now();
    const result = { scenario: scenario.name };
    sightings = [];
    seen.clear();
    const stopWatch = watchScreens();
    try {
      // a scenario may answer its figures (`perf`), or what it could not check here (`skipped`)
      const { skipped, ...figures } = (await scenario.run({ app: values.app, home })) ?? {};
      if (Object.keys(figures).length) result.perf = figures;
      if (skipped) result.skipped = skipped;
      // the last look of the window server, after the scenario's end
      await sleep(400);
      if (sightings.length) throw new Error(`a copy showed itself to the person at the Mac: ${sightings.join("; ")}`);
      result.ok = true;
    } catch (error) {
      failed++;
      result.ok = false;
      result.error = error.message;
    } finally {
      stopWatch();
      killAll();
    }
    result.seconds = Math.round((Date.now() - started) / 100) / 10;
    const log = join(home, "logs/app.log");
    if (!result.ok && existsSync(log)) result.log = readFileSync(log, "utf8").trim().split("\n").slice(-15);
    if (values.keep || !result.ok) result.home = home;
    else {
      // a stopped copy's last writes may still land in its home: retry, and never fail the run on it
      try {
        rmSync(home, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
      } catch (error) {
        result.cleanup = error.code ?? error.message;
      }
    }
    console.log(JSON.stringify(result));
  }
  process.exit(failed ? 1 : 0);
}

await main();
