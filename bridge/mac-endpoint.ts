// mac-endpoint.ts: this Mac's iterate menu-bar app, lent to a mind.
//
//   iterate provide <this package>/bridge/mac-endpoint.ts --name jonas.mac --mind <address>
//
// The mind then has `itx.jonas.mac`: the screen, the camera, the microphone, the speakers, the accessibility tree
// of the window in front, banners on the screen (a call's among them), and commands that run with
// the app's permissions: the inputs, outputs and compute of a device that a person is often near. This file holds no
// capture code and no permission: it asks the app on its local socket (LocalEndpoint.swift), one
// line of JSON for each call. The app holds the permissions of macOS, shows each use in the menu
// bar, and its owner chooses for each thing: off, ask or shared. It imports nothing but Node.
//
// When the app does not run, this file builds and opens it first (run-on-mac.sh beside it; that
// needs the Command Line Tools). So the one command above is the whole start on a Mac.
import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { connect } from "node:net";
import { homedir } from "node:os";
import { join } from "node:path";
import { pages } from "./pages.mjs";

/** What agents read next to the name. The mind refuses a lend whose description is over 500
 *  characters ("a rewrite rule's description is one line: a string of at most 500 chars"), and the
 *  lend then never goes live: keep this well under it. The detail is in `instructions` below. */
export const description =
  "A person's Mac as an endpoint device, through its iterate menu-bar app. Inputs: screen, camera, microphone, the front window as text. Outputs: speakers, banners (banner.show; call.ring rings). Compute: commands; http(): its own pages. Record into the mind: record.state, record.set. Live: live.state, live.end. Into a call: call.publish. A person is often near it: state().presence says if one is likely there now. The owner sets each thing to off, ask or shared, and sees each use in the menu bar.";

/** The app's socket: in its own home when the app has one (`ITERATE_MAC_HOME`, AppEnvironment.swift). */
const socketPath = process.env.ITERATE_MAC_HOME
  ? join(process.env.ITERATE_MAC_HOME, "endpoint.sock")
  : join(homedir(), "Library/Application Support/voice-meet-mac/endpoint.sock");

type Answer = Record<string, unknown>;

/** One question to the app: one connection, one line out, one line back. */
function ask(method: string, parameters: Record<string, unknown> = {}): Promise<Answer> {
  return new Promise((resolve, reject) => {
    const socket = connect(socketPath);
    let received = "";
    socket.setEncoding("utf8");
    socket.on("connect", () => socket.write(`${JSON.stringify({ ...parameters, method })}\n`));
    socket.on("data", (chunk: string) => (received += chunk));
    socket.on("error", (error: NodeJS.ErrnoException) =>
      reject(
        error.code === "ENOENT" || error.code === "ECONNREFUSED"
          ? new Error(APP_NOT_RUNNING)
          : error,
      ),
    );
    socket.on("end", () => {
      const answer = appAnswerOf(received);
      if ("ok" in answer) resolve(answer.ok);
      else reject(new Error(answer.error));
    });
  });
}

/** The app's one line of answer (LocalEndpoint.swift): `{ ok: {...} }` or `{ error: "..." }`. */
function appAnswerOf(text: string): { ok: Answer } | { error: string } {
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    return { error: "The iterate menu-bar app gave an answer that is no JSON." };
  }
  if (!(parsed instanceof Object)) return { error: "The iterate menu-bar app gave no answer." };
  if ("ok" in parsed && parsed.ok instanceof Object) return { ok: { ...parsed.ok } };
  if ("error" in parsed && parsed.error) return { error: String(parsed.error) };
  return { error: "The iterate menu-bar app gave no answer." };
}

const APP_NOT_RUNNING = "The iterate menu-bar app is not running on this Mac: its owner starts it.";

/** The app answers, or it is built, opened and then answers. `iterate provide` calls this through
 *  the default export on each connection, on the person's own command. */
