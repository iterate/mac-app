#!/usr/bin/env node
// design-diff.mjs: each view of the app against its mock in design/, measured.
//
//   node harness/design-diff.mjs [--only v2-Live,v2-Pills] [--tone dark|light|both]
//                                [--app .build/debug/VoiceMeetMac] [--drawn <folder>] [--out <folder>]
//
// For each mock (design/html/<target>-<tone>.html) headless Chrome draws the page at 2 pixels to a
// point, and the script cuts out each component (an element with the mocks' panel or pill shadow,
// in the order of the page). The app draws every view (`--render-all`, or the drawings already in
// `--drawn`), and the script cuts out the matching one. Both are put over the same grey, aligned
// at their top left, and compared over the part they share:
//
// - `mad`: the mean absolute difference of a channel, 0 to 255 (0 is the same picture);
// - `banded`: the same, with each band of 16 points of the mock compared where it fits the app's
//   picture best, up to 40 points up or down: a row the app has and the mock has not (or a line
//   that wraps otherwise) moves what is under it, and `mad` counts all of that, `banded` not;
// - `size`: the app's size less the mock's, in points.
//
// Into <out> (default ~/.cache/mac-app-night/fidelity) go <view>-side.png (the mock, the app, and
// the difference side by side) and <view>-diff.png (the difference alone, brightened), and
// scores.json. Chrome runs with its own profile in a new folder under /tmp and is stopped at the
// end; the mocks' web fonts are blocked, so the mocks draw in SF as the app does.
import { execFileSync, spawn } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { parseArgs } from "node:util";
import { readPng, writePng } from "./snapshots.mjs";

const root = join(import.meta.dirname, "..");
const chromePath = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";

/** What to compare. `parts` are the mock's components in page order; each names the app's drawing
 *  (`<name>-<tone>.png` in the drawings' folder) and the points of margin the drawing has around
 *  the component (`pad`: [top, right, bottom, left]). `crop: true` cuts the app's drawing to the
 *  mock's height (the mock shows only the top of the panel). A null `file` has no drawing. */
const VIEWS = {
  "v2-Live": [{ view: "panel-live", file: "panel-live" }],
  "v2-Busy": [{ view: "panel-busy", file: "panel-busy" }],
  "v2-Blocked": [{ view: "panel-blocked", file: "panel-blocked" }],
  "v2-Activity": [{ view: "panel-activity", file: "panel-activity" }],
  "v2-NoMind": [{ view: "panel-no-mind", file: "panel-no-mind" }],
  "v2-Phases": ["connecting", "reconnecting", "stopped", "not-allowed", "incompatible"].map((phase) => ({
    view: `phase-${phase}`,
    file: `panel-${phase}`,
    crop: true,
  })),
  "v2-Top": [
    { view: "switcher-open", file: "switcher-open" },
    { view: "panel-ringing", file: "panel-ringing", crop: true },
  ],
  "v2-Pills": [
    { view: "pill-act", file: "activity-pill", pad: 12 },
    { view: "pill-watch", file: "watch-pill", pad: 12 },
    { view: "pill-capture", file: "capture-pill", pad: 12 },
    { view: "dictation-listening", file: "dictation-listening", pad: 24 },
    { view: "dictation-locked", file: "dictation-locked", pad: 24 },
    { view: "dictation-loading", file: "dictation-loading", pad: 24 },
    { view: "dictation-failed", file: "dictation-failed", pad: 24 },
  ],
  "v2-Input": [
    { view: "input-filled", file: "input-filled", pad: 32 },
    { view: "input-failed", file: "input-failed-fix", pad: 32 },
  ],
  "v2-Approval": [{ view: "approval", file: "approval", pad: 20 }],
  Log: [{ view: "log", file: "log" }],
  SettingsGeneral: [{ view: "settings-general", file: "settings-general" }],
  SettingsDictation: [{ view: "settings-dictation", file: "settings-dictation" }],
  SettingsMindIterate: [{ view: "settings-mind-iterate", file: "settings-mind-lent" }],
  SettingsMindGarden: [{ view: "settings-mind-garden", file: "settings-mind-failing" }],
};

/** The grey both pictures are put over, where they are see-through. */
const GROUND = [128, 128, 128];

