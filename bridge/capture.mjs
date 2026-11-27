// capture.mjs: the job `capture` of mind.mjs: one capture's folder (Sources/VoiceMeetMac/Capture.swift)
// into a mind, as files under /captures/<id>/, and the short text that a person pastes to an agent.
//
// The app sends its first line when a capture starts, `{ job: "capture", capture: <id>, folder,
// heardBy }`, so that the slow parts are done before the capture ends: on the connection of
// mind.mjs (the person's own sign-in: `iterate login`; the Mac's key lends and does nothing else)
// it asks for a signed upload link for every file a capture can have. Each later line names the
// capture and one step:
//   put: <file>     a file of the folder is whole: PUT it now (a picture, while the capture runs)
//   segment: {…}    words of the voice, final: `{ t, to, text, words }`, in milliseconds from the
//                   capture's start. The app hears the voice on this Mac (`heardBy` names its
//                   speech model) and sends each segment at the pause that ends it, so that at the
//                   end only the last words are missing
//   heard: true     every segment came: the words are whole, and transcript.json is written
//   copy: true      the person ended the capture: capture.json has every mark and numbered picture.
//                   The text goes out AT ONCE ({ copy }), before the movie is whole. Then the last
//                   words come, a model says what is under each mark (seen.json), summary.md goes
//                   up, and `capture/ready` is added to the context /captures/<id>
//   finish: true    the movie is whole: PUT the rest, capture.json once; `capture/received` is
//                   added. With the microphone on it waits first for `heard` (at most 15 s): the
//                   last words can come after the movie
// The connection is the one that is up at each call (a capture outlives a reconnect), and each
// event has the idempotency key `<type>/<id>`.
//   discard: true   remove what went up
// A capture whose first line is `finish` stayed on this Mac: it does `copy` and `finish` at once,
// with the words of its transcript.json (README, "Capture").
//
// It says { progress } (0 to 1, of the bytes); { copy }, the text for the clipboard, at `copy` and
// again when the last words are in it; then { done: true }, { failed, copy } (the reason; `copy`
// then names this Mac's folder alone) or { discarded: true }.
//
// WHO READS THE TEXT, AND HOW:
//   - an agent on this Mac reads the numbered pictures from the folder;
//   - any other agent makes the text's one call, `itx.getScrawl("<id>")`: the mind's own lookup
//     of a capture by its id (THE BOUNDARY, below). It answers the words, the marks, and the
//     pictures under "itx/images", which the mind's MCP tool `run` answers as images; an agent of
//     the mind names itself (`showTo`) and gets the pictures as the files of a message, the way
//     such an agent is shown an image. While the capture still arrives it says `pending`;
//   - in a mind that has no such lookup the text holds one script instead, which does the same
//     with the mind's files: it waits for `capture/ready` and answers context.json;
//   - a mind whose MCP tool answers no image gives text alone. For that reader a model reads each
//     picture once (seen.json): a claim, not an observation.
//
// THE BOUNDARY with the mind (27 Nov 2026). This app makes the capture: its id, the files under
// /captures/<id>/ (README, "Capture"), and the events `capture/ready` and `capture/received` on the
// context /captures/<id>. The MIND reads it: `itx.getScrawl(id, { waitMs?, showTo?, urls? })` is
// code of the mind's config (apps/scrawl/ of iterate.com's config), behind the mind's rule
// `itx.getScrawl`. It answers `{ state: "ready" | "pending" | "unknown", … }` from those files and
// events alone, and it decides who may read. The app asks once, at a capture's start, whether the
// mind has the rule (`itx.rewriteRules.get("itx.getScrawl")`), and writes the short text when it
// has. The id is a name and no key: the text holds no link and no path of the mind.
import { existsSync, readFileSync, readdirSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { isConnectionError } from "./mind-connection.mjs";
import { putFile } from "./upload.mjs";

/**
 * One capture on `link` (mind.mjs), for the mind `mind` (its address, for the text). `take(line)`
 * takes each line of the app; `say` hears what it says. A capture made at its `finish` (`kept`)
 * reads the words of its transcript.json. With no connection in `withinMs`, it fails at `finish`.
 */
export function captureUpload({
  link,
  mind,
  capture,
  folder,
  heardBy: heardByModel = "the Mac's speech model",
  kept = false,
  say,
  withinMs = 60_000,
  lastWordsMs = 15_000,
}) {
  const directory = `/captures/${capture}`;

  /** `call(itx)` on the connection that is up now, and once more on the next one when the
   *  connection broke under it: a capture outlives a reconnect. */
  async function onMind(call) {
    for (let tries = 1; ; tries++) {
      const connection = await link.now(withinMs);
      try {
        return await call(connection.itx);
      } catch (error) {
        if (tries >= 2 || !isConnectionError(error)) throw error;
        link.broke(connection, error);
      }
    }
  }
  /** One event of the capture's context, once: a second try of an event that went is no second event. */
  const append = (type, payload) =>
    onMind((itx) => itx.cd(directory).append({ type, payload, idempotencyKey: `${type}/${capture}` })).catch((error) => {
      if (error?.code !== "IDEMPOTENCY_CONFLICT") throw error;
    });
  /** Does the mind have its own lookup of a capture, `itx.getScrawl` (THE BOUNDARY, above)? Asked
   *  once, at the capture's start. Until the answer is here, and in a mind that has none, the text
   *  holds the one script. */
  let mindLooksUp = false;
  const lookedFor = onMind((itx) => itx.rewriteRules.get("itx.getScrawl")).then(
    (rule) => {
      mindLooksUp = Boolean(rule);
    },
    () => {},
  );
  /** What a file needs of the connection: its way through it when the signed route fails. */
  const r2 = { put: (...args) => onMind((itx) => itx.r2.put(...args)) };

  // Every file a capture can have (Capture.swift): the links are asked for before the files exist.
  const names = [
    "capture.json",
    "screen.mp4",
    "voice.m4a",
    "summary.md",
    "transcript.json",
    ...Array.from(
      { length: 12 },
      (_, index) => `pictures/${String(index + 1).padStart(2, "0")}.jpg`,
    ),
    // the numbered pictures: one for each mark and click, and all of them on one sheet
    ...Array.from({ length: 12 }, (_, index) => `${index + 1}.jpg`),
    "sheet.jpg",
    "seen.json",
    "context.json",
    ...Array.from({ length: 6 }, (_, index) => `accessibility/${index}.json`),
  ];

  /** The links: asked for at once, awaited when first needed. They are good on any connection. */
  const ready = (async () => {
    const urls = await onMind((itx) =>
      Promise.all(
        names.map((name) =>
          itx.r2.presign({
            key: `${directory.slice(1)}/${name}`,
            method: "PUT",
            expiresInSeconds: 3600,
          }),
        ),
      ),
    );
    return { links: Object.fromEntries(names.map((name, index) => [name, urls[index].url])) };
  })();
  // a failure is told at `finish`
  ready.catch(() => {});

  let bytesToSend = 0;
  let bytesSent = 0;
  let saidAt = 0;
  /** One file to its link, once: the same promise for a second ask. */
  const uploads = new Map();
  function put(file) {
    if (uploads.has(file)) return uploads.get(file);
    const path = join(folder, file);
    bytesToSend += statSync(path).size;
    const contentType =
      {
        json: "application/json",
        mp4: "video/mp4",
        m4a: "audio/mp4",
        jpg: "image/jpeg",
        md: "text/markdown; charset=utf-8",
        js: "text/javascript; charset=utf-8",
      }[file.split(".").pop()] ?? "application/octet-stream";
    const upload = ready.then(({ links }) =>
      putFile({
        r2,
        key: `${directory.slice(1)}/${file}`,
        path,
        contentType,
        url: links[file],
        said: (bytes) => {
          bytesSent += bytes;
          if (Date.now() - saidAt < 100) return;
          saidAt = Date.now();
          say({ progress: Math.min(bytesSent / bytesToSend, 1) });
        },
      }).catch((error) => {
        throw new Error(`The upload of ${file} failed: ${error?.message ?? error}`);
      }),
    );
    // a failure is told at `finish`, which awaits every upload
    upload.catch(() => {});
    uploads.set(file, upload);
    return upload;
  }

  // THE VOICE: the segments that the app heard on this Mac, in the order of time.
  const segmentsHeard = [];
  let heardBy = { kind: "model", id: heardByModel };
  /** Settles when the words are whole: at `heard`, or at `finish` for a capture that sent none. */
  let voiceIsWhole;
  const voiceWhole = new Promise((resolve) => {
    voiceIsWhole = resolve;
  });

  /** One segment: its words go where the capture's text and context.json read them. */
  function hear(segment) {
    segmentsHeard.push(segment);
    segmentsHeard.sort((a, b) => a.t - b.t);
  }

  /** The words so far: a model's claim about the voice, not an observation. */
  const transcriptSoFar = () => ({
    by: heardBy,
    basis: ["voice.m4a"],
    segments: segmentsHeard,
  });

  const clock = (ms) =>
    `${Math.floor(ms / 60_000)}:${String(Math.floor(ms / 1000) % 60).padStart(2, "0")}`;

  /** The text a person pastes to an agent. It is short on purpose: a line for each numbered picture
   *  with the words said at it, and the two ways to the pictures. `inTheMind` is false for a
   *  capture that stayed on this Mac. */
  function paste({ manifest, transcript, wordsPending, inTheMind = true }) {
    const { panels, observations } = manifest;
    const windows = observations.filter((observation) => observation.kind === "window");
    const front = (window) =>
      `${window.application ?? ""}${window.title ? ` “${window.title}”` : ""}${window.url?.startsWith("http") ? ` ${window.url}` : ""}`;
    // As a person talks and then points: words go to the first picture that ends after they start.
    const said = panels.map(() => []);
    for (const segment of transcript?.segments ?? []) {
      const at = panels.findIndex((panel) => panel.t >= segment.t);
      if (segment.text) said.at(at)?.push(segment.text);
    }
    const lines = panels.map((panel, index) => [
      panel.t,
      `- #${panel.n} (${clock(panel.t)}) ${panel.did}${panel.on ? ` ${panel.on}` : ""}${said[index].length ? ` “${said[index].join(" ")}”` : ""}`,
    ]);
    // another app or another page in front, not a title that changed
    windows.forEach((window, index) => {
      const before = windows[index - 1];
      if (before && (before.application !== window.application || before.url !== window.url))
        lines.push([window.t, `- (${clock(window.t)}) in front now: ${front(window)}`]);
    });
    lines.sort((a, b) => a[0] - b[0]);
    const files = panels.map((panel) => panel.file);
    const pictures =
      files.length < 2
        ? files[0] || "the pictures in pictures/"
        : `${existsSync(join(folder, "sheet.jpg")) ? "sheet.jpg and " : ""}${files.length > 4 ? `${files[0]} to ${files.at(-1)}` : files.join(", ")} together`;
    return [
      `[capture ${clock(manifest.durationMs)}${windows[0] ? ` · ${front(windows[0])}` : ""} · ${manifest.by.device}${inTheMind ? ` → ${mind}` : ""}]`,
      panels.some((panel) => panel.did !== "the screen at the end")
        ? `The words point at red marks on the screen: look at the pictures before you answer. Each # is a numbered picture.`
        : `The words are about what is on the screen: look at the picture before you answer.`,
      inTheMind
        ? `Get the pictures in one of these ways, then answer from them and the lines below alone:`
        : `Read the pictures, then answer from them and the lines below alone:`,
      `- On ${manifest.by.device}: read ${pictures}, in ${folder} (open nothing else there).`,
      ...(inTheMind && mindLooksUp
        ? [
            // The mind has its own lookup: the text names the capture and the one call. A name and
            // no key: who may read is the mind's to say.
            `- Anywhere else, through the mind ${mind}: the capture's id is ${capture}, and one call answers its words, its marks and its pictures: await itx.getScrawl("${capture}"). The iterate MCP tool "run" takes async (itx) => await itx.getScrawl("${capture}") and shows the pictures as images. An agent of the mind adds its own path and gets them as images too: await itx.getScrawl("${capture}", { showTo: "/agents/…" }). With a shell and no image: add { urls: true } and download each link in "urls" (curl -o). A state "pending" says that the capture still arrives: ask again.`,
          ]
        : inTheMind
        ? [
            // A mind with no lookup of its own. One script, whole in the text: an agent that is pointed at a file of code reads the code
            // before it runs it, which is one more call. The same text runs everywhere: the MCP tool
            // takes it as it is, a codemode block and the CLI take its body. It answers context.json
            // (whose "itx/images" the MCP tool shows as images) and a signed link for each picture,
            // which a shell fetches with curl; an agent of the mind also gets the pictures as the
            // files of a message to itself.
            `- Anywhere else, through the mind ${mind}: run this itx script. It answers the words, the marks and a download link for each picture ("urls"), and an agent of the mind also gets the pictures as images. The iterate MCP tool "run" takes it as it is. In your own codemode, or with the iterate CLI (iterate itx run --mind ${mind} --eval '…'), run only its body, between the outer braces. If no images appeared, download each link in "urls" (curl -o) and look at the files.`,
            `async (itx) => { const d = "${directory}/"; await itx.cd(d).waitForEvent({ type: "capture/ready", afterOffset: 0, timeoutMs: 60000 }).catch(() => {}); const c = JSON.parse(new TextDecoder().decode(await itx.files.get(d + "context.json").bytes())); const urls = {}; for (const n of c.pictures) urls[n] = (await itx.files.get(d + n).url()).url; const me = await itx.whoami(); if (me.path.startsWith("/agents/")) await itx.agents.get(me.path).message({ message: "The capture's pictures", files: await Promise.all(c.pictures.map(async (n) => ({ contentType: "image/jpeg", filename: n, data: await itx.files.get(d + n).bytes() }))) }, { trigger: false }); return { ...c, urls }; }`,
          ]
        : []),
      ...(wordsPending
        ? [
            `The last words are not in this text yet: ${inTheMind ? `the ${mindLooksUp ? "call" : "script"} above waits for them, and ` : ""}summary.md in that folder has them a moment after the capture.`,
          ]
        : []),
      ...lines.map(([, text]) => text),
      "",
    ].join("\n");
  }

  // The model of the mind that reads a picture: Workers AI's own vision models make things up on
  // screenshots of text.
  const sight = "openai/gpt-6.2-sol";

  /** What is under each mark, as a model reads it: for a reader that gets no picture. At most 20
   *  seconds, and a picture that fails is left out. */
  async function see(panels) {
    const seen = {};
    let itx;
    try {
      ({ itx } = await link.now(withinMs));
    } catch {
      return undefined;
    }
    let timer;
    try {
      await Promise.race([
        Promise.all(
          panels.map(async (panel) => {
            const answer = await itx.ai
              .run(sight, {
                messages: [
                  {
                    role: "user",
                    content: [
                      {
                        type: "text",
                        text:
                          panel.did === "the screen at the end"
                            ? "This is a screenshot. Say in at most three sentences what it shows: the app, the window in front and its main content."
                            : "This is a part of a screenshot. A person marked it in red (ink, or a small red ring where they clicked). Say in at most two sentences what exactly the red marks circle, cover or point at. Quote the visible text under or inside every mark.",
                      },
                      {
                        type: "image_url",
                        image_url: {
                          url: `data:image/jpeg;base64,${readFileSync(join(folder, panel.file)).toString("base64")}`,
                        },
                      },
                    ],
                  },
                ],
                max_completion_tokens: 400,
                reasoning_effort: "low",
              })
              .catch(() => undefined);
            const text = answer?.choices?.[0]?.message?.content;
            if (text) seen[panel.n] = text;
          }),
        ),
        new Promise((resolve) => (timer = setTimeout(resolve, 20_000))),
      ]);
    } finally {
      clearTimeout(timer);
    }
    return Object.keys(seen).length
      ? { by: { kind: "model", id: sight }, panels: seen }
      : undefined;
  }

  /** Every file of the folder that no step below puts by its name, as paths relative to it. */
  function filesIn(relative = "") {
    return readdirSync(join(folder, relative), { withFileTypes: true }).flatMap((entry) =>
      entry.isDirectory()
        ? filesIn(join(relative, entry.name))
        : ["summary.md", "transcript.json", "seen.json", "context.json", "capture.json"].includes(
              entry.name,
            )
          ? []
          : [join(relative, entry.name)],
    );
  }

  const manifestNow = () => JSON.parse(readFileSync(join(folder, "capture.json"), "utf8"));
  /** Everything `copy` started: the capture is ready when it settles. */
  let readying;

  function copy() {
    const manifest = manifestNow();
    let isHeard = false;
    // the file is written before the mind is reached: a later `--finish` reads it
    const heard = voiceWhole.then(() => {
      isHeard = true;
      writeFileSync(join(folder, "transcript.json"), JSON.stringify(transcriptSoFar()));
      return put("transcript.json").then(() => ({ transcript: transcriptSoFar() }));
    });
    // At once: everything this Mac knows now. The pictures went up while the person talked. One
    // turn of the loop later, so that words that are whole already count as heard.
    setImmediate(() =>
      say({
        copy: paste({
          manifest,
          transcript: transcriptSoFar(),
          wordsPending: !isHeard && manifest.microphone,
        }),
      }),
    );
    // capture.json goes once, at `finish`: it grows until then (the movie's and the voice's
    // observations), and nothing reads it in the mind before `capture/received`
    const early = Promise.all(filesIn().filter((file) => file.endsWith(".jpg")).map(put));
    // a failure of these is told at `finish`, which awaits `readying`
    early.catch(() => {});
    heard.catch(() => {});
    readying = (async () => {
      await ready;
      const [words, seen] = await Promise.all([heard, see(manifest.panels)]);
      if (seen) {
        writeFileSync(join(folder, "seen.json"), JSON.stringify(seen));
        await put("seen.json");
      }
      // What the text's one script answers: the words, the marks and the pictures' names.
      const pictures = [
        ...(manifest.panels.length > 1 && existsSync(join(folder, "sheet.jpg"))
          ? ["sheet.jpg"]
          : []),
        ...manifest.panels.map((panel) => panel.file),
      ].slice(0, 8);
      writeFileSync(
        join(folder, "context.json"),
        JSON.stringify({
          said: (words.transcript?.segments ?? []).map(
            (segment) => `${clock(segment.t)} ${segment.text}`,
          ),
          marks: manifest.panels.map((panel) => ({
            "#": panel.n,
            at: clock(panel.t),
            did: `${panel.did}${panel.on ? ` ${panel.on}` : ""}`,
            ...(seen?.panels[panel.n] && { seen: seen.panels[panel.n] }),
            picture: panel.file,
          })),
          ...(seen && {
            note: `\`seen\` is what a model (${seen.by.id}) read off each picture: it may be wrong. Trust the pictures.`,
          }),
          pictures,
          "itx/images": pictures.map((name) => `${directory}/${name}`),
          more: `capture.json (every observation), screen.mp4 and voice.m4a (they come last) are files under ${directory}/.`,
        }),
      );
      await put("context.json");
      await lookedFor;
      const text = paste({ manifest, ...words });
      writeFileSync(join(folder, "summary.md"), text);
      await Promise.all([put("summary.md"), early]);
      // the same text with the last words: it takes the first one's place on the clipboard
      say({ copy: text });
      await append("capture/ready", { capture, summary: `${directory}/summary.md`, pictures: manifest.panels.length });
    })();
    // a failure is told at `finish`, which awaits it
    readying.catch(() => {});
  }

  async function finish() {
    try {
      // The app sends the last words and `heard` when its speech model has finished, which can be
      // after the movie: they are waited for, at most `lastWordsMs`. Then the words that came are
      // all there are.
      if (!kept && manifestNow().microphone) {
        let timer;
        await Promise.race([voiceWhole, new Promise((resolve) => (timer = setTimeout(resolve, lastWordsMs)))]);
        clearTimeout(timer);
      }
      voiceIsWhole();
      if (!readying) copy();
      const manifest = manifestNow();
      const files = filesIn();
      await ready;
      const rest = Promise.all(
        ["capture.json", ...files]
          .sort((a, b) => statSync(join(folder, a)).size - statSync(join(folder, b)).size)
          .map(put),
      );
      // a failure is told below, where `rest` is awaited
      rest.catch(() => {});
      await readying;
      await rest;
      const window = manifest.observations.find((observation) => observation.kind === "window");
      await append("events.iterate.com/itx/described", {
        description: `A capture from ${manifest.by.device}, ${clock(manifest.durationMs)} long${window ? `, of ${window.application}` : ""}: a person talked, clicked and drew on the screen. Its files are under ${directory}/; start with summary.md.`,
        metadata: { capture },
      });
      await append("capture/received", {
        capture,
        manifest: `${directory}/capture.json`,
        summary: `${directory}/summary.md`,
        files: [...uploads.keys()],
      });
      say({ progress: 1 });
      say({ done: true });
    } catch (error) {
      say({
        failed: String(error?.message ?? error).slice(0, 300),
        copy: paste({ manifest: manifestNow(), transcript: transcriptSoFar(), inTheMind: false }),
      });
    }
  }

  async function discard() {
    await Promise.allSettled(uploads.values());
    try {
      await ready;
      if (uploads.size) await onMind((itx) => itx.r2.delete([...uploads.keys()].map((file) => `${directory.slice(1)}/${file}`)));
    } catch {}
    say({ discarded: true });
  }

  if (kept) {
    // a capture that stayed on this Mac: its words are the transcript.json it has
    const file = join(folder, "transcript.json");
    if (existsSync(file)) {
      const transcript = JSON.parse(readFileSync(file, "utf8"));
      segmentsHeard.push(...(transcript.segments ?? []));
      heardBy = transcript.by ?? heardBy;
    }
  }

  return {
    /** One line of the app: one step. `finish` and `discard` answer when they are done. */
    take(line) {
      if (line.segment) hear(line.segment);
      if (line.heard) voiceIsWhole();
      if (line.put) put(line.put);
      if (line.copy) copy();
      if (line.finish) return finish();
      if (line.discard) return discard();
    },
  };
}
