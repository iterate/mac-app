#!/usr/bin/env node
// snapshots.mjs: every view of the app, drawn now, against the drawings in harness/baselines/.
//
//   node harness/snapshots.mjs [--update] [--app .build/debug/VoiceMeetMac] [--out <folder>]
//
// The app draws every view, light and dark (`--render-all`, Sources/VoiceMeetMac/Rendering.swift),
// into <out> (a new temporary folder unless given). Each file is compared with its baseline:
//
// - On the macOS build that made the baselines (harness/baselines/made-on.json), the check is
//   strict: the sizes are equal, and at most 0.5% of the pixels differ by more than 24 in a channel.
// - On another build, the system's fonts and controls may draw a pixel or two otherwise. The check
//   is then of the layout: the sizes are within 2%, and at most 1% of the blocks of 16 × 16 pixels
//   differ by more than 24 in a channel's mean. A missing row, a wrapped line, a control that moved
//   or a colour that changed fails it; a glyph's antialiasing, or the whole view a point to the
//   side, does not (measured: 0.05% of the blocks). The strict differences are reported, and their
//   pictures written, but do not fail. The locked dictation pill is allowed 3%: its words are
//   anchored at their end, so a glyph a fraction of a point wider on another build moves every
//   word of the line (measured on macOS 15.8.2: 1.1% dark, 0.95% light, against 0.30% at most
//   for every other drawing).
//
// A file that fails gets a picture in <out>/diff/: the baseline, faded, with the differing pixels
// in red. The exit is 1 when a file fails, is missing, or has no baseline. `--update` writes the
// drawings as the new baselines and this Mac's build as their maker.
import { execFileSync } from "node:child_process";
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";
import { crc32, deflateSync, inflateSync } from "node:zlib";

const STRICT = { channel: 24, fraction: 0.005 };
const LAYOUT = { size: 0.02, block: 16, channel: 24, fraction: 0.01 };
/** Drawings whose words are anchored at their end, with the part of the blocks they may differ by. */
const LAYOUT_TAIL_TEXT = { "dictation-locked-dark.png": 0.03, "dictation-locked-light.png": 0.03 };

const root = join(import.meta.dirname, "..");
const baselines = join(import.meta.dirname, "baselines");
const madeOnFile = join(baselines, "made-on.json");

/** A PNG of 8 bits a channel, RGB or RGBA, not interlaced (what NSBitmapImageRep writes), as RGBA. */
export function readPng(bytes) {
  if (bytes.readUInt32BE(0) !== 0x89504e47) throw new Error("not a PNG");
  let at = 8;
  let width, height, depth, colorType, interlace;
  const data = [];
  while (at < bytes.length) {
    const length = bytes.readUInt32BE(at);
    const type = bytes.toString("latin1", at + 4, at + 8);
    const body = bytes.subarray(at + 8, at + 8 + length);
    if (type === "IHDR") {
      width = body.readUInt32BE(0);
      height = body.readUInt32BE(4);
      depth = body[8];
      colorType = body[9];
      interlace = body[12];
    } else if (type === "IDAT") data.push(body);
    else if (type === "IEND") break;
    at += 12 + length;
  }
  if (depth !== 8 || ![2, 6].includes(colorType) || interlace !== 0)
    throw new Error(`a PNG of depth ${depth}, colour type ${colorType}, interlace ${interlace} is not read`);
  const channels = colorType === 6 ? 4 : 3;
  const raw = inflateSync(Buffer.concat(data));
  const stride = width * channels;
  const pixels = Buffer.alloc(width * height * 4);
  let previous = Buffer.alloc(stride);
  for (let y = 0; y < height; y++) {
    const filter = raw[y * (stride + 1)];
    const line = Buffer.from(raw.subarray(y * (stride + 1) + 1, (y + 1) * (stride + 1)));
    for (let x = 0; x < stride; x++) {
      const left = x >= channels ? line[x - channels] : 0;
      const up = previous[x];
      const upLeft = x >= channels ? previous[x - channels] : 0;
      let add = 0;
      if (filter === 1) add = left;
      else if (filter === 2) add = up;
      else if (filter === 3) add = (left + up) >> 1;
      else if (filter === 4) {
        const p = left + up - upLeft;
        const [a, b, c] = [Math.abs(p - left), Math.abs(p - up), Math.abs(p - upLeft)];
        add = a <= b && a <= c ? left : b <= c ? up : upLeft;
      }
      line[x] = (line[x] + add) & 0xff;
    }
    for (let x = 0; x < width; x++) {
      for (let c = 0; c < 3; c++) pixels[(y * width + x) * 4 + c] = line[x * channels + c];
      pixels[(y * width + x) * 4 + 3] = channels === 4 ? line[x * channels + 3] : 255;
    }
    previous = line;
  }
  return { width, height, pixels };
}