// MARK: - Chrome, through its DevTools protocol

async function startChrome() {
  const profile = mkdtempSync(join("/tmp", "design-diff-chrome-"));
  const child = spawn(
    chromePath,
    [
      "--headless=new",
      "--remote-debugging-port=0",
      `--user-data-dir=${profile}`,
      "--no-first-run",
      "--no-default-browser-check",
      "--hide-scrollbars",
      "--mute-audio",
      "about:blank",
    ],
    { stdio: ["ignore", "ignore", "pipe"] },
  );
  const url = await new Promise((resolve, reject) => {
    let said = "";
    const timer = setTimeout(() => reject(new Error(`Chrome did not start: ${said.slice(-2000)}`)), 20000);
    child.stderr.on("data", (data) => {
      said += data;
      const match = said.match(/DevTools listening on (ws:\/\/\S+)/);
      if (match) {
        clearTimeout(timer);
        resolve(match[1]);
      }
    });
    child.on("exit", (code) => reject(new Error(`Chrome ended (${code}): ${said.slice(-2000)}`)));
  });
  const socket = new WebSocket(url);
  await new Promise((resolve, reject) => {
    socket.onopen = resolve;
    socket.onerror = reject;
  });
  let next = 1;
  const waiting = new Map();
  const listeners = [];
  socket.onmessage = (message) => {
    const data = JSON.parse(message.data);
    if (data.id && waiting.has(data.id)) {
      const { resolve, reject } = waiting.get(data.id);
      waiting.delete(data.id);
      if (data.error) reject(new Error(JSON.stringify(data.error)));
      else resolve(data.result);
    } else if (data.method) for (const listen of listeners) listen(data);
  };
  const send = (method, params = {}, sessionId) =>
    new Promise((resolve, reject) => {
      const id = next++;
      waiting.set(id, { resolve, reject });
      socket.send(JSON.stringify({ id, method, params, sessionId }));
    });
  const { targetId } = await send("Target.createTarget", { url: "about:blank" });
  const { sessionId } = await send("Target.attachToTarget", { targetId, flatten: true });
  const page = (method, params) => send(method, params, sessionId);
  const event = (name) =>
    new Promise((resolve) => {
      const listen = (data) => {
        if (data.method === name && data.sessionId === sessionId) {
          listeners.splice(listeners.indexOf(listen), 1);
          resolve(data.params);
        }
      };
      listeners.push(listen);
    });
  await page("Page.enable");
  await page("Network.enable");
  await page("Network.setBlockedURLs", { urls: ["*fonts.googleapis.com*", "*fonts.gstatic.com*"] });
  await page("Emulation.setDeviceMetricsOverride", { width: 1400, height: 3000, deviceScaleFactor: 2, mobile: false });
  await page("Emulation.setDefaultBackgroundColorOverride", { color: { r: 0, g: 0, b: 0, a: 0 } });
  return {
    page,
    event,
    stop() {
      socket.close();
      child.kill();
    },
  };
}

/** The mock's components, each as a PNG of 2 pixels to a point, the page around it see-through. */
async function drawMock(chrome, file) {
  const loaded = chrome.event("Page.loadEventFired");
  await chrome.page("Page.navigate", { url: `file://${file}` });
  await loaded;
  const { result } = await chrome.page("Runtime.evaluate", {
    returnByValue: true,
    awaitPromise: true,
    expression: `(async () => {
      await document.fonts.ready;
      const parts = [...document.querySelectorAll("[style]")].filter((element) =>
        /box-shadow: 0 (18px 50px|6px 20px)/.test(element.getAttribute("style")));
      for (const part of parts) {
        part.style.boxShadow = "none";
        // the page around the component is see-through, as the app's window is
        for (let up = part.parentElement; up; up = up.parentElement) up.style.background = "transparent";
      }
      document.body.style.background = "transparent";
      return parts.map((part) => { const r = part.getBoundingClientRect(); return [r.x, r.y, r.width, r.height]; });
    })()`,
  });
  const shots = [];
  for (const [x, y, width, height] of result.value) {
    const { data } = await chrome.page("Page.captureScreenshot", {
      format: "png",
      captureBeyondViewport: true,
      clip: { x, y, width, height, scale: 1 },
    });
    shots.push({ picture: readPng(Buffer.from(data, "base64")), points: [width, height] });
  }
  return shots;
}

