#!/usr/bin/env node
// fourier-lock.mjs: writes Sources/SpeechText/FourierLock.swift, the Python packages that run Oruk
// Fourier on this Mac (README, "Dictation"), each pinned to one version and to the SHA-256 of each of
// its files that a Mac with Apple silicon can install (macOS arm64 and pure-Python wheels).
//
//   node harness/fourier-lock.mjs [--exclude-newer 2026-11-24T22:00:00Z]
//
// uv resolves `mlx-audio` and `soundfile` for CPython 3.12 on macOS 14 or later, with no package
// newer than the date (the set that the speech bench measured, 25 November 2026); PyPI's JSON gives
// each file's hash. The app installs with `--require-hashes`: a file with another hash fails.
import { execFileSync } from "node:child_process";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { parseArgs } from "node:util";

const { values } = parseArgs({ options: { "exclude-newer": { type: "string", default: "2026-11-24T22:00:00Z" } } });
const requirements = "mlx-audio==0.6.7\nsoundfile\n";
const pins = execFileSync(
  "uv",
  [
    "pip", "compile", "-", "--python-version", "3.12", "--python-platform", "aarch64-apple-darwin", "--only-binary", ":all:",
    "--exclude-newer", values["exclude-newer"], "--no-header", "--no-annotate", "-q",
  ],
  { input: requirements, encoding: "utf8", env: { ...process.env, MACOSX_DEPLOYMENT_TARGET: "14.0" } },
)
  .split("\n")
  .map((line) => line.trim())
  .filter((line) => line && !line.startsWith("#"))
  .map((line) => line.split("=="));

/** A wheel that CPython 3.12 on macOS arm64 can install: its Python, ABI and platform tags. */
function fits(filename) {
  const parts = filename.replace(/\.whl$/, "").split("-");
  if (parts.length < 5) return false;
  const [python, abi, platform] = parts.slice(-3);
  const abis = abi.split(".").filter((tag) => tag === "none" || tag === "abi3" || tag === "cp312");
  // a stable ABI wheel (abi3) of an older CPython runs on 3.12 too
  const stable = (tag) => abis.includes("abi3") && /^cp3\d+$/.test(tag) && Number(tag.slice(3)) <= 12;
  const pythons = python.split(".").some((tag) => tag === "py3" || tag === "cp312" || tag === "py312" || stable(tag));
  const platforms = platform.split(".").some((tag) => tag === "any" || (/^macosx_/.test(tag) && /(arm64|universal2)$/.test(tag)));
  return pythons && abis.length > 0 && platforms;
}

const lines = [];
for (const [name, version] of pins) {
  const answer = await fetch(`https://pypi.org/pypi/${name}/${version}/json`);
  if (!answer.ok) throw new Error(`PyPI has no ${name} ${version}: ${answer.status}`);
  const files = (await answer.json()).urls.filter((file) => file.packagetype === "bdist_wheel" && fits(file.filename));
  if (!files.length) throw new Error(`${name} ${version} has no wheel for macOS arm64`);
  lines.push(`${name}==${version} ${files.map((file) => `--hash=sha256:${file.digests.sha256}`).join(" ")}`);
}

const swift = `// Written by harness/fourier-lock.mjs: do not edit by hand. The Python packages that run Oruk Fourier
// (\`FourierRuntime\`), resolved with no package newer than ${values["exclude-newer"]}: each one at one version, with
// the SHA-256 of each of its wheels for macOS arm64.

enum FourierLock {
    static let requirements = """
${lines.map((line) => `        ${line}`).join("\n")}
        """
}
`;
writeFileSync(join(import.meta.dirname, "../Sources/SpeechText/FourierLock.swift"), swift);
console.error(`${pins.length} packages, ${lines.reduce((sum, line) => sum + line.split("--hash").length - 1, 0)} hashes`);