export function writePng({ width, height, pixels }) {
  const chunk = (type, body) => {
    const head = Buffer.alloc(8);
    head.writeUInt32BE(body.length, 0);
    head.write(type, 4, "latin1");
    const tail = Buffer.alloc(4);
    tail.writeUInt32BE(crc32(Buffer.concat([head.subarray(4), body])), 0);
    return Buffer.concat([head, body, tail]);
  };
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width, 0);
  header.writeUInt32BE(height, 4);
  header.set([8, 6, 0, 0, 0], 8);
  const raw = Buffer.alloc(height * (width * 4 + 1));
  for (let y = 0; y < height; y++) pixels.copy(raw, y * (width * 4 + 1) + 1, y * width * 4, (y + 1) * width * 4);
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk("IHDR", header),
    chunk("IDAT", deflateSync(raw)),
    chunk("IEND", Buffer.alloc(0)),
  ]);
}

/** The pixels that differ by more than `channel` in a channel, and a picture of them. */
export function pixelDifference(a, b, channel) {
  const diff = Buffer.alloc(a.pixels.length);
  let differing = 0;
  for (let i = 0; i < a.pixels.length; i += 4) {
    let most = 0;
    for (let c = 0; c < 4; c++) most = Math.max(most, Math.abs(a.pixels[i + c] - b.pixels[i + c]));
    const grey = (a.pixels[i] + a.pixels[i + 1] + a.pixels[i + 2]) / 3;
    if (most > channel) {
      differing++;
      diff.set([255, 0, 0, 255], i);
    } else diff.set([grey, grey, grey, 70], i);
  }
  return { fraction: differing / (a.width * a.height), picture: { width: a.width, height: a.height, pixels: diff } };
}

/** The part of the `size` × `size` blocks whose mean differs by more than `channel` in a channel.
 *  Images of different sizes are compared over the part they share, from the top left. */
export function blockDifference(a, b, { block, channel }) {
  const width = Math.min(a.width, b.width);
  const height = Math.min(a.height, b.height);
  let blocks = 0;
  let differing = 0;
  for (let by = 0; by + block <= height; by += block) {
    for (let bx = 0; bx + block <= width; bx += block) {
      const sums = [0, 0, 0, 0, 0, 0, 0, 0];
      for (let y = by; y < by + block; y++) {
        for (let x = bx; x < bx + block; x++) {
          for (let c = 0; c < 4; c++) {
            sums[c] += a.pixels[(y * a.width + x) * 4 + c];
            sums[4 + c] += b.pixels[(y * b.width + x) * 4 + c];
          }
        }
      }
      blocks++;
      const n = block * block;
      if ([0, 1, 2, 3].some((c) => Math.abs(sums[c] - sums[4 + c]) / n > channel)) differing++;
    }
  }
  return blocks ? differing / blocks : 0;
}

const thisBuild = () =>
  `${execFileSync("sw_vers", ["-productVersion"], { encoding: "utf8" }).trim()} (${execFileSync("sw_vers", ["-buildVersion"], { encoding: "utf8" }).trim()})`;