// MARK: - Pictures

/** The picture over the ground, as RGB in a Float32Array. */
function flatten({ width, height, pixels }) {
  const rgb = new Float32Array(width * height * 3);
  for (let i = 0; i < width * height; i++) {
    const alpha = pixels[i * 4 + 3] / 255;
    for (let c = 0; c < 3; c++) rgb[i * 3 + c] = pixels[i * 4 + c] * alpha + GROUND[c] * (1 - alpha);
  }
  return { width, height, rgb };
}

function cut(picture, x, y, width, height) {
  width = Math.max(0, Math.min(width, picture.width - x));
  height = Math.max(0, Math.min(height, picture.height - y));
  const pixels = Buffer.alloc(width * height * 4);
  for (let row = 0; row < height; row++)
    picture.pixels.copy(pixels, row * width * 4, ((y + row) * picture.width + x) * 4, ((y + row) * picture.width + x + width) * 4);
  return { width, height, pixels };
}

/** The score over the part both share, the difference's picture, and the side by side. */
function compare(mock, app) {
  const a = flatten(mock);
  const b = flatten(app);
  const width = Math.min(a.width, b.width);
  const height = Math.min(a.height, b.height);
  let sum = 0;
  const diff = { width, height, pixels: Buffer.alloc(width * height * 4) };
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      let most = 0;
      for (let c = 0; c < 3; c++) {
        const d = Math.abs(a.rgb[(y * a.width + x) * 3 + c] - b.rgb[(y * b.width + x) * 3 + c]);
        sum += d;
        most = Math.max(most, d);
      }
      const v = Math.min(255, most * 3);
      diff.pixels.set([v, v * 0.35, v * 0.35, 255], (y * width + x) * 4);
    }
  }
  const mad = width && height ? sum / (width * height * 3) : 255;
  const banded = bandedDifference(a, b);
  // side by side: the mock, the app, the difference, 16 pixels apart on the ground
  const gap = 16;
  const sideWidth = a.width + b.width + width + gap * 4;
  const sideHeight = Math.max(a.height, b.height) + gap * 2;
  const side = { width: sideWidth, height: sideHeight, pixels: Buffer.alloc(sideWidth * sideHeight * 4) };
  for (let i = 0; i < sideWidth * sideHeight; i++) side.pixels.set([...GROUND, 255], i * 4);
  const paste = (picture, left, isFlat) => {
    for (let y = 0; y < picture.height; y++)
      for (let x = 0; x < picture.width; x++) {
        const at = ((y + gap) * sideWidth + x + left) * 4;
        if (isFlat) for (let c = 0; c < 3; c++) side.pixels[at + c] = picture.rgb[(y * picture.width + x) * 3 + c];
        else picture.pixels.copy(side.pixels, at, (y * picture.width + x) * 4, (y * picture.width + x) * 4 + 4);
        side.pixels[at + 3] = 255;
      }
  };
  paste(a, gap, true);
  paste(b, gap * 2 + a.width, true);
  paste(diff, gap * 3 + a.width + b.width, false);
  return { mad, banded, diff, side };
}

/** The mean difference of each band of the mock at the vertical offset in the app's picture where
 *  it is least, every second pixel of a row, weighted by the band's height. */
function bandedDifference(a, b, band = 32, reach = 80) {
  const width = Math.min(a.width, b.width);
  let total = 0;
  let rows = 0;
  for (let top = 0; top < a.height; top += band) {
    const height = Math.min(band, a.height - top);
    let best = Infinity;
    for (let shift = -reach; shift <= reach; shift += 2) {
      if (top + shift < 0 || top + shift + height > b.height) continue;
      let sum = 0;
      for (let y = 0; y < height; y++) {
        const ra = (top + y) * a.width * 3;
        const rb = (top + shift + y) * b.width * 3;
        for (let x = 0; x < width; x += 2) {
          const ia = ra + x * 3;
          const ib = rb + x * 3;
          sum += Math.abs(a.rgb[ia] - b.rgb[ib]) + Math.abs(a.rgb[ia + 1] - b.rgb[ib + 1]) + Math.abs(a.rgb[ia + 2] - b.rgb[ib + 2]);
        }
        if (sum >= best * height * Math.ceil(width / 2) * 3) break;
      }
      best = Math.min(best, sum / (height * Math.ceil(width / 2) * 3));
    }
    if (best === Infinity) best = 255;
    total += best * height;
    rows += height;
  }
  return rows ? total / rows : 255;
}