async function ensureTheAppRuns(): Promise<void> {
  const answers = () =>
    ask("state").then(
      () => true,
      (error: Error) => {
        if (error.message === APP_NOT_RUNNING) return false;
        throw error;
      },
    );
  if (await answers()) return;
  // Run by the app itself (Lend.swift) or by the installer: the app is not this file's to start; it
  // may have been quit on purpose.
  if (process.env.ITERATE_MAC_APP_SUPERVISED) throw new Error(APP_NOT_RUNNING);
  // Installed: open it. Else build, install and open it (run-on-mac.sh beside this file).
  const installed = existsSync("/Applications/iterate.app");
  console.error(
    `The iterate menu-bar app is not running. ${installed ? "Opening" : "Building, installing and opening"} it...`,
  );
  const [command, args] = installed
    ? ["/usr/bin/open", ["/Applications/iterate.app"]]
    : ["/bin/sh", [join(import.meta.dirname, "..", "run-on-mac.sh")]];
  const exitCode = await new Promise<number>((resolve, reject) => {
    // The script's own words go to stderr: stdout is `iterate provide`'s, for the lent name.
    const child = spawn(command, args, { stdio: ["ignore", process.stderr, process.stderr] });
    child.on("error", reject);
    child.on("close", (code) => resolve(code ?? 1));
  });
  if (exitCode !== 0) throw new Error(`${command} ended with ${exitCode}: the app did not open.`);
  for (let attempt = 0; attempt < 40; attempt++) {
    if (await answers()) return;
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  throw new Error("The iterate menu-bar app was opened and does not answer on its socket.");
}

/** This Mac's pages (pages.mjs), on the app's socket. */
const served = pages({ ask });

const bytes = (base64: unknown) => new Uint8Array(Buffer.from(String(base64 || ""), "base64"));

async function run(
  argv: string[],
  options: { stdin?: string | Uint8Array; timeoutSeconds?: number } = {},
) {
  const { stdoutBase64, stderrBase64, ...rest } = await ask("run", {
    argv,
    stdinBase64: Buffer.from(options.stdin || "").toString("base64"),
    timeoutSeconds: options.timeoutSeconds,
  });
  return { ...rest, stdout: bytes(stdoutBase64), stderr: bytes(stderrBase64) };
}

/** A script's output as text: what an agent reads. */
function asText({ stdout, stderr, ...rest }: Awaited<ReturnType<typeof run>>) {
  return {
    ...rest,
    stdout: Buffer.from(stdout).toString(),
    stderr: Buffer.from(stderr).toString(),
  };
}

/** The app's answer to a snapshot, with the JPEG as bytes. */
function picture({ jpegBase64, ...size }: Answer) {
  return { ...size, jpeg: bytes(jpegBase64) };
}

type BannerAnswer =
  | { pressed: string }
  | { pressed: null; why: "no answer" | "dismissed" | "replaced" | "off"; words: string };

/** The app's answer to `banner.show` (Banner.swift `Banners.show`), read: one this bridge does not
 *  know is an error, never a guess. */
function bannerAnswerOf(answer: Answer): BannerAnswer {
  if (typeof answer.pressed === "string") return { pressed: answer.pressed };
  const { why } = answer;
  if (why === "no answer" || why === "dismissed" || why === "replaced" || why === "off")
    return { pressed: null, why, words: String(answer.words ?? "") };
  throw new Error(
    "The iterate menu-bar app gave an answer to banner.show that this bridge does not know.",
  );
}

type RingAnswer =
  | { accepted: true }
  | { accepted: false; why: "declined" | "no answer" | "replaced" | "off"; words: string };

/** The app's answer to `call.ring` (Banner.swift `Banners.ring`), read the same way. */
function ringAnswerOf(answer: Answer): RingAnswer {
  if (answer.accepted === true) return { accepted: true };
  const { why } = answer;
  if (why === "declined" || why === "no answer" || why === "replaced" || why === "off")
    return { accepted: false, why, words: String(answer.words ?? "") };
  throw new Error(
    "The iterate menu-bar app gave an answer to call.ring that this bridge does not know.",
  );
}

/** A banner on the screen (`banner.show`). */
type BannerInput = {
  title: string;
  body?: string;
  buttons?: {
    label: string;
    style?: "accept" | "decline" | "plain";
    /** An SF Symbol's name. */
    symbol?: string;
    /** A page of this mind, opened after the press. */
    open?: string;
  }[];
  sound?: "ring" | "chime" | "none";
  seconds?: number;
};

/** The switches of the record (`record.set`): each left out stays as it is. */
type RecordSwitches = {
  screens?: boolean;
  cameras?: boolean;
  mics?: boolean;
  speakers?: boolean;
  windowText?: boolean;
};

/** The record's state (`record.state`), as DeviceRecord.swift and AppModel.swift give it. */
type RecordState = {
  sources: { screens: boolean; cameras: boolean; mics: boolean; speakers: boolean };
  windowText: boolean;
  recording: boolean;
  paused: boolean;
  line: string;
  tracks: string[];
  waitingSlots: number;
  uploadFailure?: string;
  mind?: string;
  device?: string;
};

/** Who watches this Mac live now (`live.state`), as DeviceLive.swift gives it. */
type LiveState = {
  watchers: { watcher: string; who: string; tracks: string[]; since: number }[];
  signalling: boolean;
};

/** This Mac's cameras and screens in calls (`call.state`, `call.publish`), as DeviceCall.swift
 *  gives it: each publication, its call, its source, since when (Unix ms) and whether its picture
 *  reaches the call's SFU yet. */
type CallState = {
  publications: { publication: string; context: string; source: string; since: number; connected: boolean; who: string }[];
};

/** THE PROVIDED OBJECT: what `iterate provide` lends. Each call fails with the app's own words
 *  when the owner has the thing off, does not approve the use, or macOS has not given the app the
 *  permission. */
export default async function macEndpoint() {
  await ensureTheAppRuns();
  return {
    /** Every thing of the Mac (each display, each camera, the microphone, the speakers, the window
     *  text, banners, commands) with its `sharing`: "shared", "ask" (the owner approves each use) or "off".
     *  `presence`: whether a person is likely at the Mac now. `idleSeconds` since the last key
     *  press, mouse move or click in any app; `screenLocked` (or another user's session in front);
     *  `displayAsleep` (every display). Idle under a few minutes, not locked and a display awake
     *  is the sign that a person is likely there; it says nothing of who. `record`: the record's
   *  short state (`record.state()` has all of it). */
    state: () => ask("state"),
    screen: {
      /** One still picture of a whole display, as JPEG bytes. `display` is the number
       *  in `state().things`; with none it is the first display that is not off. */
      snapshot: (input: { display?: number; maxWidth?: number } = {}) =>
        ask("screen.snapshot", input).then(picture),
    },
    camera: {
      /** One still picture of a camera, as JPEG bytes. `camera` is a name from `state().things`;
       *  with none it is the first camera that is not off. The camera runs only for the call. */
      snapshot: (input: { camera?: string; maxWidth?: number } = {}) =>
        ask("camera.snapshot", input).then(picture),
    },
    microphone: {
      /** Some seconds (5 unless said, at most 60) of the microphone, as a WAV file's bytes: one
       *  channel, 16 bits, about 16 000 samples a second. */
      async listen(input: { seconds?: number } = {}) {
        const { wavBase64, ...rest } = await ask("microphone.listen", input);
        return { ...rest, wav: bytes(wavBase64) };
      },
    },
    speaker: {
      /** Play a sound through the Mac's speakers: the bytes of a WAV, AIFF, MP3 or AAC file, at
       *  most 300 s long. The call returns when the sound has ended. */
      play: (sound: Uint8Array) =>
        ask("speaker.play", { soundBase64: Buffer.from(sound).toString("base64") }),
      /** Say words through the Mac's speakers in the system's voice. */
      say: (words: string) => ask("speaker.say", { words }),
    },
    accessibility: {
      /** The window in front as a tree of roles, titles and values: text, not a picture. */
      frontWindow: (input: { maxDepth?: number; maxNodes?: number } = {}) =>
        ask("accessibility.frontWindow", input),
    },
    /** Run `argv` (never a shell line) as a child of the app, so with the app's permissions for
     *  the screen, the camera, the microphone and Accessibility. */
    run,
    /** Run an AppleScript on the Mac: the plainest way to use its apps. The first script that
     *  controls another app makes macOS ask the owner once for that app. */
    appleScript: (source: string, options: { timeoutSeconds?: number } = {}) =>
      run(["/usr/bin/osascript", "-e", source], options).then(asText),
    /** Run a Swift program on the Mac, given as source. It needs the Command Line Tools there. */
    swift: (source: string, options: { timeoutSeconds?: number } = {}) =>
      run(["/usr/bin/swift", "-"], { ...options, stdin: source }).then(asText),
    banner: {
      /** Show a banner on the Mac's screen: an output, beside the speakers. `title` (one line),
       *  `body` (two lines at most), one to three `buttons` (default one "OK"), a `sound` ("chime"
       *  unless said) and `seconds` (30 unless said; 5 to 120). The button that Return presses is
       *  the first `accept`, else the first. A button with `open` opens that page in the browser
       *  after its press: https on this mind's own domain, else the banner is refused before it
       *  shows. Answers the label pressed, or why none was. One banner at a time (a newer one
       *  replaces it, but never a call), at most 6 a minute. */
      show: (input: BannerInput) => ask("banner.show", input).then(bannerAnswerOf),
    },
    record: {
      /** The record of this Mac into the mind (`/devices/<name>/record/`): which sources are on,
       *  whether it records or is paused (the Mac is locked or asleep), its tracks, the slots that
       *  wait for upload. Reading it is no use of the Mac's powers. */
      state: () => ask("record.state") as Promise<RecordState>,
      /** Turns sources of the record on or off; returns the new state. Off is always allowed. On is
       *  a use of that power under the owner's choice, as a snapshot is: Screens and Speakers go by
       *  every display's, Camera by every camera's, Microphone by the microphone's, Window text by
       *  the window text's. Off refuses, Ask asks the owner, Shared does it; Activity shows it. The
       *  sources turned off stay off when a source turned on is then refused. */
      set: (input: RecordSwitches) => ask("record.set", input) as Promise<RecordState>,
    },
    live: {
      /** Who watches this Mac live now: each watcher's id, who it is (an email or a name), its
       *  tracks (`screen-<display>`, `camera-0`, `mic-0`) and since when (Unix ms). A watch starts
       *  from a member's page (record.<domain>), never from here; the owner's choices for the
       *  screen, the camera and the microphone decide what it gets. Reading it is no use. */
      state: () => ask("live.state") as Promise<LiveState>,
      /** Ends one watch now: the page hears `bye`. Always allowed. */
      end: (input: { watcher: string }) => ask("live.end", input) as Promise<LiveState>,
    },
    call: {
      /** A banner that looks like a call: `from` (who calls; the agent's path when none) and
       *  `reason`, Decline and Accept as round phone buttons, the ring sound, 30 s. Accept opens
       *  `url`: by default the agent's page in the Dash, which opens the call's lobby: the person
       *  checks their camera and sound, then presses Join now. */
      ring: (input: { agent: string; from?: string; reason?: string; url?: string }) =>
        ask("call.ring", input).then(ringAnswerOf),
      /** Sends a screen (`"screen:<display>"`, the number in `state().things`) or the camera
       *  (`"camera"`) of this Mac into the call on `context` (an agent's path, as Meet's page has
       *  it), as a participant of its own that the call names "<the owner>'s Mac". It is a use of
       *  that display or camera under the owner's choice: Off refuses, Ask asks once with Touch ID,
       *  Shared sends it; Activity shows it while it runs. One screen and one camera for each call:
       *  a second screen replaces the first. `as`: the asking page's subscription row; when it
       *  leaves the call, this ends too. Answers when the picture reaches the call. */
      publish: (input: { context: string; source: string; as?: string }) =>
        ask("call.publish", input) as Promise<CallState>,
      /** Ends a publication: by its id, or every one of a `context` (and `source`). Always allowed. */
      unpublish: (input: { publication?: string; context?: string; source?: string }) =>
        ask("call.unpublish", input) as Promise<CallState>,
      /** This Mac's publications now. Reading it is no use. */
      state: () => ask("call.state") as Promise<CallState>,
    },
    /** This Mac's own pages, from the files of `pages/` in this package, under the owner's choice
     *  for Pages (and for the display, for the live view). `/`: the page; `/state.json`: this
     *  Mac's name, its lend, the record and the newest acts; `/live.mjpeg`: the main display (or
     *  `?display=N`) as multipart/x-mixed-replace JPEG frames, at most 4 a second and 1280 px
     *  wide, at most 2 at once, for at most 10 minutes; a cancel of the body ends it. A refusal is
     *  a status (403; 503 when the app does not run) with the owner's words. The answer's `body` is
     *  a string, bytes or a ReadableStream of bytes: a mind's site returns `new Response(body,
     *  { status, headers })` (pages/MIND-ROUTE.md). */
    http: (request: { method?: string; path: string; query?: Record<string, string>; headers?: Record<string, string> }) =>
      served.http(request) as Promise<{ status: number; headers: Record<string, string>; body: string | Uint8Array | ReadableStream<Uint8Array> }>,
    __describe() {
      return {
        instructions: `${description} Say what you looked at or did, and why.`,
        types:
          "state(): Promise<{ things: { thing: string; kind: 'screen' | 'camera' | 'microphone' | 'speaker' | 'banners' | 'accessibility' | 'commands' | 'pages'; name: string; sharing: 'off' | 'ask' | 'shared'; permitted: boolean; uses: number; display?: number }[]; microphone: string; presence: { idleSeconds: number; screenLocked: boolean; displayAsleep: boolean }; record: { recording: boolean; paused: boolean; line: string }; live: { watchers: string[] } }>; screen.snapshot(input?: { display?: number; maxWidth?: number }): Promise<{ jpeg: Uint8Array; pixelWidth: number; pixelHeight: number }>; camera.snapshot(input?: { camera?: string; maxWidth?: number }): Promise<{ jpeg: Uint8Array; pixelWidth: number; pixelHeight: number }>; microphone.listen(input?: { seconds?: number }): Promise<{ wav: Uint8Array; seconds: number }>; speaker.play(sound: Uint8Array): Promise<{ seconds: number }>; speaker.say(words: string): Promise<{ characters: number }>; accessibility.frontWindow(input?: { maxDepth?: number; maxNodes?: number }): Promise<{ application: string; bundleIdentifier: string; window?: object; truncated: boolean }>; run(argv: string[], options?: { stdin?: string | Uint8Array; timeoutSeconds?: number }): Promise<{ exitCode: number; timedOut: boolean; stdout: Uint8Array; stderr: Uint8Array }>; appleScript(source: string, options?: { timeoutSeconds?: number }): Promise<{ exitCode: number; timedOut: boolean; stdout: string; stderr: string }>; swift(source: string, options?: { timeoutSeconds?: number }): Promise<{ exitCode: number; timedOut: boolean; stdout: string; stderr: string }>; banner.show(input: { title: string; body?: string; buttons?: { label: string; style?: 'accept' | 'decline' | 'plain'; symbol?: string; open?: string }[]; sound?: 'ring' | 'chime' | 'none'; seconds?: number }): Promise<{ pressed: string } | { pressed: null; why: 'no answer' | 'dismissed' | 'replaced' | 'off'; words: string }>; call.ring(input: { agent: string; from?: string; reason?: string; url?: string }): Promise<{ accepted: true } | { accepted: false; why: 'declined' | 'no answer' | 'replaced' | 'off'; words: string }>; call.publish(input: { context: string; source: 'camera' | `screen:${number}`; as?: string }): Promise<CallState> (a screen or the camera into a meet call on an agent's context, as a participant of its own; a use under that thing's choice); call.unpublish(input: { publication?: string; context?: string; source?: string }): Promise<CallState> (always allowed); call.state(): Promise<CallState>; record.state(): Promise<RecordState>; record.set(input: { screens?: boolean; cameras?: boolean; mics?: boolean; speakers?: boolean; windowText?: boolean }): Promise<RecordState> (a source turned on is a use under its power's choice; off is always allowed); live.state(): Promise<LiveState>; live.end(input: { watcher: string }): Promise<LiveState> (ends a watch; always allowed); http(request: { method?: 'GET'; path: '/' | '/state.json' | '/live.mjpeg'; query?: { display?: string }; headers?: Record<string, string> }): Promise<{ status: number; headers: Record<string, string>; body: string | Uint8Array | ReadableStream<Uint8Array> }> (this Mac's own pages; a site returns new Response(body, { status, headers })); type CallState = { publications: { publication: string; context: string; source: string; since: number; connected: boolean; who: string }[] }; type LiveState = { watchers: { watcher: string; who: string; tracks: string[]; since: number }[]; signalling: boolean }; type RecordState = { sources: { screens: boolean; cameras: boolean; mics: boolean; speakers: boolean }; windowText: boolean; recording: boolean; paused: boolean; line: string; tracks: string[]; waitingSlots: number; uploadFailure?: string; mind?: string; device?: string };",
      };
    },
  };
}