function main() {
  const { values } = parseArgs({
    options: {
      update: { type: "boolean" },
      app: { type: "string", default: join(root, ".build/debug/VoiceMeetMac") },
      out: { type: "string" },
    },
  });
  const out = values.out ?? mkdtempSync(join(tmpdir(), "iterate-snapshots-"));
  mkdirSync(out, { recursive: true });
  // the app's libraries talk on stdout and stderr: what they said is shown only when the drawing failed
  try {
    execFileSync(values.app, ["--render-all", out], { stdio: ["ignore", "pipe", "pipe"], maxBuffer: 64 * 1024 * 1024 });
  } catch (error) {
    process.stderr.write(String(error.stderr ?? "").slice(-4000));
    throw new Error(`${values.app} --render-all did not draw every view (exit ${error.status})`);
  }
  const drawn = readdirSync(out).filter((name) => name.endsWith(".png")).sort();
  const build = thisBuild();

  if (values.update) {
    mkdirSync(baselines, { recursive: true });
    for (const name of drawn) copyFileSync(join(out, name), join(baselines, name));
    writeFileSync(madeOnFile, `${JSON.stringify({ macOS: build }, null, 2)}\n`);
    const stale = readdirSync(baselines).filter((name) => name.endsWith(".png") && !drawn.includes(name));
    console.log(`Wrote ${drawn.length} baselines, made on macOS ${build}.`);
    for (const name of stale) console.log(`Stale: harness/baselines/${name} is drawn no more: git rm it.`);
    return;
  }

  const madeOn = existsSync(madeOnFile) ? JSON.parse(readFileSync(madeOnFile, "utf8")).macOS : "none";
  const strict = madeOn === build;
  console.log(
    strict
      ? `Strict check: this Mac's macOS ${build} made the baselines.`
      : `Layout check: the baselines were made on macOS ${madeOn}, this is ${build}; pixel differences are reported, not failed.`,
  );
  const failed = [];
  const noted = [];
  const known = existsSync(baselines) ? readdirSync(baselines).filter((name) => name.endsWith(".png")) : [];
  for (const name of known.filter((name) => !drawn.includes(name))) failed.push(`${name}: has a baseline and was not drawn`);
  for (const name of drawn) {
    if (!known.includes(name)) {
      failed.push(`${name}: has no baseline (node harness/snapshots.mjs --update)`);
      continue;
    }
    const now = readPng(readFileSync(join(out, name)));
    const base = readPng(readFileSync(join(baselines, name)));
    const size = `${base.width}×${base.height} → ${now.width}×${now.height}`;
    const sameSize = now.width === base.width && now.height === base.height;
    const pixels = sameSize ? pixelDifference(base, now, STRICT.channel) : undefined;
    const pixelsFail = !sameSize || pixels.fraction > STRICT.fraction;
    if (pixels && pixelsFail) {
      mkdirSync(join(out, "diff"), { recursive: true });
      writeFileSync(join(out, "diff", name), writePng(pixels.picture));
    }
    const pixelWords = pixels ? `${(pixels.fraction * 100).toFixed(2)}% of the pixels differ` : `the size changed, ${size}`;
    if (strict) {
      if (pixelsFail) failed.push(`${name}: ${pixelWords}`);
      continue;
    }
    const sizeOff = Math.max(Math.abs(now.width - base.width) / base.width, Math.abs(now.height - base.height) / base.height);
    const blocks = blockDifference(base, now, LAYOUT);
    if (sizeOff > LAYOUT.size) failed.push(`${name}: the size changed, ${size}`);
    else if (blocks > (LAYOUT_TAIL_TEXT[name] ?? LAYOUT.fraction)) failed.push(`${name}: ${(blocks * 100).toFixed(1)}% of the blocks differ`);
    else if (pixelsFail) noted.push(`${name}: ${pixelWords} (another macOS build: not failed)`);
  }
  for (const line of noted) console.log(`  note: ${line}`);
  for (const line of failed) console.log(`  FAIL: ${line}`);
  console.log(`${drawn.length} drawings in ${out}${existsSync(join(out, "diff")) ? `, the differences in ${join(out, "diff")}` : ""}.`);
  if (failed.length) {
    console.log(`${failed.length} failed. A change you meant: node harness/snapshots.mjs --update, and look at the new baselines.`);
    process.exit(1);
  }
  console.log("All match.");
}

if (process.argv[1] && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) main();