// MARK: - Main

function main() {
  const { values } = parseArgs({
    options: {
      only: { type: "string" },
      tone: { type: "string", default: "both" },
      app: { type: "string", default: join(root, ".build/debug/VoiceMeetMac") },
      drawn: { type: "string" },
      out: { type: "string", default: join(homedir(), ".cache/mac-app-night/fidelity") },
    },
  });
  const targets = values.only ? values.only.split(",") : Object.keys(VIEWS);
  const tones = values.tone === "both" ? ["dark", "light"] : [values.tone];
  mkdirSync(values.out, { recursive: true });

  let drawn = values.drawn;
  if (!drawn) {
    drawn = mkdtempSync(join(tmpdir(), "design-diff-app-"));
    execFileSync(values.app, ["--render-all", drawn], { stdio: ["ignore", "pipe", "pipe"], maxBuffer: 64 * 1024 * 1024 });
  }
  return run(targets, tones, drawn, values.out);
}

async function run(targets, tones, drawn, out) {
  const chrome = await startChrome();
  const scores = {};
  try {
    for (const target of targets) {
      const parts = VIEWS[target];
      if (!parts) throw new Error(`no view ${target}: ${Object.keys(VIEWS).join(", ")}`);
      for (const tone of tones) {
        const shots = await drawMock(chrome, join(root, "design/html", `${target}-${tone}.html`));
        if (shots.length !== parts.length) throw new Error(`${target}-${tone}: ${shots.length} components, ${parts.length} expected`);
        for (const [index, part] of parts.entries()) {
          const name = `${part.view}-${tone}`;
          const mock = shots[index].picture;
          const file = join(drawn, `${part.file}-${tone}.png`);
          if (!existsSync(file)) {
            scores[name] = { mad: null, note: `the app draws no ${part.file}` };
            writeFileSync(join(out, `${name}-side.png`), writePng(mock));
            continue;
          }
          const whole = readPng(readFileSync(file));
          const [top, right, bottom, left] = [part.pad ?? 0].flat().length === 1 ? Array(4).fill(part.pad ?? 0) : part.pad;
          let app = cut(whole, left * 2, top * 2, whole.width - (left + right) * 2, whole.height - (top + bottom) * 2);
          const size = [(app.width - mock.width) / 2, (app.height - mock.height) / 2];
          if (part.crop) app = cut(app, 0, 0, app.width, mock.height);
          const { mad, banded, diff, side } = compare(mock, app);
          writeFileSync(join(out, `${name}-side.png`), writePng(side));
          writeFileSync(join(out, `${name}-diff.png`), writePng(diff));
          scores[name] = {
            mad: Number(mad.toFixed(2)),
            banded: Number(banded.toFixed(2)),
            mock: [mock.width / 2, mock.height / 2],
            app: [app.width / 2, part.crop ? whole.height / 2 - top - bottom : app.height / 2],
            size: part.crop ? [size[0], null] : size,
          };
        }
      }
    }
  } finally {
    chrome.stop();
  }
  const file = join(out, "scores.json");
  const all = existsSync(file) ? JSON.parse(readFileSync(file, "utf8")) : {};
  writeFileSync(file, `${JSON.stringify({ ...all, ...scores }, null, 2)}\n`);
  for (const [name, score] of Object.entries(scores)) {
    const size = score.size ? ` size ${score.size.map((v) => (v === null ? "·" : (v > 0 ? "+" : "") + v)).join(" × ")} pt` : "";
    console.log(`${name.padEnd(28)} ${score.mad === null ? score.note : `mad ${score.mad.toFixed(2).padStart(6)}  banded ${score.banded.toFixed(2).padStart(6)}${size}`}`);
  }
  console.log(`Pictures and scores.json in ${out}.`);
}

await main();
