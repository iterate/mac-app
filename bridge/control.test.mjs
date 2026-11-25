// Control (mac-endpoint.ts `control.*`): each call is one line on the app's socket, with the
// method and the caller's input as they are; the app's refusal comes back as the call's error.
// The app's side is a fake here: no event reaches this Mac.
import assert from "node:assert/strict";
import { mkdtempSync } from "node:fs";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";

/** The app's socket in a home of its own: one line of JSON in, one out, as LocalEndpoint.swift. */
async function appSocket(answer) {
  const home = mkdtempSync(join(tmpdir(), "control-"));
  const lines = [];
  const server = createServer((socket) => {
    let text = "";
    socket.setEncoding("utf8");
    socket.on("data", async (chunk) => {
      text += chunk;
      if (!text.includes("\n")) return;
      const line = JSON.parse(text.slice(0, text.indexOf("\n")));
      lines.push(line);
      const { method, ...parameters } = line;
      const reply = await Promise.resolve()
        .then(() => answer(method, parameters))
        .then((ok) => ({ ok }), (error) => ({ error: error.message }));
      socket.end(`${JSON.stringify(reply)}\n`);
    });
  });
  await new Promise((resolve) => server.listen(join(home, "endpoint.sock"), resolve));
  return { home, lines, close: () => server.close() };
}

const DISPLAY = { id: 1, pixelWidth: 3024, pixelHeight: 1964, pointWidth: 1512, pointHeight: 982 };

test("control: start, input, paste, clipboard, state and end are one line each on the app's socket", async (t) => {
  const socket = await appSocket((method, parameters) => {
    switch (method) {
      case "state":
        return { things: [] };
      case "control.start":
        return { session: "s1", display: DISPLAY };
      case "control.input":
        return { applied: parameters.events.length, paused: false };
      case "control.paste":
        return { pasted: true, paused: false, characters: parameters.text.length, pressed: parameters.press === true };
      case "control.clipboard":
        return { text: "copied", truncated: false };
      case "control.state":
      case "control.end":
        return { sharing: "ask", permitted: true, paused: false, sessions: [] };
      default:
        throw new Error(`No method "${method}".`);
    }
  });
  t.after(socket.close);
  process.env.ITERATE_MAC_HOME = socket.home;
  process.env.ITERATE_MAC_APP_SUPERVISED = "1";
  const { default: macEndpoint, description } = await import("./mac-endpoint.ts");
  assert.ok(description.length < 500, `the description is ${description.length} characters`);
  assert.match(description, /iterate menu-bar app/);
  const mac = await macEndpoint();

  const started = await mac.control.start({ by: "Misha" });
  assert.deepEqual(started, { session: "s1", display: DISPLAY });
  const events = [
    { t: "move", x: 0.5, y: 0.5 },
    { t: "down", x: 0.5, y: 0.5, button: 0 },
    { t: "up", x: 0.5, y: 0.5, button: 0 },
    { t: "key", code: "KeyC", down: true, mods: ["meta"] },
    { t: "text", text: "hello" },
  ];
  assert.deepEqual(await mac.control.input({ session: "s1", events }), { applied: 5, paused: false });
  assert.equal((await mac.control.paste({ session: "s1", text: "hi", press: true })).pressed, true);
  assert.equal((await mac.control.clipboard({ session: "s1" })).text, "copied");
  assert.deepEqual((await mac.control.state()).sessions, []);
  await mac.control.end({ session: "s1" });

  const sent = socket.lines.filter((line) => line.method !== "state");
  assert.deepEqual(
    sent.map((line) => line.method),
    ["control.start", "control.input", "control.paste", "control.clipboard", "control.state", "control.end"],
  );
  assert.deepEqual(sent[0], { method: "control.start", by: "Misha" });
  assert.deepEqual(sent[1].events, events);
  assert.deepEqual(sent[2], { method: "control.paste", session: "s1", text: "hi", press: true });
});

test("control: the app's refusal is the call's error, in its words", async (t) => {
  const OFF = "The Mac's owner has Control this Mac off in the iterate panel: nobody controls this Mac.";
  const socket = await appSocket((method) => {
    if (method === "state") return { things: [] };
    throw new Error(OFF);
  });
  t.after(socket.close);
  process.env.ITERATE_MAC_HOME = socket.home;
  process.env.ITERATE_MAC_APP_SUPERVISED = "1";
  // a module of its own, so that it reads this test's home
  const { default: macEndpoint } = await import(`./mac-endpoint.ts?refusal`);
  const mac = await macEndpoint();
  await assert.rejects(mac.control.start({}), { message: OFF });
});
