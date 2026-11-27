# @iterate-com/mac-app

**The primitive is the iterate CLI.** `iterate provide <file> --json` lends a file's functions to
a mind as `itx.<name>` and prints the lend's state on stdout, one JSON line at each change:
`connecting`, `live`, `reconnecting` (the attempt and the wait), `notAllowed` (with the link where
a member allows the key), `incompatible` and `stopped`, each with its reason. A program that keeps
a lend reads those lines; the lines for a person go to stderr. See
[`provide`](https://github.com/iterate/core/blob/main/core/lib/src/cli/README.md#provide) and
[its states](https://github.com/iterate/core/blob/main/core/lib/src/cli/provide-state.ts).

**This app is one thing built on it, and a starting point.** Clone it, change it, build it from
your clone: see [Install: clone it](#install-clone-it) and [Make your own thing](#make-your-own-thing).

A Mac's menu-bar app for an [iterate](https://iterate.com) mind. It makes this Mac an endpoint
device of the mind, which a person is often near. Its inputs are the screen, the camera, the
microphone and the window in front as text; its outputs, the speakers and banners on the screen
(a call's among them); its compute, commands (AppleScript, Swift, shell). You choose for each thing: **Off**, **Ask** (you
approve each use with Touch ID) or **Shared**. Everything starts at Off.

## Install: clone it

The way to have this app is a clone of this repository. You own the code: read it, change it, and
pull what changed here when you want it.

```sh
git clone https://github.com/iterate/mac-app ~/src/mac-app
cd ~/src/mac-app
node cli.mjs                              # asks for your mind and this Mac's name, builds, installs, lends
node cli.mjs --mind example.com --name jane.mac --login   # the same with no questions
```

After a change of yours, or a `git pull`:

```sh
node cli.mjs update                       # build and install again from the clone, with the saved answers
./run-on-mac.sh                           # or: build, install, open and follow the logs
```

An app built from a clone runs what was built: **it does not update itself**, and the panel says
"Built from ~/src/mac-app". You decide when to `git pull`.

### Without a clone: npm

```sh
npx @iterate-com/mac-app
```

The same app from npm, for a Mac where you only want to use it. It updates itself once an hour
from npm (below). `npx @iterate-com/mac-app init [folder]` turns it into a copy you own later:
that copies the source into a git repository of its own, and `diff` and `update` there bring in
what changed upstream. A clone of this repository does the same with plain `git`.

### What the install does

It asks for your mind's address, the name to lend this Mac under (`itx.<name>`) and whether to
start at login. Then it:

1. installs Apple's Command Line Tools if they are missing (macOS's own window asks);
2. builds the app from the Swift source in this package and installs it as
   `/Applications/iterate.app` (once per version; a minute or two the first time);
3. installs the [iterate CLI](https://www.npmjs.com/package/iterate) at a pinned version in the
   app's own folder;
4. makes a key that may lend this Mac to your mind under that one name, and opens a link where a
   member of the mind allows it with their passkey;
5. opens the app. The 𝑖 in the menu bar is its panel.

From then on the app is the one thing that runs: it lends the Mac to the mind with that key, and
lends it again when the connection ends. It starts at login if you said so (System Settings ›
General › Login Items shows it). Once an hour it asks npm for a newer version and updates itself,
unless the microphone or a camera is in use.

```sh
npx @iterate-com/mac-app --mind example.com --name jane.mac --login   # no questions
npx @iterate-com/mac-app update                                       # update now, with the saved answers
npx @iterate-com/mac-app uninstall                                    # quit and remove the app, its keys and its state
```

### Several minds, one lent at a time

This Mac can know several minds, each with its own key (`keys/<mind>.key`). The app lends it to
one of them, the active one. The top of the panel is the mind switcher: the active mind's icon
(with the lend's dot), its name, its address and this Mac's name there, and at the right the
lend's phase. A click lists the minds, with a check mark and the phase on the active one (the app
knows no other mind's), then **Add a Mind…**, **Remove a Mind…**, and **Reconnect Now** while the
lend is live or connecting. With no mind at all, the panel says how to add one, and only
dictation works. It does the same
as these commands (a switch and a removal the app writes into config.json itself, as the CLI does;
**Add a Mind…** runs the CLI's `add`):

```sh
npx @iterate-com/mac-app list                                      # the minds; * marks the active one
npx @iterate-com/mac-app add --mind example.org --name jane.mac    # a new key; a member allows it; then it is active
npx @iterate-com/mac-app use example.org                           # lend to that mind; the app switches at once
npx @iterate-com/mac-app remove example.org                        # forget it and delete its key
npx @iterate-com/mac-app set --login                               # one saved value: --login, --no-login,
npx @iterate-com/mac-app set --mind example.org --words-expression '…'   # a word list's expression ("" removes it)
```

`add` offers the minds of the iterate CLI's profiles (`iterate login`). `remove` deletes the key on
this Mac only: it stays listed on the mind's /keys page until a member removes it there.

A mind's name and icon are what its website answers to anyone at `/.well-known/iterate-profile`:
the app reads them with no key, at most once in five minutes while a view shows the mind, and keeps
them in `faces/` of its folder, so the panel draws them at once and with no network. A mind with no
icon is the first letter of its name on a colour that its address gives. The name is the owner's
own words, unsigned, so the address is always shown beside it.

### The lend's state

The panel says what the lend does at the right of the mind: **Connecting** or **Live** since when
(orange, green), **Reconnecting** with its attempt (orange), **Stopped**, **Not allowed** or
**Incompatible** (red). While it is held up, a block under the mind has the reason in the CLI's
words: the next try and the last failure, why the process ended and when it starts again, the link
where a member allows the key, or the command that updates the CLI with **Copy Command**. **Reconnect
Now** (in the block, or the switcher's last entry) ends a wait or an attempt and starts at once; the
app does the same when the Mac wakes from sleep, and when the network comes back to a lend that is
not live. Opening the panel does it too, for a lend that waits for its next start (stopped,
refused, or the CLI between its tries); one that is connecting or live is left alone. Every change
of state is one line in the app's log.

The mind this Mac is lent to is one session in the app: the selected mind, this Mac's name there,
and the paths of Node, the iterate CLI and the bridge. The device's events, the record, live and the
input work for that session, as you, with the iterate CLI's own sign-in. Only selecting another mind
or removing it ends the session: its approvals end, and its events, record and live stop before any
starts for the next mind. A reconnect keeps it, and the record's waiting slots with it. **Not
allowed** ends only the lend's powers: every approval ends, a question that waits is refused, and a
call of the lend is refused until the mind lets the key in again; the events, the record, live and
the input go on.

The 𝑖 in the menu bar shows the lend at a glance: plain while live, dimmed while it connects or
reconnects, and dimmed with a slash through it while it is not lent (no mind, stopped, not allowed,
incompatible). Green, red and orange (a banner, a use, the microphone or a camera on) show over it
while they last. A small red dot at its lower right is the record: filled while it records, a ring
while it is paused, none while it is off.

When the active mind has an icon kept (`faces/`, read again at most every five minutes), the menu
bar shows that mind's face in place of the 𝑖: its icon in a circle, 18 points across, in colour.
The face shows the same states. It is plain while live, dimmed while it connects, and dimmed with a
slash while it is not lent. Green, red and orange are a ring at its edge, and the lend's tone stays
under the ring. The record is the red dot at its lower right, and Always listen is the orange dot at
its upper left. With no mind, or no icon read yet, or an icon that does not load, the menu bar
shows the 𝑖. A switch of mind shows the new face at once, from disk. The words of the status
item (its tooltip and VoiceOver label) do not change. `--render-icons <folder>` draws each mark on
a light and a dark bar, and `marks-light.png` and `marks-dark.png`: each colour of the mark with each
dot. It also draws `faces-light.png` and `faces-dark.png`: each tone and ring of the face with each
dot. And `menubar-light.png` and `menubar-dark.png`: the bar at its own size, with the mark and the
face in five states.

Needs macOS 14 or later and Node 22.18 or later.

### Settings

**Settings…** in the panel's footer (or ⌘, while the panel shows) opens one window, 800 points
wide. Its sidebar has two groups. **This Mac** is what holds whichever mind the Mac is lent to:

- **General**: open at login (config.json's `login`), show each act on the screen (the same tick
  as on the Activity page), how long an approval lasts (5, 15, 30, 60 or 120 minutes; the Ask
  question's second button says it: "Approve for 30 Minutes"), the keys of capture and the input
  and of "Paste the last transcript" (⌥⇧W) (a click records a new one, with ⌘, ⌥ or ⌃; × removes
  it; a key that macOS refuses says so and the one before stays), the version with **Update Now** and **Update by itself** (from npm only:
  a trial and a copy are updated by hand), and **Copy Prompt**.
- **Dictation**: fn to hold and talk (× removes it: ⌥⇧D stays), double-tap to keep it on,
  Always listen (off unless set; "Listening"), the orange row when macOS acts on 🌐 too, the speech model and its list, "OpenAI through <mind>:
  the mind's key" when sockets open through the lent mind, your own OpenAI key (optional; set or removed;
  it is never shown), whether the pill shows the
  words, where the text goes (where the cursor is, or on the clipboard only), the history ("Keep
  a history", and **Clear History…**, which asks once in the page itself; "Dictation" below), and
  the default expression of the word list (below).

**Minds** has a page for each mind this Mac knows: **Lend to This Mind** (or "Lent now"), this
Mac's name there (a new name needs a new key: the app asks, then runs the CLI's `add`), the key's
state (known only for the mind this Mac is lent to: "Allowed by a member" while live, else "Not
checked"), your sign-in of the iterate CLI, the mind's word list, and **Remove…**. Then **Add a
Mind…**.

Your sign-in is what the iterate CLI keeps in `~/.config/iterate/sessions.json`: the app reads the
end of the mind's token (`expiresAt`) and whether it has a refresh token, nothing else, and asks no
network. "Signed in · 3 h 12 min left" while the token lasts; "Signed in · renews at its next use"
when it ended and the CLI renews it at its next connection; "Not signed in" with neither.

The app writes config.json only through `cli.mjs` (`set`, `add`; `use` and `remove` as the panel
does), and `cli.mjs` keeps every key it does not know, at the top and in each mind. The choices
of this Mac are in the app's defaults: `approval.minutes`, `key.capture`, `key.input`, `key.writeSaid`, `listen.always`,
`dictation.history`, `dictation.key`, `dictation.doubleTap`, `dictation.pill`, `dictation.sounds`, `dictation.write`, `update.byItself`.
`--render-settings <folder>` draws the pages (General, Dictation, a mind lent with the default
list, a mind whose own expression fails), light and dark.

## Make your own thing

Three parts are what a thing lent to a mind from a Mac needs; keep them:

- **The lend's state machine**: `Sources/VoiceMeetCore/LendState.swift` (pure, with its tests)
  reads the CLI's JSON lines and the process's end, and says what to do: start now, wait, or stop.
  `Sources/VoiceMeetMac/Lend.swift` runs `iterate provide` and does what it says.
- **The local socket and the bridge**: `LocalEndpoint.swift` answers one line of JSON per call on
  a Unix socket that only you can read; `AppModel.swift` routes each method. `bridge/mac-endpoint.ts`
  is the file that `iterate provide` lends: each of its methods is one request on that socket.
  **The bridge is the contract with the mind.** Its methods are what agents call, and its
  `description` is the line they read next to the name: keep it under 500 characters, or the mind
  refuses the lend and it never goes live.
- **The switches**: `Permissions.swift` (Off, Ask, Shared for each thing, and macOS's permissions)
  and `Approval.swift` (the Ask question and Touch ID; its panel is `ApprovalPanel.swift`). The panel (`Panel.swift`) shows them, under its mind
  switcher (`MindSwitcher.swift`). `MindFace.swift` is a mind's name and icon for any view
  (`MindAvatar`, `MindLabel`).

For a minimal app, delete the things it shares and their methods in `AppModel.swift` and the
bridge: `Camera.swift` and `CameraState.swift`, `AudioOwner.swift`, `AudioDevices.swift` and
`MicrophoneState.swift`, `Speaker.swift`, `Banner.swift` and `BannerState.swift`, `Powers.swift`
(screen, window text, commands), `Capture.swift` and `bridge/capture.mjs`, `MindInput.swift`,
`InputDraft.swift` and `bridge/input.mjs`, `Presence.swift`, both `RemoteControl.swift` (control), and their tests (and their jobs in
`bridge/mind.mjs`); `swift build` then names what
still refers to them, in the panel and the app's delegate. Then add your own method: a
case in `AppModel.swift`, a function in the bridge, a line in its description.

## In the mind

The panel's **Copy Prompt** copies a text for an agent: how to find this Mac in the mind and how to
use it. In short, with the name `jane.mac`:

```js
const mac = itx.jane.mac;
await mac.state(); // each display, camera and other thing, and its Off / Ask / Shared; presence
await mac.screen.snapshot({ display: 0 }); // { jpeg, pixelWidth, pixelHeight }
await mac.camera.snapshot(); // a still picture of a camera
await mac.microphone.listen({ seconds: 5 }); // { wav }
await mac.speaker.say("Lunch is ready");
await mac.accessibility.frontWindow(); // the window in front as text
await mac.appleScript('tell application "Music" to play');
await mac.swift('print("hello")');
await mac.run(["sw_vers"]); // { exitCode, stdout, stderr }
await mac.banner.show({
  title: "Design review is starting",
  body: "Misha asks you to join",
  buttons: [
    { label: "Join", style: "accept", open: "https://meet.example.com/contexts/agents/meet/x" },
    { label: "Not now" },
  ],
}); // { pressed: "Join" }, or { pressed: null, why: "no answer" | "dismissed" | "replaced" | "off", words }
await mac.call.ring({ agent: "/agents/lunch", from: "Lunch planner", reason: "Friday's table" });
// { accepted: true }, or { accepted: false, why: "declined" | "no answer" | "replaced" | "off", words }
await mac.call.publish({ context: "/agents/meet/x", source: "screen:0" }); // or "camera": into that call
await mac.call.unpublish({ context: "/agents/meet/x" }); // or { publication }; call.state() lists them
await mac.record.state(); // { sources: { screens, cameras, mics, speakers }, windowText, recording, paused, line, tracks, … }
await mac.record.set({ screens: true, mics: false }); // the new state; "on" is a use, as a snapshot is
await mac.http({ path: "/state.json" }); // { status, headers, body }: this Mac's own pages (below)
const { session } = await mac.control.start({ by: "Misha" }); // a person drives this Mac (below, "Control")
await mac.control.input({ session, events: [{ t: "move", x: 0.5, y: 0.5 }, { t: "text", text: "hi" }] });
```

### Presence

`mac.state()` also says whether a person is likely at the Mac, read when asked and kept nowhere:

```js
(await mac.state()).presence; // { idleSeconds: 42, screenLocked: false, displayAsleep: false }
```

- `idleSeconds`: the seconds since the last key press, mouse move, click or scroll, in any app.
- `screenLocked`: true while the screen is locked, or while another user's session is in front.
- `displayAsleep`: true while every display sleeps (or none is on).

Idle under a few minutes, not locked and a display awake is the sign that a person is likely
there; an agent reads it before it shows a banner or rings. It says nothing of who is there. It
has no switch of its own: it is part of `state()`, which any agent the Mac is lent to may read, and
macOS asks no permission for any of the three (`CGEventSource.secondsSinceLastEventType`,
`CGSessionCopyCurrentDictionary`, `CGDisplayIsAsleep`).

### Keep the Mac awake: Amphetamine

The app does not keep the Mac awake itself. When [Amphetamine](https://apps.apple.com/app/amphetamine/id937984704)
is installed, an agent drives it through `mac.run` with `osascript`. The first call shows macOS's
question whether `iterate` may control Amphetamine, once.

```js
const amph = (script) => mac.run(["osascript", "-e", `tell application "Amphetamine" to ${script}`]);
await amph("session is active"); // stdout "true" or "false": the person may have one running
await amph("start new session with options {duration:2, interval:hours, displaySleepAllowed:true}");
await amph("session time remaining"); // seconds; 0 no end, -1 a trigger, -2 an app or a date, -3 none
await amph("end session");
```

- Amphetamine has **one** session for the whole Mac. A new one ends the one before, the person's
  own too. So read `session is active` first, and do not end a session that you did not start.
- Always give a duration, so that a session ends when the agent stops. `duration:0, interval:0` never ends.
- `displaySleepAllowed:true` keeps the Mac awake and lets the screen sleep.
- With the lid closed, the Mac sleeps anyway, unless closed-display mode is on: `enable closed
  display mode`. That needs the separate Amphetamine Enhancer helper, which the person installs.
- `osascript` exits with an error when Amphetamine is not installed: then nothing keeps the Mac awake.

### Banners

A banner is an output of this Mac, beside the speakers. `mac.banner.show` puts one on the screen:
a title, a line or two of text, one to three buttons (one "OK" when none is given), a sound
(`chime` unless said, or `ring`, or `none`) and a time limit (30 s unless said, 5 to 120). It
answers the label of the button pressed: what happens next is the agent's. A button with `open`
also opens that page in the default browser after its press. `mac.call.ring` is a banner that
looks like a call: who calls, why, Decline and Accept as round red and green phone buttons, and a
ring for 30 s. Accept opens the call's page.

With Banners at **Off** in the panel, a banner is refused in words (`why: "off"`). At **Ask** and
at **Shared** it shows: no button is ever pressed but by you. The banner has the look of macOS's
own call banner and comes at the top right, where notifications come, over every window and on
the active space; the 𝑖 turns green, and the panel shows the banner too, with its buttons. It
does not take the keyboard when it comes, so a Return typed elsewhere presses nothing; click it,
and Return presses the default button (the first `accept`, else the first one) and Escape closes
it (or declines a call). One banner at a time: a newer one replaces it (`why: "replaced"`), but a
plain banner never replaces a call (it is refused). At most 6 begin in a minute.

A page to open is checked before anything shows. For a call with no `url`, it is the agent's page
in the mind's Dash, `https://dash.<zone>/agents<path>?call=join`, which opens the call's lobby:
there you see your camera and your microphone's level, choose the devices, see who is in the call,
and press Join now. Anyone can send such a link, so the lobby opens no microphone and no camera
by itself, and nothing is sent until you join. Any other page must be https, with no user or port, on the zone of the mind this Mac is
lent to or a subdomain of it: the app opens no other origin. The zone comes from the mind's
address as the lend's CLI says it (`iterate.example.com`), without the leading `iterate.` when
two labels are left (`iterate.com` stays `iterate.com`); a zone of one label is refused.

A call for a thing that is Off, or that macOS has not allowed yet, fails with the reason in words
an agent can pass on. Each use turns the 𝑖 red for 3 seconds.

## Ask: one question for each use

A thing set to **Ask** asks you at each use, in a floating panel of the app in the middle of the
screen: the face and address of the mind that asks, what it wants ("Iterate wants to run
commands"), what exactly in monospace (the command and its input), why it is asked, and three
answers: **Approve Once** (Return), **Approve for 30 Minutes** (the length is Settings › General,
"An approval can last") and **Deny** (Esc). Its last line counts down the seconds: with no answer
in 60 s the use is refused. An approval is confirmed with Touch ID (or the Mac's password). The
panel takes the keys without making the app the active one, so the app in front stays in front;
Touch ID's own window comes from macOS. One question at a time: a second use waits for the first
answer, which may cover it. An approval for N minutes holds for the mind it was given to, until
the mind changes or refuses this Mac's key.

## Pause: all sharing off in one click

**Pause** beside Capture, Input and Dictate turns everything a mind can use to Off, and keeps
each choice. While paused:

- A mind's use is refused: "The Mac's owner paused all sharing".
- The record, the live watches, a call's picture and Drive stop.
- The keyboard and mouse events, the app in front and the window text stop.
- Every approval ends.
- The menu bar mark has the paused ring.

Presence and the acts (the refusals among them) still go to the mind. The pause holds across a
restart. Only you end it, with **Resume** in the panel. A mind sees `paused: true` in `state`
and cannot change it.

## What a mind does with the Mac, as you see it

Each act of a mind with this Mac shows twice:

- **On the screen.** While the act runs, and for 4 seconds after, a pill at the top right names it
  with the mind's face: "Running a command" with the command's words, "Taking a picture of the
  display", "Listening to the microphone for 5 s". The 𝑖 in the menu bar is red for that time. The
  pill is in no picture or recording of the screen, so a mind's own screenshot does not show it.
- **In the panel.** "Activity" shows the two newest acts and the count. **All** shows the Activity
  page in place of the panel's middle (its back button returns): the last acts with their times,
  how long each took, and the reason when one failed. Its first line is the context it shows:
  `/devices/<name>` on the mind, and the presence that context heard last. In "A mind can use", the
  row of a thing whose act runs says "running" in red, and a thing a watcher gets "watched".

The list is a view of the device's context in the mind (below), not a store of the app. Each act
is two kept events there, `device/act-started` and `device/act-ended`, by one act id; the list
folds them by act into one row (`ActivityFold` in `VoiceMeetCore`). The job `events` of the mind's
process (below, "How it works") reads the context back, those types alone: it subscribes to them, and when it connects it reads the log
backwards, 500 offsets a page, until it has 50 acts, at most 10 pages (5,000 offsets). Every other
event (most of the log is keys and moves) is dropped as its page comes, and the bridge keeps only
the offsets of the last 200 events it told. An act of this Mac shows
at once, and its echo from the context is the same row. While the connection is down the act
waits in the bridge's queue with the other events, and its row has an orange cloud: not yet in the
mind. A start with no end in the context is an act that the app's end cut short. Another mind is
another context: the list starts empty and reads that one.

The pill's × hides it until the next act begins, also while a long act runs on. "Show each act
on the screen", on the Activity page, turns the pill off; the list and the red 𝑖 stay.
An act that was refused (the thing is off, or you said no) is no act and shows in neither.
`--render-activity <folder>` draws the pill and the page to PNG files, with sample acts.

**Open in a Window**, on the Activity page, shows the context in a window of its own. Its switch
shows the **Acts** (the panel's rows) or **Every event** the context keeps: every type on
`/devices/<name>`, newest first, with filters for each kind (keys and mouse are off until you turn
them on) and a search. At the right are the chosen event's fields, and the Off / Ask / Shared of
its thing, with **End the Approval** while one holds and **Copy Event**. Every event is read only
while the window is open: the job `events` subscribes to every kept type ("*", so no ephemeral
key) and reads the newest 100 events; a scroll to the end of the list reads the 100 below (at most
5,000 offsets scanned for a page), until the window holds 500. A new event over that pushes the
oldest out. A string of an event is cut at 2,000 characters for the window (the mind keeps it
whole). Closing the window ends the subscription and lets go of the events.
Its third mode, **Dictations**, is the history of transcripts on this Mac ("Dictation").
`--render-log <folder>` draws the window with sample events, and its Dictations mode.

## What the Mac tells its mind: `/devices/<name>`

A lent Mac has a context of its own in the mind, `/devices/<name>`, with the name of its lend
(`itx.<name>`). The app adds events there, through the job `events` of the mind's process
(`bridge/events.mjs`), as you (the iterate CLI's own sign-in; the Mac's key lends and does nothing
else). When that connection ends (a session's sign-in lasts 4 hours, a network goes), it connects
again
(`bridge/mind-connection.mjs`: 1 s, then twice as long, at most 60 s); the events wait meanwhile
(at most 2,000: the oldest moves and keys go first), go up in order, and the app says its presence
again:

| Event                     | When                                                                                                                                                                    | Payload                                                       |
| ------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------- |
| `device/presence-changed` | Always while the Mac is lent: it goes idle (120 s with no input), active, locked or asleep                                                                              | `state`, `idleSeconds`, `was`                                 |
| `device/key-pressed`      | While **Keyboard and mouse** is on in the panel                                                                                                                         | `key`, `text`, `keyCode`, `modifiers`, `app`, `isRepeat`      |
| `device/mouse-pressed`    | The same                                                                                                                                                                | `x`, `y`, `button`, `clicks`, `app`                           |
| `device/mouse-moved`      | The same, at most 10 a second                                                                                                                                           | `x`, `y`                                                      |
| `device/scrolled`         | The same, at most 10 a second                                                                                                                                           | `x`, `y`, `dx`, `dy`                                          |
| `device/app-focused`      | Always while the Mac is lent: the front app or its window's title changed                                                                                               | `app`, `bundle`, `title`                                      |
| `device/window-read`      | While **Window text** is ticked under Record: on a new app or window, a click, a pause after typing, the end of a scroll; at most every 2 s, only when the text changed | `app`, `title`, `text` (at most 20,000 characters), `trigger` |
| `record/slot-stored`      | While a switch under **Record** is on: once for each 30 seconds, after its files are in the mind                                                                        | `t`, `tracks` (below)                                         |
| `device/live-watch-started` | A member's page began to watch this Mac live (below, "Live")                                                                                                          | `watcher`, `who`, `tracks`                                    |
| `device/live-watch-ended` | The watch ended                                                                                                                                                         | `watcher`, `who`, `seconds`, `why`                            |
| `device/act-started`      | A mind's act with this Mac starts (above, "What a mind does with the Mac"). Its idempotency key is `device/act-started/<act>`                                    | `act`, `thing`, `doing`, `detail`                             |
| `device/act-ended`        | The act is over. Its idempotency key is `device/act-ended/<act>`                                                                                                        | `act`, `did`, `failure`                                       |
| `device/control-configured` | Always while the Mac is lent: at each connection, and when Control this Mac, Accessibility or a display's choice changes the offer. Kept (below, "Drive") | `kind`, `lend`, `control` (`"ask"`, `"shared"` or `null`), `displays`, `why` |
| `device/input-submitted`  | You sent an input with ⌥⇧Space (below, "Input"). It goes to the mind you chose, which need not be the one this Mac is lent to                                             | `id`, `text`, `at`, `files`                                   |

A key event holds the key itself, so what you type goes to the mind, but never a password
(`SecretKeys`). A key goes to no mind, not even as a key code, while macOS's secure input is on
(a system password prompt, the login window, 1Password's master password), while a password
manager or a system prompt is in front, or while the focused field is a password field (a
browser's sign-in form). The keys go again when the focus leaves it. A key asks no other process
for this when it can be helped (`FocusWatch`): the app in front is kept from one activation to the
next, and the focused field's kind is read once each time the app says its focus moved (an
`AXObserver`); the changes it said and the app has not yet given are heard before each key. An app
that tells no change (or the moment after an activation) is asked at each key, as before. Keyboard and mouse is off
until you turn it on. Its events are ephemeral: they reach whoever listens at that
moment and are in no log, unless you tick **Keep these events in the mind's log**. Keys need the
Accessibility permission of macOS. A presence event is always kept.

A password manager in front (1Password, Keychain Access, Passwords) is told as `app` and `bundle`
with no title, so that the app before it is seen to end; its window's title and text are never
read. A window's title and text need the Accessibility permission of macOS, and the app asks for
them away from its main thread, so an app that does not answer holds nothing up.

## The record: what the Mac saw and heard, in the mind

The panel's **Record into the mind** has a switch for each of **Screens**, **Camera**, **Microphone**,
**Speakers** and **Window text**: all off until you turn one on, and remembered. A switch that is
on is red; one that is on and held off by a permission macOS has not given is orange. The Mac records only while it is lent
to a mind, into that mind, and starts again by itself when the app starts. A source whose
permission macOS has not given says so in its row and stays off. Screens and cameras pause as
soon as the Mac is locked or its displays sleep, and start again by themselves: a paused camera is
off, its light too. Microphones and speakers go on. The line under the
switches says what happens ("Recording 4 tracks · 2 slots waiting"), and the 𝑖 in the menu bar has
a red dot at its lower right while the Mac records, a red ring while the record is paused. The
record does not change the colour of the 𝑖: orange still says that a call or a capture has the
microphone or a camera on.

A mind's agent reads and sets the same switches: `mac.record.state()` (no use of the Mac's powers)
and `mac.record.set({ screens, cameras, mics, speakers, windowText })`, which answers the new
state. Turning a source off is always allowed. Turning one on is a use of its power under your
choice for it, as a snapshot or a listen is: **Screens** and **Speakers** go by each display's
choice, **Camera** by each camera's, **Microphone** by the microphone's, **Window text** by the
window text's. Off refuses, Ask asks you with Touch ID, Shared does it, and Activity shows it
("Record the screens until switched off"). Your own hand on the panel's switches asks nothing.
`mac.state()` has the record's short state too (`record: { recording, paused, line }`).

Time is cut into **slots** of 30 seconds on the UTC clock. For each slot each **track**
(`screen-<display>`, `camera-0`, `mic-0`, `speaker-0`) is one file in the mind's files, named by
the clock, that plays by itself, and a video track has a small picture of the slot's start. The
track `transcript` is the words that were said, as JSON lines ("Listening"). `mic-0` is the
default input, read from the app's one microphone stream:

```
/devices/<name>/record/<track>/<YYYY-MM-DD>/<HH>/<MM>-<SS>.mp4   HEVC or AAC, fragmented MP4, time zero at the slot's start
/devices/<name>/record/<track>/<YYYY-MM-DD>/<HH>/<MM>-<SS>.jpg   640 px wide
```

Screens are 10 frames a second at the display's own pixels (only frames that changed), cameras
720p at up to 15, both HEVC at quality 0.45 with a keyframe at the slot's start and every 10 s. Sound is
AAC at 48 kHz, on the same clock as the picture. Windows of password managers are left out of
the screens.

What does not change costs almost nothing (`Sources/Record/Quiet.swift`):

- **A camera** keeps a frame only when its picture changed since the last frame it kept (the mean
  difference of a 32×18 copy of the luma is 1.5 levels or more), and at least one a second. Each
  kept frame lasts until the next. Measured on the owner's camera: a still room 0.0–0.5, a person
  who sits and talks 0.5, a head turn or a hand 2–44.
- **Sound** below a loudness (20 ms RMS under −50 dBFS for a microphone, −70 for the speakers),
  from 0.5 s after the last sound on, starts no encoder: the file has a silent AAC packet for
  each 1024 samples, so it plays as long and as true as before, and `rms`, `peak` and `levels`
  are of every sample. The encoder starts again 250 ms before the next sound. Measured on the
  owner's microphone: speech −46 dBFS (median), a quiet room −68, typing −60.
- **The speakers' capture** runs only while another app plays sound (Core Audio's
  `kAudioProcessPropertyIsRunningOutput` of each process, with listeners), and stops 2 s after the
  last one stops; meanwhile the track is silence by the clock. The first moments of a sound, while
  the capture opens again, are not recorded.

The recorder (`Sources/Record`) writes each slot's files into a spool on this Mac first
(`~/Library/Application Support/iterate-mac-app/record/<mind>/`, a file's path there is its path
in the mind), and `slots/<t>.json` once every track of the slot has closed. The job `record` of the
mind's process (`bridge/record.mjs`) takes the slots oldest first: it puts each file into the mind
by a signed upload link (`bridge/upload.mjs`: the links of a slot asked for in one go; the file
streams from disk, so no byte of it passes through the connection), then appends `record/slot-stored`
to `/devices/<name>` with the idempotency key `record/slot-stored/<t>`, then deletes the slot from
the spool. So an event never names a file that is not there. With no network the spool waits (up
to 5 GB; then the oldest slots go). The event's payload is `{ t, tracks: { <track>: { kind, file,
bytes, codec, … } } }`: a video track also has `width`, `height`, `frames`, `parts` (`[[byte
offset, ms from the slot's start], …]`, one per fragment), `picture`, and a screen's `x`, `y`,
`scale`; an audio track has `rate`, `channels`, `rms`, `peak` and `levels` (60 half seconds, in
dBFS).

## Live: a member watches this Mac now

A member of the mind (or a member's agent) opens the device on `record.<domain>` and presses
**Watch live**: the page shows the screens, the camera and hears the microphone of this Mac, about
a tenth of a second behind, peer to peer over WebRTC. The mind carries only the signalling: a few
ephemeral `device/live-signal` events on `/devices/<name>`. The contract is the mind app's README,
"Live".

- **Your choices decide.** A watch is a use of each display, the camera and the microphone under
  your choice for it, as a snapshot is: Off, that track is not offered; Ask, you are asked once
  for the whole watch (Touch ID); Shared, it is sent. A Mac that may show nothing answers with the
  reason, and the page shows nothing. There is no switch of its own.
- **You see it.** While somebody watches, Activity shows "Watched live by <who>" as a running act
  (the pill stays at the top right), and the panel shows each watcher first under the mind, in a
  red row, with an **End** button. Each watch is also on the device's log in the mind:
  `device/live-watch-started { watcher, who, tracks }` and
  `device/live-watch-ended { watcher, who, seconds, why }`.
- **One capture, two sinks.** The record's own capture feeds live (`CaptureSink` in
  `Sources/Record`): the same frames, no copy. A source that only live wants starts with the first
  watcher and stops with the last. While somebody watches, a screen captures 30 frames a second and
  the record keeps its 10 by time, so its files are the same with or without a watcher.
- **What a watcher gets:** each display (`screen-<display>`, at its own pixels), one camera
  (`camera-0`, 1280×720 at most) and one sound (`mic-0`), H.264 in hardware, at most 4 watchers.
  The page is told to show each picture at once, and the sound is in a stream of its own.
- **On the same network** the page connects to this Mac directly, and macOS asks once whether
  iterate may find devices on the local network. From another network it goes through STUN (or
  TURN, when the mind gives it), and macOS does not ask.

A mind's agent reads and ends watches: `mac.live.state()` (each watcher, its tracks, since when)
and `mac.live.end({ watcher })`. A watch starts only from a page.

How it is built: `Sources/Live` holds everything that touches WebRTC (LiveKit's build of WebRTC,
a binary target of `Package.swift`, carried in the bundle's `Contents/Frameworks`). `LivePeer` is
the sink and one peer connection per watcher; the signalling's rules are `LiveWatchers` in
`VoiceMeetCore`, tested on their own. The job `live` of the mind's process (`bridge/live.mjs`), on
its connection as you, subscribes to `device/live-signal`, appends the Mac's signals in order, and
asks the facet `record` for the ICE servers (STUN alone when it has none). It subscribes again on
each new connection, and once a minute it checks that its subscription still hears (an ephemeral
`device/live-ping` that only it hears); watches that run go on through a reconnect, peer to peer.

## A call's camera or screen from this Mac

A member in a call on meet.iterate.com (any agent's call that uses the kit's call) opens **Devices**.
When this Mac is lent to that mind now, and lent by that member, the Camera list also has "Your Mac
“jane.mac” (iterate app): <camera>", and a Screen list shows each display of this Mac that is not
Off. Without such a lend the picker is as it was. A choice asks the Mac:

```js
await mac.call.prepare(); // the picker opened: { prepared: ["screen", "camera"], seconds: 60 }
await mac.call.publish({ context: "/agents/meet/x", source: "screen:0", as: "<the page's row>" });
// { publications: [{ publication, context, source, since, connected: true, who }] } once the SFU has it
await mac.call.unpublish({ publication }); // or { context, source? }: always allowed
await mac.call.state(); // { publications }
```

- **Your choices decide.** A publication is a use of that display or the camera, as a snapshot
  is: Off refuses with your words, Ask asks once (Touch ID) for the whole publication, Shared
  sends. Turning the thing Off later ends it. Activity shows "Showing <thing> in a call" as a
  running act until it ends.
- **Everyone sees a tile.** The Mac joins the call as a participant of its own, as you (the
  mind's process signs in as you), so the call shows a tile "Jonas's Mac" beside your own. Pages
  without this app see it as any other tile; nothing changes for them.
- **One capture.** The record's capture feeds the call (`CaptureSink`), as it feeds live: a
  source that only the call wants starts with it. A screen goes at its own aspect within 1920×1200,
  at most 15 frames a second; the camera goes as three layers (full, half, quarter) so that each
  page takes what it can show. H.264 in hardware (VideoToolbox). A still screen gives no frames, so
  the last frame goes again when the connection connects and when no frame came for 0.2 s: a page
  that asks for a key frame gets one at once.
- **Ready before the choice.** When the device picker opens, the page calls `call.prepare()`. The
  Mac makes a connection and its offer for a screen and for the camera, with no picture in it. It
  reads no screen and no camera and asks nothing, so it is no use. A choice then takes the ready
  connection: the join and the publish go at once. A spare that no choice takes ends after 60 s.
- **It ends** with `call.unpublish`, when the page that asked leaves the call (its row is un-set),
  when you choose a browser device again, when the connection to the mind ends, when the Mac is
  lent to another mind, or when the app quits. At most 4 at once; one screen and one camera for
  each call (a second screen for the same call replaces the first).

How it is built: the job `call` of the mind's process (`bridge/call.mjs`) calls the call facet's
person methods (`join`, `signal`, `leave`) as a member's page does. The facet knows a page by its
subscription row on the agent's context, so each publication subscribes a row of its own,
`mac-call-<device>-<id>`; the kit reads that prefix and names the tile "<name>'s Mac". The app's
own peer connection (`CallSender` in `Sources/Live`, beside `LivePeer`) makes the offer (a spare
one from `call.prepare` when there is one, with the newest join's TURN servers or Cloudflare's STUN
server alone); the job sends the publish as soon as it has the offer and the row, also before the
join answers, and once more after the join when the facet did not know the page yet. The
facet passes it to Cloudflare's SFU and gives back the answer and the TURN servers (fresh ones at
three quarters of their life). The rules (sources, the gate's words, the list, the size, no TCP
candidate) are `CallRule.swift` in `VoiceMeetCore`, tested on their own. `DeviceCall` holds the
steps of each publication; `AppModel.publishToCall` is the gate. The picker is in
`@iterate-com/ui` (`call-rules.ts`: `liveMacs`, `macSources`; `call-engine.ts`: `chooseMac`).

Measured with `call-run` (below) on 2026-11-25 against iterate.com: a synthetic 1280×720 screen,
sender and receiver on this Mac, through the SFU. The time is from the choice to the first decoded
frame on the other page, the median of 6 runs:

| The other page | Prepared (the picker opened 1.5 s before) | Not prepared |
| --- | --- | --- |
| Receives a picture of the call already (as a page that hears your microphone) | 1.56 s (1.27–2.22) | 2.24 s (1.84–3.01) |
| Receives nothing yet: a new connection | 2.87 s (2.02–3.72) | 3.08 s (2.53–6.25) |

Before these changes the same runs took 3.0–4.0 s (median 3.2 s) for a page that received nothing
yet. With a prepared connection the SFU has the picture 0.5–1.0 s after the choice. The rest is
the other page: its subscribe (0.45–1.8 s; the facet asks the SFU), its answer, and its first key
frame (about 0.35 s after it connects). A page with a new connection waits 0.35 s for its own
candidates before it answers; without that wait it was 2.27 s (6 runs, all connected). A still
screen (`--still`) shows its first frame too, and then 4 frames a second. Touch ID under Ask is not
in these numbers.

What v0 does not do: the Mac's picture is not in your own tile (that needs the facet to take a
publication from a second peer connection for one page); a publication does not come back after
the mind's process connects again; no sound from the Mac; a guest has no Mac to choose; and the
SFU's data channels (remote control, `control.input`) are not used yet.

## Control: somebody drives this Mac

A member of the mind (Misha, on a call with you) drives this Mac's mouse, keyboard and clipboard,
as in a shared call: both of you have a pointer and keys, and yours win. **Control this Mac** is a
thing in "A mind can use", Off (the default), Ask or Shared. A page or an agent of the mind calls
the lend; this Mac posts the events as a mouse and a keyboard would. The picture of the screen
comes some other way (the call's screen share, or Live).

```js
const { session, display } = await mac.control.start({ by: "Misha" }); // display: { id, pixelWidth, pixelHeight, pointWidth, pointHeight }
await mac.control.input({ session, events: [
  { t: "move", x: 0.42, y: 0.61 },                    // 0–1 on the display, from its top left
  { t: "down", x: 0.42, y: 0.61, button: 0 },         // 0 left, 1 middle, 2 right; clicks: 2 for a double click
  { t: "up", x: 0.42, y: 0.61, button: 0 },
  { t: "scroll", dx: 0, dy: 120 },                    // pixels, as a WheelEvent's deltas
  { t: "key", code: "KeyC", down: true, mods: ["meta"] }, // a KeyboardEvent.code: a physical key
  { t: "key", code: "KeyC", down: false, mods: ["meta"] },
  { t: "text", text: "Grüße" },                       // typed as it is, in any layout
] }); // { applied, paused, withheld?, skipped?, problem? }
await mac.control.connect({ session, offer, iceServers }); // { answer }: a data channel for the batches (below, "Drive")
await mac.control.paste({ session, text: "from my clipboard", press: true }); // the pasteboard, then ⌘V
await mac.control.clipboard({ session }); // { text } of this Mac's pasteboard, at most 1 MB
await mac.control.state(); // who drives which display, since when
await mac.control.end({ session });
```

- **Your choice decides.** Off refuses (`control.start` fails with your words). Ask asks once for
  the whole session: "Misha wants to control this Mac", with Touch ID. Shared begins it. `by` is
  the name as the caller says it. Posting needs macOS's Accessibility, which the app already asks
  for the window text; without it, `control.start` says so.
- **You see it.** Purple means somebody drives: the 𝑖 in the menu bar is purple for the whole
  session, before every other colour (its tooltip says "Misha drives this Mac"), and a thin purple
  border goes around the controlled display (clicks go through it; it is in no picture of the
  screen, as the pill is not). The panel has a row with **End**, and Activity shows "Controlled
  by Misha" as a running act.
- **You win.** Each move, click, scroll or key of yours pauses every session for 1 s, and lets go
  of what a session held down, so that your moves are no drags. `control.input` then answers
  `paused: true` and drops the batch. **⌃⌥⌘Esc** ends every session at once; so do End, Control at
  Off, and another mind. A session also ends after 30 s with no call from its caller.
- **Not your passwords.** While the focus is in a password field, a password manager or secure
  input (`SecretKeys`), `key` and `text` events and `paste`'s ⌘V are dropped and counted as
  `withheld`. The mouse still works. `control.clipboard` gives no password manager's copy (it is
  marked concealed): `{ text: null, withheld }`.
- **Keys are physical**, as a browser's `code` is: "KeyA" is the key left of S on any layout,
  shortcuts too. Text in the person's own words is `text`; more than 2,000 characters is `paste`.
  `paste` replaces your clipboard; it does nothing while you have the mouse (`paused`).
- **Fast.** A batch is applied when it arrives, in order; consecutive moves are one, the last.
  The app takes about 0.1 ms from a batch's arrival to its last event posted (a test with a fake
  poster: `RemoteControlTests`); the log says the real figure each 500 batches. The rest is the
  way there: the page, the mind, the lend and the app's socket. At most 4 sessions at once.

How it is built: `ControlSessions` in `VoiceMeetCore` (`RemoteControl.swift`, with its tests) has
the rules: the key table, the mapping of 0–1 to the display's points (any display, any scale),
the moves folded into one, the click counts, the pause, the idle end, the sessions. The app's
`RemoteControl.swift` posts what they say with `CGEvent` at the HID level, each event with a
marker in its user data field; an event tap of the session tells the owner's input from the
app's by that marker. A copy with a home of its own posts nothing (it counts), and so needs no Accessibility and no event tap, unless
`ITERATE_CONTROL_POSTS=1`.

## Drive: a person in a call drives this Mac

In a call on meet.iterate.com (any page that uses the kit's call), a member presses **Drive** and
chooses this Mac ("Jonas's Mac", or the lend's first word, "zaktop"). The page shows this Mac's
screen large and sends the pointer, the wheel and the keys from over it. The gate is Control this
Mac, as above: Ask asks you with Touch ID, and your own input always wins.

**The offer is a fact in the mind, not a list in a config file.** The app says on `/devices/<name>`
whether the Mac may be driven now:

```js
{ type: "device/control-configured", payload: { kind: "mac", lend: "jane.mac", control: "ask",
  displays: [{ display: 0, name: "Built-in Retina Display", screen: "shared" }] } }
{ type: "device/control-configured", payload: { kind: "mac", lend: "jane.mac", control: null,
  why: "Control this Mac is Off" } }
```

- An offer needs Control this Mac at Ask or Shared, Accessibility, and one display at least whose
  screen is not Off: the driver sees that screen in the call. `displays` lists those displays.
- It is said at each connection of the mind's process, and again only when it changes (Control
  this Mac, Accessibility, a display's choice, a display that comes or goes). `control: null`
  says why it ends: Off, no Accessibility, every display Off, the app quits, the Mac is lent to
  another mind. A Mac that goes away with no word leaves its last fact: the page also checks
  that the lend is live.
- The rules are `ControlOffer` and `ControlOfferTeller` in `VoiceMeetCore`, tested on their own;
  `AppModel.tellControlOffer` says it.

**The page** (`@iterate-com/ui`, call-engine.ts `listDrives`) reads, in the call and every 30 s:
the live lends, the contexts under `/devices` whose types hold the fact, and the newest fact of
each (its newest 200 offsets the first time, then the offsets since its last read). An offer
older than that is read from the Mac's own `state()`. A choice then calls `control.start({
display, by })`, puts the screen in the call (`call.publish`, or the publication that is there
already: your own share is not ended by the driver), and sends each batch to `control.input`, one
batch in flight. A driver not on a Mac presses Ctrl for ⌘. The driver's paste (⌘V or Ctrl+V)
goes to `control.paste`. A guest gets no Drive menu in v0.

**The direct path.** A batch through the mind takes about 110 ms there and back. So the page also
offers a WebRTC data channel, `control`, straight to this Mac: `control.connect({ session, offer,
iceServers })` answers this Mac's description, with its candidates in it. The mind carries only
that one call. Each message on the channel is `{ id, events }`, applied as `control.input`, and
the answer comes back on the channel as `{ id, applied, paused, … }`. Until the channel opens, and
when it closes, the batches go through the mind. The channel uses the call's ICE servers (its
TURN relay too). It belongs to its session: `control.end`, the session's end and the app's end
close it. `ControlChannels` in `Sources/Live` holds it; its factory has the app's own audio device
that sends nothing, so libwebrtc opens no microphone and no speaker. `control.state()` says
`direct: true` for a session with an open channel.

Measured on 2026-11-26, from a page on this Mac to a test copy of the app (`--home`, lent as
`itx.drivetest.mac` to iterate.com), one batch of one move, its answer, then the next:

| Path | p50 | p90 | max |
| --- | --- | --- | --- |
| Through the mind (`control.input`), 28 batches | 110.5 ms | 151.4 ms | 162.5 ms |
| The data channel, 195 batches (a page of the test) | 0.6 ms | 1.2 ms | 5.6 ms |
| The data channel, 200 batches (the kit's own engine) | 0.8 ms | 1.2 ms | 1.5 ms |

The channel opened 0.8 s after the choice (Shared, no question). Both ends were on one Mac, so
the channel's numbers are the app's and the browser's own cost; between two networks they add the
network's round trip, which is still shorter than a trip through the mind. A copy with a home of
its own posts nothing (it counts), so it needs no Accessibility to be driven in a test.

## This Mac's pages: a small site, served through the lend

The app ships a site of its own: the files of `pages/`, served by `mac.http({ method, path, query,
headers })` (`bridge/pages.mjs`), which answers `{ status, headers, body }`. A mind's site passes it
on to a member's browser; `pages/MIND-ROUTE.md` has that code (not deployed in any mind yet).

| Path | What it answers |
| --- | --- |
| `/` | One HTML page with no build step: this Mac's name, its lend, the record, the newest acts, and a live view on a press of **Watch the Display**. The system's font, light and dark. |
| `/state.json` | The same data as JSON: what the app already knows, nothing it asks for. |
| `/live.mjpeg` | The main display (or `?display=N`) as `multipart/x-mixed-replace` JPEG frames. |

- **Pages** is a thing in "A mind can use", beside Commands: Off (the default), Ask or Shared. Every
  request is a use of it. Off is a `403` with your words; a mind's site passes them on.
- **The live view is also a use of the display**, as a snapshot is: password managers are left out,
  and one question covers the whole view when Pages or the display is on Ask. It is an act in
  Activity ("Showing the display … live in a page") from its start to its end, and it ends at once
  when you turn Pages or the display Off.
- **Bounded.** At most 4 frames a second, 1280 px wide, made off the main thread; at most 2 views
  at once; each ends after 10 minutes. A frame is made only when the reader took the one before:
  for a slow reader the frames between drop, and the bridge holds at most one. Over capnweb the
  connection carries at most its flow window (256 KB at the start: 3 frames of 150 KB in a test,
  then no more until the mind reads). A cancel of the body (the browser went away) ends the view in
  the app at once; a view whose bridge asks no frame for 15 s ends too.

How it is built: `bridge/pages.mjs` serves the files and the stream; it asks the app on its socket
(`pages.state`, `pages.live.start`, `pages.live.frame`, `pages.live.stop`), and the app decides
(`Sources/VoiceMeetMac/PagePowers.swift`).

## Capture: show an agent what you mean

Press **⌥⇧S** in any app, then talk, click, and hold **⇧** and move the mouse to draw on the
screen in red (no button). Press ⌥⇧S again (or Send on the pill at the top of the display). A short
text is on the clipboard at once: paste it to an agent. The capture also goes into the mind this
Mac is lent to. The gesture and the shape of the text are
[Scrawl](https://github.com/kitlangton/scrawl)'s, by Kit Langton. A capture is your own act, so it
has no switch in the panel; it needs macOS 15, Screen Recording, and the microphone for your
voice. It ends by itself after 10 minutes. Discard on the pill throws it away.

In a mind that looks a capture up itself (the rule `itx.getScrawl`; "The boundary with the mind",
below), the text on the clipboard is one line, the capture's id and the one call:

```
Run itx.getScrawl("<id>") on example.com to see the scrawl
```

How an agent reads the answer (look at the pictures first, what `pending` means, a link for each
picture) is in that answer, as `how`: it is the mind's text, and it changes there with no release
of this app. `summary.md` of the capture still holds the long text below. In a mind with no such
rule, and for a capture that stayed on this Mac, the long text is on the clipboard: a line for
each **numbered picture** with the words you said at it, and the two ways to the pictures:

```
[capture 0:15 · Ghostty “my project” · jonas.mac → example.com]
The words point at red marks on the screen: look at the pictures before you answer. Each # is a numbered picture.
Get the pictures in one of these ways, then answer from them and the lines below alone:
- On jonas.mac: read sheet.jpg and 1.jpg, 2.jpg together, in /Users/…/iterate-mac-app/captures/<id> (open nothing else there).
- Anywhere else, through the mind example.com: the capture's id is <id>, and one call answers its words, its marks and its pictures: await itx.getScrawl("<id>"). The iterate MCP tool "run" takes async (itx) => await itx.getScrawl("<id>") and shows the pictures as images. An agent of the mind: your AGENTS.md says how you look at the pictures. With a shell and no image: add { urls: true } and download each link in "urls" (curl -o). A state "pending" says that the capture still arrives: ask again.
- #1 (0:06) drew “what is this here?”
- #2 (0:12) clicked “Save” “and this is slow”
```

Each mark and each click gets a numbered picture: the part of the display around it, cut out
while you talk. `sheet.jpg` is all of them on one. While you talk the pictures go up, and your
voice is put into words at each pause by the one transcriber of every feature ("Listening" below:
GPT Live Transcribe at OpenAI when it can be reached, else the local model on this Mac), with the
`words.md` list of the capture's mind. At OpenAI one socket serves the capture: each pause of
0.7 s commits the sound so far, and its text is a segment with its times. The pill shows the last
words: the sign that the microphone hears you. So at the end
only your last words can be missing: the long text says so, and the same text with all the words
takes its place on the clipboard a moment later, unless you copied something else. The one line
does not change: the mind's lookup waits for the last words.

**The boundary with the mind** (27 November 2026). This app makes the capture: its id, its files
under `/captures/<id>/` and the two events below. The mind reads it: `itx.getScrawl(id, { waitMs?,
urls? })` is code of the mind's own config (`apps/scrawl/` of iterate.com's config), behind
the mind's rule `itx.getScrawl`. It answers `{ state: "ready", said, marks, pictures, "itx/images"
}`, or `"pending"` while the capture still arrives (it waits up to 30 s for it first), or
`"unknown"`. It reads and delivers nothing, and the mind decides who may read. So the text holds an id, which is a name and no
key: no link, no path of the mind and no code. The app asks once, at a capture's start, whether the
mind has the rule. In a mind that has none, the text holds one script in the call's place: it
waits for `capture/ready`, reads `context.json`, makes a signed link for each picture, and sends
the pictures to an agent of the mind as images.

**Who reads the text, and what they get** (tested with real agents on 21 November 2026, with the
script; the call does the same in each row):

| The agent                                         | What it does                                | Does its model see the pictures?                                                                                                               |
| ------------------------------------------------- | ------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| On this Mac (Claude Code, Codex)                  | Reads the numbered pictures from the folder | Yes                                                                                                                                            |
| In the mind (the Dash, Slack)                     | Makes the text's call (or runs its script) | Yes: the script sends them to that agent as the files of a message                                                                             |
| Elsewhere, with the mind's MCP tool and a shell   | Makes the text's call (or runs its script) | Yes                                                                                                                                            |
| Elsewhere, with the iterate CLI and a shell       | Runs the script's body with `iterate itx run --eval`, then downloads the links in `urls` | Yes, from the downloaded files (25 Nov 2026: an agent on Beelink found no way to the pictures before) |
| With the mind's MCP tool alone (no shell, no web) | Makes the text's call (or runs its script) | Yes: the tool answers the pictures as images. A mind that does not have that yet answers text, with `seen`: what a model read off each picture |

Each of them answers in one turn: one reply to the one message with the text.

The call (and the script) waits for the event `capture/ready`, so a text that is pasted before the
capture is whole still gives the whole capture. The folder stays on this Mac for 7 days.

A capture is a set of **observations**, each with its time in milliseconds from the start. They
are files of the mind under `/captures/<id>/`, and the capture is a context of its own at that
path, with two events: `capture/ready` (the words, the marks and the pictures are there) and
`capture/received` (the movie too):

| File                   | What it holds                                                                                                                                                                                                                                                                                                                 |
| ---------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `summary.md`           | The text on the clipboard, with all the words                                                                                                                                                                                                                                                                                 |
| `1.jpg` …, `sheet.jpg` | The numbered pictures, at most 12, and all of them on one. A capture with no mark and no click has one: the display at the end                                                                                                                                                                                                |
| `context.json`         | What the text's call or script answers: the words, the marks, and the pictures under `"itx/images"`                                                                                                                                                                                                                                   |
| `seen.json`            | What a model read under each mark, for a reader that gets no picture: a model's claim                                                                                                                                                                                                                                         |
| `transcript.json`      | The words with their times (`segments`: `t`, `to`, `text`, `words`), as the speech model heard them (`by`: the one the rule picked at the start): a model's claim, not an observation                                                                                                                                                       |
| `capture.json`         | The observations: `screen` and `voice` (the two files below), `window` (the app in front, its window's title, a browser's page URL, its accessibility tree: a new one at each change), `click` and `ink` (the points, and the accessibility element under them), `picture`; the numbered pictures (`panels`); and the display |
| `pictures/01.jpg` …    | At most 12 sharp stills of the whole display: at each mark, at the start and the end, at a change of window, at a click                                                                                                                                                                                                       |
| `screen.mp4`           | The display under the pointer, with the ink on it and your voice: small (1600 pixels wide, 10 pictures a second)                                                                                                                                                                                                              |
| `voice.m4a`            | The voice alone                                                                                                                                                                                                                                                                                                               |
| `accessibility/0.json` | The window in front as text, for the first six windows                                                                                                                                                                                                                                                                        |

**The word list.** The capture uses the mind's `words.md`, the one list of dictation and the input
("Dictation" below): its terms are listened for, and its wrong forms are written as the terms.

The Mac's key only lends, so the capture goes up as you: the job `capture` of that mind's process
(`bridge/capture.mjs`) uses the iterate CLI's own sign-in to it (`iterate login <mind>`, once). A
capture keeps its mind: when the Mac is lent to another mind before it is sent, it still goes to
the one it began with. With no sign-in, or no network, the capture stays in
`~/Library/Application Support/iterate-mac-app/captures/<id>/` with its `transcript.json`, the text
on the clipboard names the files there, and the panel says why. Send it later with one line on a
process for that mind:

```sh
echo '{"job":"capture","capture":"<id>","folder":"<folder>","finish":true}' \
  | node bridge/mind.mjs <mind> --name <name> --iterate <iterate.js>
```

## Input: say or type what you want to a mind

Press **⌥⇧Space** in any app (or **Input** in the panel). One bar opens, and it
listens: talk, type, or both, and press **Return**. That is all the bar knows: it has no commands
and no list of actions. What happens with your words is the mind's own matter.

- **The microphone.** The bar starts by listening. What you say is written into the text as you
  say it, by the one transcriber ("Listening" below: at OpenAI when it can be reached, else on this Mac),
  with the word list of the mind the input goes to. The
  button at the right shows the loudness; a click, or **⌘D**, turns the microphone off, and again
  on. Words that you change by hand stay as you made them: only what you say after that comes in.
  The microphone is open only while the bar is open: Escape, Return and ⌥⇧Space close it. A bar
  that comes back with a failed input does not listen.

- **Files.** **⌘V** adds the files on the clipboard, or a picture that is there with no file (a
  screenshot); text on the clipboard goes into the text. Drop files on the bar from any app: the
  bar stays open while another app is in front. Each file is a chip with its size and a ×; Delete
  in an empty text takes the last one away. At most 20 files, each at most 500 MB; a folder is
  refused.
- **The mind.** The face at the left is the mind the input goes to. A click lists the minds this
  Mac knows (the panel's mind switcher adds and removes them); **Tab** chooses the next one. The
  bar starts with the mind you chose last, else the one this Mac is lent to. The choice changes
  nothing of the lend: an input can go to a mind this Mac is not lent to.
- **Keys.** ⇧Return and ⌥Return make a new line. Escape, or a click outside the bar, closes it and
  keeps what you wrote; ⌥⇧Space opens it again. The text grows to six lines, then scrolls.

Return closes the bar at once. One input goes at a time: while it goes, the bar shows it and takes
no new one. The input goes up as you, as a capture does: the job `input` of that mind's process
(`bridge/input.mjs`) uses the iterate CLI's own sign-in to that mind (`iterate login <mind>`, once). When it did not go
(no sign-in, no network, a file that failed), the bar comes back with your text, your files and the
reason, and Return sends the same input again (the same id: the mind keeps it once). When the
reason says the sign-in is missing, or the iterate CLI has none for that mind, the bar shows the
command that fixes it (`iterate login <address>`) with **Copy**. An input you
changed first is another input, with a new id. The line under the panel's three buttons says how
the newest of the last capture, input and dictation ended, in orange when it failed.

**What the mind gets.** Each file is a file of the mind, and then ONE event is on the context
`/devices/<name>` (the name of this Mac in that mind):

```
/devices/<name>/inputs/<id>/<n>-<file name>

device/input-submitted {
  id: "20261124T140211Z-3fa9",
  text: "Open the roadmap on Misha's computer",
  at: "2026-11-24T14:02:11Z",
  files: [{ path: "/devices/jane.mac/inputs/…/1-Roadmap.pdf", name: "Roadmap.pdf", contentType: "application/pdf", bytes: 2200000 }]
}
```

The event has the idempotency key `device/input-submitted/<id>`, so an input that is sent twice is
in the mind once. **The event is the whole contract.** A mind that does nothing with it keeps it in
the device's log. To act on it, the mind's config handles that event type (for example: start an
agent with the text and the files as its first message). Which agent or model answers is the
mind's choice, and it can change with no new build of this app.

## Dictation: talk, and it is written

Hold **fn** (🌐) in any app and talk. Let go, and what you said is written where the cursor is.
Double-tap fn (two presses within half a second) and the dictation stays on with no key held: the
next press of fn ends it and writes the text, and **Esc** ends it and writes nothing. This is how
Wispr Flow works. A press shorter than 0.35 s listens until half a second after it went down; with
no second press, the sound is thrown away. fn with another key (fn-arrow, fn-delete) is that key's
combination: the dictation it started ends with no sign. **⌥⇧D** works too, as the open source
app [Hex](https://github.com/anomalyco/hex) does it: hold it and talk; a short press keeps the
dictation on until the next press. The panel's **Dictate** button starts one that stays on. A pill
at the bottom of the screen shows the words on one row while you talk, the newest at the right,
with a lock while it stays on and the time since the start.

### Dictation becomes a capture

While a dictation stays on (fn tapped twice, or ⌥⇧D), you can switch to showing instead of
telling. Tap **⇧** alone (down and up, with no other key in between). A capture starts at once
on the display under the pointer ("Capture" below):
- Hold ⇧ and move the pointer to draw, and click on things.
- Your words from before the ⇧ go into the capture's transcript as its first words.
- The next press of **fn** ends the capture and sends it.
- The capture's text (its id and `itx.getScrawl`) is written where the cursor is, and it also
  stays on the clipboard. ⌥⇧S ends it too.

⇧ is heard only while a dictation stays on, and only when a capture can start now (Screen
Recording given, no capture running). ⇧ with a letter is typing, not a tap.

- **fn needs Accessibility.** The app hears fn with event taps of the session, which macOS
  gives only to an app with Accessibility (the permission that also writes the text for you). One
  tap hears the modifier keys; the tap for key presses is on only while fn is down or a dictation
  goes, so the rest of the Mac's typing passes no tap of this app. It swallows one key: Esc while
  a dictation stays on, so that Esc does not reach the app in front. Without the permission, ⌥⇧D still works, its first use opens the permission's guide, and
  Settings › Dictation says so. macOS can act on 🌐 too (the emoji
  picker, or its own dictation): when System Settings › Keyboard › "Press 🌐 key to" is not "Do
  Nothing", Settings › Dictation says to set it, with **Open Keyboard Settings**. The app changes
  no setting. Settings › Dictation can turn fn off (⌥⇧D stays) and the double tap off (a short
  tap then does nothing).
- **One listening at a time.** Dictation and the input bar share one microphone listening
  (`SpeechSession`), which reads the one microphone stream ("Listening" below). When one starts
  while the other listens, the other ends first: its last words are written where they belonged.
- **GPT Live Transcribe at OpenAI, when the lent mind has an OpenAI key (or this Mac has one);
  else on this Mac.** One rule picks who hears for every use: dictation, the input bar, the
  capture and Always listen ("Listening" below). Settings › Dictation (the panel's Settings button
  opens it) shows the model; "On this Mac" there makes the local model hear every use.

  | Model                       | Runs         | Download | License   | Note                                                     |
  | --------------------------- | ------------ | -------- | --------- | -------------------------------------------------------- |
  | GPT Live Transcribe         | OpenAI       | none     | OpenAI    | The default with a key (the mind's or yours). $1/hour of talking; the sound leaves this Mac |
  | Oruk Fourier 2B             | this Mac     | 2.68 GB  | CC BY-NC 4.0 | The default with no key, and the model behind OpenAI. **Non-commercial**: see below |
  | Parakeet TDT 0.6B v3        | this Mac     | 480 MB   | CC BY 4.0 | The model behind OpenAI until Fourier is on this Mac     |
  | Parakeet Ultra              | this Mac     | 632 MB   | CC BY 4.0 | A post-training of v3, which FluidAudio 0.18.4 recommends |

  **Oruk Fourier's licence is non-commercial.** [Oruk Fourier 2B](https://huggingface.co/oruk/oruk-fourier-2b)
  is under CC BY-NC 4.0: no commercial use. The owner accepts it for his own Mac for now. Before
  this default ships to anyone else (a release of the app to other Macs, a customer, a commercial
  use), iterate must have Oruk's permission; until then, Parakeet v3 (CC BY 4.0) stays a choice in
  Settings › Dictation. The app downloads the model from Oruk's repository on each Mac; it does not
  redistribute it.

  Why OpenAI is the default: on the owner's own voice (`harness/speech-bench`, 25 November 2026)
  `gpt-live-transcribe` with delay `low` had WER 10.3 and got 130 of 146 terms; Parakeet v3 had
  WER 21.8. It costs $0.017 a minute of sound, about $1 an hour of talking.

  The app opens a WebSocket to `wss://api.openai.com/v1/realtime?intent=transcription` at fn down,
  with the session that the bench measured: `gpt-live-transcribe`, delay `low`, 24 kHz pcm16, no
  turn detection, the mind's word list terms as `keywords`, and the bench's prompt. The sound is
  kept from fn down, so a socket that opens late loses no word (its setup costs about 0.8 s). Each
  delta is the pill's text; at the end a commit asks for the final, which the word list repairs.
  Each socket serves one dictation. When OpenAI fails (no session within 5 s, an error
  while you talk, no final within 5 s of the end, or no socket through the mind and no key), the local model (Oruk
  Fourier 2B, or Parakeet v3 until Fourier is on this Mac) hears what was kept and
  what comes after, and `app.log` says why ("gpt-live-transcribe failed after 0.31 s (…): the local
  model hears it"). The code: `Sources/SpeechText/OpenAIStream.swift` (the session on a socket),
  `OpenAISocket.swift` (the two sockets: `DirectSocket`, URLSession's WebSocket with this Mac's
  key, and `RelaySocket`, relayed by the mind's bridge), `StreamRecognizer.swift` (the stream,
  with the local model behind it).

  A new socket is ready 0.74 to 1.02 s after it opens (p50 0.82 s, measured on 25 November 2026),
  so the live words came late. Thus one **standby socket** waits for the next dictation, opened
  and configured with the same session in the background when a dictation ends. fn down takes it
  when it is open, has the word list's current keywords and answers a ping (0.5 s at most); else
  it closes it and opens a new socket, as before. There is at most one standby, and only while
  GPT Live Transcribe is the model and the mind or a key opens it; it opens the same way as a new
  socket, through the mind or with the key. It closes when the model, the lent mind or the key changes, when the Mac sleeps, and after 10 minutes unused (then the next one opens only after the next
  dictation, so an idle Mac holds no socket for long). One that the server or the network closes
  is dropped, with a line in the log and nothing else. An open socket with no sound costs nothing:
  OpenAI bills transcription by its audio. The speech log says, for each dictation,
  `gpt-live-transcribe is ready 8 ms after the start (standby, mind)`, or `(new, own key)`:
  where the socket came from, and what opened it. A new socket's line, and the standby's, also
  say when OpenAI's `session.created` came after the socket's start. The ping of a standby
  through the mind asks the mind's bridge, which answers when it holds the socket open (about
  8 ms); a direct ping goes to OpenAI (about 140 ms). The code: `OpenAIStandby.swift`.
- **The OpenAI key is the mind's, and the socket opens through the mind.** A mind keeps its
  OpenAI key at `/secrets/openai` in its vault and never hands it out. For each socket the app asks
  the bridge of the mind it is lent to (the job `openai`, `bridge/openai.mjs`, on the connection
  that the word list uses). The job opens the socket with `itx.fetch` of
  `https://api.openai.com/v1/realtime?intent=transcription` with `Upgrade: websocket` and the
  header `Authorization: Bearer getSecret("/secrets/openai")`: the vault puts the key in on the way,
  and the mind hands the upstream socket back to the bridge (iterate/private #1394, on iterate.com
  since 25 November 2026). The bridge relays the socket's text frames both ways over its JSON lines
  (`{ job: "openai", socket: <id>, frame }`, with `open`, `opened`, `ping`/`pong`, `close`,
  `closed { code, reason }` and `failed { refused? }`). OpenAI's frames are JSON text, the sound
  base64 inside `input_audio_buffer.append`, so only text goes. The socket gets the usual
  `session.update`, with the keywords; the stream, the standby, the billed log and the fallbacks
  are the same as on a socket of this Mac's own key. A drop of the bridge's connection to the mind,
  or the end of its process, fails every socket of it, and a dictation on one falls back. No key,
  no token and no frame is logged; the words of a failure have any key cut out.

  Measured on the owner's Mac on 25 November 2026 with the synthetic fixture (`say -o`, 4.4 s, 8
  dictations each, in a test copy, no word list): from the socket's start to `session.created`,
  p50 515 ms through iterate.com against 497 ms direct (p90 578 against 535 ms); from the end of
  the dictation to the final text, p50 0.65 s through the mind against 0.67 s direct (p90 0.72
  against 0.68 s). With the mind's 59 terms through the mind: 506 ms and 0.67 s.

  Whether the lent mind can open a socket is found out with one socket opened and closed at each
  new connection of its bridge (no sound, so OpenAI bills nothing), and by each dictation's: a mind
  with no `/secrets/openai` (or a key OpenAI refuses) says no (`refused`), and then Oruk Fourier 2B
  is the default, unless this Mac has a key of its own. A failure with no `refused` (no
  connection, no socket within 5 s, an error of OpenAI's servers) may pass, and the mind is asked
  again at the next dictation. Settings › Dictation says "OpenAI through <mind>: the mind's key"
  when a socket opened through the mind. The code: `MindSockets.swift`,
  `SpeechText/OpenAIAccess.swift`, `SpeechText/OpenAISocket.swift`.
- **Your own key is optional, and only behind the mind's.** It is used when this Mac is lent to no
  mind, or the mind said no (it has no OpenAI key; the log says "no socket through <mind> (…): your
  own key"). Any other failure of the mind's socket (a drop, a timeout) goes to the local model,
  never to the key: a Mac lent to a mind with OpenAI does not read the Keychain, so macOS never asks
  for it, also not after an update. It is in the login Keychain: a generic password of the service
  `com.iterate.mac-app.openai` and the account `api-key`. It is never in a file, a log, `ui.state`
  (which says only `speech.openAIKey`: true or false, and `speech.openAIMind`: the mind that sockets open through, or null) or a process's arguments. Settings ›
  Dictation says whether it is set, takes a new one in a secure field, and removes it. Or from a
  terminal: `OPENAI_API_KEY=… npx @iterate-com/mac-app --openai-key-from-env` gives the key to
  `security` on its standard input, trusts /Applications/iterate.app to read it, and says only
  "OpenAI key stored". A copy with a home of its own uses the service with `.` and the first 12
  hex digits of the SHA-256 of its home's path, so a test never reads or writes the owner's item.
  With no stored choice, a mind that opens sockets or a key that comes makes GPT Live Transcribe the model,
  and when neither is left it is the local default (Oruk Fourier 2B); a choice in Settings stays.
- **The local models run on this Mac.** With them no sound and no text leaves the Mac. Each one
  shows its size and whether it is on this Mac. A model that is not on this Mac downloads when you
  choose it, with its progress in its row of Settings › Dictation, and is the model once its files are here.
  The choice is kept in the app's defaults (`speechModel`). They need Apple silicon.
  - **Oruk Fourier 2B** (the default) is a fine-tune of Qwen3-ASR, 2.04B parameters, as Oruk's
    MLX 8-bit form (`mlx/8bit`, 2.46 GB). It runs on the GPU through
    [mlx-audio](https://github.com/Blaizzy/mlx-audio) 0.6.7, in a Python process of its own that
    the app starts: it loads the model once, then hears each stretch that the app sends it as JSON
    lines on its stdin (`Sources/SpeechText/Fourier.swift`). The process holds 2.6 GB, so it is
    loaded only when it must hear (`LocalSpeech`; "Listening" below): on a normal day online it is
    never loaded. A load took 0.92 to 1.38 s once its files were read before (measured three times
    on 25 November 2026, M4 Max, `speech-bench`, from the start of the load to a ready engine). It
    also ends when the app ends or another local model is chosen. The word list's terms go into its prompt. Its files
    are in `~/Library/Application Support/iterate-speech/oruk-fourier-2b` (2.85 GB), shared by
    every copy of the app on this Mac (`ITERATE_MAC_FOURIER_FOLDER` names another folder): a
    pinned uv (0.11.28) makes a venv with its own Python 3.12, installs the 47 packages of
    `FourierLock.swift` with `--require-hashes` (`node harness/fourier-lock.mjs` writes it), and
    the model's 11 files come from revision `d058401c` of `oruk/oruk-fourier-2b`, each checked
    against its SHA-256. A download that stops goes on from where it was; `setup.log` there says
    each step. The first use downloads 2.68 GB in all (about 2.5 minutes on the owner's line).
    On a Mac that had Parakeet v3 before Fourier became the default, v3 stays the model until
    Fourier is on this Mac: the installed app gets Fourier in the background a few seconds after
    its start, with its progress in its row (it downloads, and does not load), and uses it once its
    files are here.
  - **Why Fourier, and why 8-bit.** On the bench's synthetic set with no word list (25 November
    2026), Fourier 8-bit had WER 16.3 (plain sentences 3.3), Parakeet v3 27.4 (13.3), Parakeet
    Ultra 29.2. Fourier's BF16 checkpoint (4.08 GB, converted to MLX by
    `harness/speech-bench/engines/oruk-bf16.py`) had WER 16.1 (plain 3.3): no more accurate, and
    slower (end of audio → text 0.44 / 1.14 s at p50 / p90 against 0.20 / 0.28 s). So the app runs
    8-bit. The app's own path (`fourier-app`: the recognizer, its pauses and its paced partials)
    had WER 15.9, the first words in the pill 0.92 s after the start, and the final 0.55 / 0.81 s
    after the end of the audio (Parakeet v3 in the app: 0.43 / 0.66 s). MLX Swift is not the runtime: the app builds with Apple's Command Line Tools, which have
    no Metal compiler for MLX's kernels, and Fourier's Swift port is a prerelease fork; mlx's
    Python wheel brings its kernels built.
  - **Parakeet v3 and Ultra** run as Core ML through
    [FluidAudio](https://github.com/FluidInference/FluidAudio), the library of the Swift Hex, from
    `~/Library/Application Support/FluidAudio`. Ultra got more terms wrong than v3 on the owner's
    own captures and a fixture of the list's hard terms (`harness/speech-bench`, 24 November 2026).
- **The local model is ready when it must hear.** It loads at once when the rule picks it: the
  network drops (`NWPathMonitor`), no mind opens OpenAI and this Mac has no key, or "On this Mac"
  is chosen; so an offline dictation finds it ready. A stretch whose OpenAI fails loads it too,
  and waits for it. A load comes 3 s after the app's start at the earliest, and a home of its own
  loads nothing before a use unless an audio fixture is set. Core ML prepares a Parakeet model for
  the Neural Engine at its first load (24.9 s, then 0.25 s while macOS keeps what it prepared;
  measured on 25 November 2026). You can talk during a load: the microphone is open and what you
  say is kept (the last 60 s). The pill says "Getting the speech model: N%" only while files
  download, and "Loading the speech model" while they only load.
- **The mind's word list.** A mind keeps the names and terms that a speech model must get right in
  `words.md`, at the root of its config repo: one list item for each term, and after a colon the
  wrong forms that a transcript showed (`- Templestein: temple stein, temple steen`). The app reads
  that file as you (the job `words` of the mind's process, `bridge/words.mjs`, the iterate CLI's sign-in) and keeps a copy in
  `~/Library/Application Support/iterate-mac-app/words/<mind>.md`, fetched again when it is older
  than ten minutes. What it reads is a setting, an itx expression: by default
  `itx.repos.get("/repos/config").readFile("words.md")`; Settings › Dictation sets another for
  every mind (config.json's `wordsExpression`), and a mind's page one for that mind
  (`minds[].wordsExpression`). The expression runs as you on that mind, with `itx` in scope (an
  expression, or an `async (itx) => …` function), within 30 s, and must answer text with one
  `- term: wrong form` on a line; an empty text is no list. Any other answer fails with its reason
  ("This answered a commit id, with no line that starts with "- ""), and the last good list stays
  in use. A new expression fetches at once, and so does **Fetch Now** on the mind's page, which
  shows the count, when it was fetched and the first terms. The app runs no expression that came
  from anywhere but this setting. The list does two things. Oruk Fourier gets the terms in its
  prompt (mlx-audio's `hotwords`). For the Parakeet models a second, small model (Parakeet CTC 110M, 100 MB)
  listens for the terms in what you said and puts a term in where the sound fits it; it works
  with both, as they share v3's tokenizer. Then each wrong form, and each term
  in another case, is written as the term: whole words only, the longest form first, and any run
  of separators between a form's words (spaces, `-`, the hyphens and dashes U+2010 to U+2015, the
  minus U+2212, `_`) matches any other run, so `b link` also catches `b-link` and `B‑Link`. A full
  stop is no separator: "b. Link the box" ends a sentence. While you dictate, the pill shows each
  such repair as the heard words struck through and the term after them; the text that is
  written has the term alone. Dictation uses the list of the mind this Mac is lent
  to; the input bar uses the list of the mind the input goes to; a capture uses its mind's. A mind
  with no `words.md` gives no list.
- **How the text goes in.** The text is put on the clipboard, ⌘V is pressed for you, and the
  clipboard gets back what it held. That needs the **Accessibility** permission. Without it the
  text stays on the clipboard, and the app opens the guide for the permission. Settings ›
  Dictation, "Put the text: On the clipboard only", leaves it there, with no ⌘V.
- **Sounds.** A soft rising tone when listening starts (fn held 0.2 s, the double tap's lock, ⌥⇧D, the Dictate button, the input bar's microphone), a softer falling one when the text is written, and a low one for Esc: sines made in `SoundCue`, under 150 ms, at a tenth of full scale; the microphone opens first, and Parakeet v3 wrote the same words with the tone over the first word. Settings › Dictation, "Sounds" (`dictation.sounds`), turns them off; a home of its own and a drawing never make one (`ui.state`'s `sounds.silenced` counts them).
- **Permissions.** The microphone, at the first use. The line under the panel's three buttons
  says how the last dictation ended, when it is the newest. `app.log` holds counts and times, never the words.
- **The history, and "Paste the last transcript".** Every finished dictation goes into a history
  on this Mac: its text as it was written (with the word list's corrections), the time, the app
  it went into (its name and bundle id) and the window's title (read off the main thread, and
  never of an app that `ExcludeList` names, the password managers), the model, its words and
  seconds, and how it ended: written, heard no words, or cancelled with Esc (its text is kept:
  that is when you want it back). With Always listen, each stretch goes in too, as "Always
  listen". The history is `dictation-history.jsonl` in the app's home (a copy with `--home` keeps
  its own): one JSON line an entry, at most 2,000 entries of the last 30 days, the oldest dropped
  first, written on a queue of its own (`History`, and `TranscriptHistory` in `VoiceMeetCore`). A
  file that cannot be read starts empty, with one line in `app.log`, and its bytes stay beside it
  as `dictation-history.broken.jsonl`. It stays on this Mac and is no event to a mind: the
  record's `transcript` track already is, when you share the microphone. Settings › Dictation,
  **Keep a history** (`dictation.history`, on unless set), turns it off: then a transcript is
  kept in memory alone, for ⌥⇧W, and nothing is written. **Clear History…** asks once, in the
  page, then empties the file.

  **⌥⇧W, "Paste the last transcript"** (Settings › General sets another key, or none;
  `listen.write` on the control socket) writes the newest entry of the history where the cursor
  is: a dictation's text, or with Always listen the newest stretch, whichever ended last. It reads
  the history, so it works after a restart too: when the text went into the wrong field, or
  nowhere. The panel's **Dictate** button has it in its menu (Control-click): **Paste Last
  Transcript** and **Show Dictations**.

  **The Dictations view** is the Activity window's third mode, **Dictations**, beside Acts and
  Every event: newest first, each row its time, the app's icon and name, the text in two lines
  (all of it when chosen), and **Copy** and **Paste**. Paste writes it where the cursor is in the
  app that was in front before the window: that app comes to the front, then ⌘V. The search
  keeps the rows with every word of it. At the right are the chosen transcript's fields and its
  whole text. The list is lazy: only the rows on the screen are made. It is a mode of the
  Activity window, not a window of its own, because that window already has the switch, the
  search and the pane at the right that it needs.

With a local model, while you talk, the text is written again from the stretch of speech that is
going: twice a second with Parakeet; with Oruk Fourier, which has no partial text of its own and
hears the whole stretch at each pass, at most once a second, and never sooner than twice the last
pass's time (`PacedEngine`). A pass took 0.08 s for 1 s of speech, 0.15 s for 4 s, 0.38 s for
10 s and 0.45 s for 12 s (25 November 2026, an M4 Max). A stretch ends at a pause of 0.7 s, or
after 14 s at its quietest moment; then its text is final: one more pass, one segment, with its
times from the start (Fourier gives no times of its words). With GPT Live Transcribe a
dictation is one segment, with no times of its words; a capture is a segment at each pause.

## Listening: one microphone, in layers

Dictation, the input bar, Always listen and the record's microphone are layers on ONE stream of
the microphone. Each layer has its events, and the layer above reads them. Speech-to-text is ONE
capability (`Transcriber`), and two providers satisfy it: OpenAI and the local model. The
features are built on what it writes, and none of them chooses a model.

| Layer | What it is | Its events | Who reads them |
| --- | --- | --- | --- |
| 1. The microphone stream | `MicStream`: the one owner of the input device (an `AVAudioEngine` tap, or the audio fixture) | `frame`: 16 kHz mono samples and the wall time of the first one; the device's own buffers and their host time; `failed` | `SpeechSession` (dictation, the input bar), Always listen, the record's `mic-0` |
| 2. Speech detection | `SpeechGate` on Silero VAD | `speech started` (its time), `speech ended` (its start and end) | Always listen |
| 3. The transcription stream | The one `Transcriber`: OpenAI or the local model, as the rule picks, for each stretch of speech | `partial` (ephemeral: the stretch's words so far, as heard and with the word list's corrections); `segment` (final: the text, the heard words, the corrections, the start and end, the model, the stretch and what heard it) | The pill and the input bar (the partials of their own stretch); `Listening` (the segments: the transcript in memory and the record's `transcript` track) |
| 4. The features | Dictation, the input bar, the capture, the history and "Paste the last transcript", Always listen, the record's `transcript` track | | The person |

- **The stream** (`Sources/SpeechText/MicStream.swift`) runs while anyone reads it, and only then.
  The first reader starts the device, the last one stops it. A change of device (headphones in,
  another microphone chosen) is handled once, by the device. The 16 kHz samples are made once for
  all readers, through one converter for each run of the device. A reader is called on the
  device's thread and does its work elsewhere. The record's `mic-0` reads the device's own buffers
  (48 kHz, as before) through `MicrophoneFeed`, so the record opens no microphone of its own. The
  capture still hears through ScreenCaptureKit, which also puts the voice into its movie.
- **Speech detection** runs only for Always listen: with a key, the key says where speech is. A
  silent room costs one loudness for each buffer, on the device's thread: a buffer under −46 dBFS
  is not resampled and wakes nothing. A louder one wakes the gate for 1.5 s, with the 0.6 s before
  it. Then each 256 ms piece gets the speech probability of Silero VAD (FluidAudio 0.18.4's
  `VadManager`; its model, 1 MB, downloads into `~/Library/Application Support/FluidAudio` at its
  first use). While Silero loads, and when it fails, the probability is the energy gate's
  (`SpeechGate.energy`: −50 to −30 dBFS, hiss at half). The gate (`SpeechGate`, in
  `VoiceMeetCore`) starts a stretch at a piece of 0.5 or more, 0.2 s before it, and ends it after
  0.8 s under 0.35, 0.2 s after the last piece of speech. A stretch of 30 s ends there and the
  next one starts.
- **The transcription stream.** One transcriber (`Sources/SpeechText/Transcriber.swift`) turns
  a stretch of the microphone stream, a growing stretch with its partials, or a capture's buffers
  with their times, into segments with words and times. ONE rule picks its provider for every
  use (`SpeechRoute`, in `VoiceMeetCore`):

  | The rule's inputs | Who hears |
  | --- | --- |
  | "On this Mac" chosen in Settings › Dictation | The local model, always |
  | No network (`NWPathMonitor`) | The local model |
  | A lent mind that did not say no to OpenAI, or this Mac's own key | OpenAI (GPT Live Transcribe), through the mind's socket (`RelaySocket`), else the key |
  | Neither: no mind, or it said no (`refused`), and no key | The local model |

  A stretch whose OpenAI fails (no session in 5 s, an error while you talk, no final in 5 s) goes
  to the local model whole, as dictation's fallback always did; a capture's goes from the end of
  the last segment OpenAI answered. A key's listening is one stretch (`dictation-<n>`,
  `input-<n>`), and each final segment gets its wall times from the stretch's first sample.
  Always listen's stretches (`listen-<n>`) go to the transcriber once, when the stretch ends. While
  a key listens, Always listen holds: the stretch that goes on ends at that moment, so a stretch is
  never put into words twice. Each segment names the model that heard it. The log says the rule's
  answer at each change ("speech: OpenAI hears every use (oruk-fourier-2b behind it): OpenAI can
  be reached"), and each listening's provider and why.
- **The local model loads only when it must hear** (`LocalSpeech`, and `LocalModelLife` in
  `VoiceMeetCore`). It loads at once when the rule picks it (so an offline dictation finds it
  ready), and for a stretch whose OpenAI failed. It is unloaded once the rule picks OpenAI again
  and nothing used it for 5 minutes; a stretch that it hears keeps it. On a normal day online it is
  never loaded. Each load and unload is a line of the speech log, with its reason and its seconds
  (`oruk-fourier-2b loads: the network is down`, `oruk-fourier-2b is loaded in 0.9 s: …`,
  `oruk-fourier-2b is unloaded after 412.3 s: OpenAI hears again and the local model was unused
  for 300 s`). A load of Oruk Fourier took 0.92 to 1.38 s (above). `ui.state`'s `speech` has
  `network` and `route` (`provider`, `why`, `local`).
- **The segments are recorded** as a record track of their own, `transcript`: one JSON line for
  each segment, in a file for each slot, `/devices/<name>/record/transcript/<YYYY-MM-DD>/<HH>/<MM>-<SS>.jsonl`
  (`application/x-ndjson`). A line is `{ t, to, text, heard, corrections: [{ heard, term }], model,
  by, stretch }`, its times in Unix milliseconds; `by` is `dictation`, `input` or `listen`. A line
  goes into the slot in which it came (its own times can be in the slot before), and a slot with
  no line has no file. The slot's event has `transcript: { kind: "transcript", codec: "jsonl",
  file, bytes, segments }`. The track records while the Mac is lent and **Microphone** or Always
  listen is on; with neither, no text goes into the record.
- **The features read the stream.** The pill and the input bar show their stretch's partials. A
  dictation writes the words of its stretch between its key's down and up, taken from the stream;
  the sound is kept from fn down, as before. Each finished stretch of Always listen goes into the
  history ("Dictation"), and **"Paste the last transcript"** (⌥⇧W; `listen.write` on the control
  socket) writes its newest entry where the cursor is: with Always listen, also what you said with
  no key held.
- **Always listen** (Settings › Dictation; `listen.always` in the defaults) is OFF unless you turn
  it on. On, the microphone stays open with no key, each stretch of speech is put into words by
  the transcriber, and the segments go into the record. Online that is OpenAI: about $0.017 a
  minute of SPEECH. Speech detection gates it, so only the stretches go and silence costs nothing;
  each stretch opens a socket of its own (the standby stays for the next key). Offline, or with "On
  this Mac", the local model hears it and no sound leaves the Mac. The mark (or the mind's face) in the menu bar has a
  small orange dot at its upper left while it listens; the rest of it does not change. Off, nothing listens
  without a key, and everything works as before, through the same layers.

`ui.state`'s `listening` has the counts: whether Always listen runs, the stretches it found, the
stream's readers and starts, and the last stretch (its id, seconds and text, for a test copy).

Not built yet: the capture on the stream (its movie needs the voice), the other microphones in the
record (`mic-0` is the default input now; a Bluetooth input is not opened for it, as before), the
sound of an Always-listen stretch that began before fn down given to that dictation, and Always
listen's partials.

## Online and local: what the bench measured, and what is not built

The owner's own voice (`--set owner`, 25 November 2026) confirmed the synthetic set, and
GPT Live Transcribe is now the default with a key ("Dictation" above), with the mind's key on a
socket opened through the mind (or this Mac's own key) and a local model only when OpenAI cannot
be reached or fails, for every use ("Listening"). What follows is the
measure and the proposal before it; the parts not built are local always (both models on every
dictation) and the wait of X for OpenAI's final. The key in the mind is built, in another shape
than proposed below: no client secret, the socket itself opens through the mind, and the app sends
its own `session.update`.

What the speech bench measured on 24 November 2026 (`harness/speech-bench`, the synthetic set: 48
clips of `say -o`, two voices; an M4 Max on a home connection).

| Engine | WER % (Daniel / Anna) | Terms right, false | End of audio → final, p50 / p90 | First partial | $ / min |
| --- | ---: | ---: | ---: | ---: | ---: |
| `parakeet-v3`, the app's model | 21.8 (3.4 / 40.2) | 124/146, 30 | 0.43 / 0.66 s | 0.47 s | 0 |
| `gpt-live-transcribe`, delay low | 10.3 (3.1 / 17.4) | 130/146, 8 | 0.71 / 0.79 s | 0.92 s | 0.017 |
| `gpt-transcribe` | 11.0 (3.1 / 19.0) | 121/146, 3 | 0.80 / 1.09 s | none | 0.0045 |
| `oruk-fourier-2b` (local, CC BY-NC) | 12.1 (4.8 / 19.3) | 99/146, 3 | 0.26 / 0.32 s | none | 0 |

On a clear voice (Daniel) Parakeet is as good as OpenAI; on the accented voice it makes twice the
errors, and its word-list boosting writes terms that were not said (30 times in 48 clips, the
others 3 to 8). A new connection costs 0.6 s to connect and 0.2 s for `session.update`.

The proposal:

- **Local always.** Parakeet runs on every dictation, as now: its partials are the pill's text,
  and it is the answer when there is no network.
- **Online too, when it is set and reachable.** At fn down the app streams the same 24 kHz audio
  to `gpt-live-transcribe` (delay `low`: of the two delays it had the lower WER and the faster
  final) with the mind's `words.md` terms as `keywords`. The audio is kept from fn down, so a
  socket that opens late loses no word: only its partials come later.
- **At the end of speech, wait at most X = 900 ms for OpenAI's final; else write local's.** X is
  OpenAI's end-to-final p90 (0.79 s) plus 0.1 s for a slower network than this one: 9 dictations of
  10 get the online text, and each one waits about 0.3 s more than local alone (0.71 s against
  0.43 s at p50). With `gpt-transcribe` (a quarter of the price) X would be 1.2 s (its p90 is
  1.09 s). When the socket did not open, failed, or has not had all the audio, there is no wait.
- **The key stays in the mind.** The mind holds `/secrets/openai`. The app never gets it: it asks
  its mind (through the bridge, as `words-fetch.mjs` does) for a client secret, and the mind makes
  one with `POST /v1/realtime/client_secrets`: the transcription session (model, delay, `keywords`
  from its `words.md`, `prompt`, `languages: ["en"]`) and `expires_after` of 600 s. The app
  connects with `Authorization: Bearer ek_…`; the session is already set, so no `session.update`
  goes. The bench checked this path: the secret came in 1.09 s, the socket opened in 0.74 s, and
  the final came 0.72 s after the end. The secret is the slowest step, so the app gets the next one
  before the current one expires, not at fn down. The mind also decides who may dictate online.
- **What changes for the person.** "No sound and no text leaves the Mac" is then not true for a
  mind with online speech: it must be a choice of the mind, said in Settings › Dictation.
  At the measured prices, an hour of dictation costs $1.02 (`gpt-live-transcribe`) or $0.27
  (`gpt-transcribe`).

## How it works

- **The app** (`Sources/`) holds macOS's permissions: Screen Recording, Accessibility, Camera and
  Microphone, each asked for by a guide in the panel when you first set a thing to Ask or Shared.
  It answers on a Unix socket in `~/Library/Application Support/voice-meet-mac/`, a folder only you
  can read.
- **The bridge** (`bridge/mac-endpoint.ts`) is the file that `iterate provide` lends to the mind,
  with the Mac's key. It turns each call into one request on that socket.
- **The mind's process** (`bridge/mind.mjs`) is everything else the app says to a mind, as you.
  See below.
- **The installer** (`cli.mjs`) builds and updates, and makes and updates a copy. Its state is in
  `~/Library/Application Support/iterate-mac-app/`; the app's log is in
  `~/Library/Logs/voice-meet-mac/app.log`.
- **The signature is local.** The build signs the app with a self-signed certificate that it makes
  once, in a keychain of its own, so that macOS keeps the permissions through each update. No Apple
  account is involved.
- A command that the mind runs is a child of the app, so it has the app's permissions. Set
  Commands to Shared only for a mind you trust with all of it.

### The mind's process: one connection, as you

Two identities reach a mind from this Mac. The lend, `iterate provide` with the Mac's key, is the
mind's way in: one process. Everything the app says to the mind goes as you, with the iterate CLI's
own sign-in, through ONE Node process for that mind, `node bridge/mind.mjs <mind> --name <name>
--iterate <iterate.js>`, with ONE connection to it (`bridge/mind-connection.mjs`). When the
connection ends, it connects again: 1 s, then twice as long, at most 60 s; a session whose sign-in
ended after its 4 hours (the mind closes the socket with 1008) comes back with a renewed one. Every
job is on it:

| Job       | What it does                                                                 | Swift              | Script          |
| --------- | ---------------------------------------------------------------------------- | ------------------ | --------------- |
| `events`  | the events of `/devices/<name>`, the acts and presence read back, and every event while the Activity window is open | `DeviceEvents` | `events.mjs` |
| `live`    | the signalling of live                                                       | `DeviceLive`       | `live.mjs`      |
| `call`    | a publication into a call: its row, the call facet's join, signal and leave  | `DeviceCall`       | `call.mjs`      |
| `record`  | the record's spool into the mind                                             | `DeviceRecord`     | `record.mjs`    |
| `capture` | one capture into the mind, by its id                                         | `Capture`          | `capture.mjs`   |
| `input`   | one input into the mind, by its id                                           | `MindInput`        | `input.mjs`     |
| `words`   | the mind's `words.md` into the app's copy                                    | `Words`            | `words.mjs`     |
| `openai`  | OpenAI's realtime sockets through the mind, with its key, relayed by id      | `MindSockets`      | `openai.mjs`    |

stdin and stdout are JSON lines, each tagged with its job (`{ job, … }`); a line with no job is the
process's own (`{ connected }`, `{ failed }`). `events`, `live` and `record` run from `{ job, start:
true }` to `{ job, stop: true }`. A record slot, a capture and an input upload their files in one
way (`bridge/upload.mjs`): a signed PUT that streams the file from disk and whose answer must name
the file's size; when the signed route answers 5xx, a file of at most 8 MB goes through the
connection instead.

In the app, `MindBridge` owns the process: one for a mind, its name and its helpers, which runs
while someone holds it. The session holds its mind's process while the Mac is lent to it; a capture
holds its own mind's until it is sent, an input until it went, a word list until it came. So a
running copy has one such process for the mind it is lent to, and a second one only while a job of
another mind runs (a capture that began before a switch, an input to another mind, that mind's
word list). When no one holds it, its stdin closes: the events that wait go, the last byes of live
and the record's slot, and it exits. A process that ends while it is held starts again after 10 s,
and its jobs start again. `JSONLineProcess` (in `VoiceMeetCore`) runs it: it cuts stdout into lines
by bytes before it decodes them, writes stderr into the app's log, and says the end only after the
last line.

Notes from the first runs (macOS 15.7.4, a MacBook Pro):

- The first start of an audio engine with Apple's voice processing changes the audio
  configuration itself (the microphone's format grows from 3 to 9 channels), so the engine starts
  twice; the app starts the same engine again and waits for it to settle.
- Apple's voice processing removed speech that another program played through the speakers from
  the microphone about as well as speech that its own engine played (about 21 dB in a short test).

## Developing

This repository is the app's home: `git clone https://github.com/iterate/mac-app`, then build and
install from the checkout with `node cli.mjs update` (or `./run-on-mac.sh`). A pull request is
checked by `.github/workflows/ci.yml` on a macOS runner: `swift build`, `swift test`, every
script of the bridge parses, the bridges' tests pass (`node --test 'bridge/*.test.mjs'`), every
view draws as its baseline (`node harness/snapshots.mjs`), and the app runs its scenarios
(`node harness/run.mjs ci`; see "Testing with no hand"). Every push to `main` publishes a version to npm
(`.github/workflows/release.yml`), and a Mac that installed from npm updates itself within the hour.

```sh
./run-on-mac.sh               # build, install in /Applications, open, follow the logs
./run-on-mac.sh --build-only  # build and sign .build/iterate.app only
./run-on-mac.sh --logs        # follow the app's log
swift test                    # the state machines' tests (needs Xcode): microphone, camera, lend, banner, the record (with its camera change rule, sound gate and silent slots), the mark, record.set's rule, live, the input's draft
node --test 'bridge/*.test.mjs'  # the mind's process and its jobs: a fake mind that ends sessions (1008) and subscriptions
npx .                         # the installer from this folder
npx . init /tmp/mac --no-install   # a copy, without building or installing it
```

`swift build --product record-run`, then `.build/debug/record-run --spool /tmp/spool --device test.mac
--synthetic --seconds 70` records a test picture and a beep each second into a spool, with no
permission; `--screens --cameras --mics --speakers` record the real sources, which need the app's
permissions (run it through the app's `run` method). `{ echo '{"job":"record","start":true,"spool":"/tmp/spool"}'; cat; }
| node bridge/mind.mjs <address> --name test.mac --iterate <iterate.js>` sends a spool to a mind,
until Ctrl-D ends its stdin.

`swift build --product live-run` drives live from a terminal with the same libraries and bridge:
`.build/debug/live-run --device test.mac --node $(which node) --bridge bridge/mind.mjs --iterate <iterate.js>
--mind <address> --synthetic --seconds 90` answers every watcher of `/devices/test.mac` with the
test picture and beep (no switch is asked); `--record <spool>` records them too; `--screens
--cameras --mics` are the real sources (through the app's `run` method), and `--loopback-only
--no-stun` keeps the media on this Mac for a watcher here. stderr has a line of statistics a second.

`swift build --product call-run` measures a call from a terminal: `.build/debug/call-run --context
/agents/meet/<call> --node $(which node) --bridge bridge/mind.mjs --iterate <iterate.js> --mind
<address> --device test.mac --seconds 15` joins a receiving page, publishes the synthetic picture
(it carries the wall time in a strip) as a screen, subscribes to it, and writes a JSON line for
each step and each second: frames, the picture's delay, the first frame after the choice, and the milliseconds of
each call to the facet. "The picker opens" 1.5 s before the choice (`--choose-after`), and the
sender prepares then; `--no-prepare` makes the steps one after the other, `--warm` lets the
receiver first receive a camera of the Mac, `--still` sends a screen that does not change, and
`--answer-at-once` lets the receiver answer without its candidates. No switch, camera, microphone
or screen is used.

`.build/release/VoiceMeetMac --render-panel panel.png` draws the panel to a file without opening
anything, with fixed minds, things and clock (see "Testing with no hand"). A third word draws the lend in one phase: `live`, `reconnecting`, `stopped` or
`not-allowed`, `incompatible`; `ringing` draws a call's banner at the top; `busy` (watched,
recording, an act that runs), `blocked` (Screen Recording and Accessibility not given), `activity`
(the Activity page) and `no-mind` draw the panel's own states. `--render-banner banner.png ring`
draws a banner (`ring`, `request` or `notice`; add `dark` for the dark appearance);
`--render-ring ring.png` is the ring's. `--render-switcher <folder>` draws the mind switcher,
closed and open, light and dark, four files. `--render-input <folder>` draws the input bar (empty,
listening, with a text and files, while it sends, not sent, not sent with its fix) and the
dictation pill (loading, listening, locked, failed), light and dark, twenty files. `--render-settings <folder>` draws the Settings window's pages, light and dark, eight files. `--render-approval <folder>` draws the
Ask question, `--render-log <folder>` the Activity window, and `--render-capture <folder>` the capture's pill while it
records, light and dark, two files each. Settings and the Activity window draw in a window with its title bar, so their
window buttons show (grey: the drawing is never the active app). `--render-all <folder>` draws every view, light and dark.

**The speech bench** (local only, never in CI) compares speech-to-text engines on sentences with
known text: `harness/speech-bench/sentences.md`, 24 sentences as the owner dictates to a coding
agent: 16 dense with the terms of iterate.com's `words.md` (each term is in one at least), 4 plain,
2 with numbers and paths, 2 long ones with self-corrections. It has two sets of clips:

- `owner`: the owner's own voice. `node harness/speech-bench/record.mjs` shows one sentence at a
  time and records the Mac's default microphone while you talk (Enter starts, Enter stops; `r` says
  it again), into `~/.cache/iterate-speech-bench/clips/NN.wav` with the sentence as `NN.txt`.
- `synthetic`: each sentence from `say -o` in two voices, Daniel and Anna (a German voice that reads
  English). It is made at the first run, so that every engine can be measured before the owner
  recorded.

`swift build -c release --product speech-bench`, then `node harness/speech-bench/run.mjs --set
owner` (or `--set synthetic`; `--engines a,b`, `--clips 01,02`, `--text` for each clip's text).
Each engine is a file in `harness/speech-bench/engines/` with its setup at its top, behind one
interface: the clips (16 kHz WAV) and the word list in; per clip its partials with their times, its
final text, the time to the first partial, the time from the end of the audio to the final text
("how long after I let go"), and the setup: the first ever (install, download, the first load), each
start of the app, each dictation. A streaming engine hears the clip at the pace of the clock in
pieces of 0.1 s; a model that hears whole utterances gets the clip at its end.

| Engine | Runtime | Word list |
| --- | --- | --- |
| `parakeet-v3`, `parakeet-ultra` | The app's recognizer (`speech-bench`, Core ML) | CTC boosting and repair, as the app |
| `fourier-app` | The app's recognizer (`speech-bench`): Oruk Fourier in the app's own Python process, a partial pass at most once a second | The terms in its prompt, and repair, as the app |
| `fluid-speech-pro` | Core ML, the FluidVoice fork of FluidAudio, patched for Xcode 16 | The fork's CTC boosting |
| `phonon-2.5-english` | Core ML on the Neural Engine, the package's C library | 25 hotwords (its most) |
| `oruk-fourier-2b`, `oruk-fourier-2b-bf16` | MLX 8-bit or BF16 (converted by `engines/oruk-bf16.py`), Python mlx-audio in the bench's venv (CC BY-NC 4.0) | The terms in its prompt |
| `granite-speech-5.0-470m-turboctc` | MLX, Python mlx-audio (Granite-MLX needs macOS 26) | None (CTC) |
| `gpt-live-transcribe-low`, `-medium` | OpenAI, a WebSocket; deltas while you talk | `keywords`, `prompt` |
| `gpt-transcribe` | OpenAI, a WebSocket; the committed turn | `keywords`, `prompt` |

`score.mjs` scores a run: the word error rate after the app's word-list repair (every engine's text
goes through it), the terms written exactly (and before the repair), the literals (`AGENTS.md`,
`/devices/jonas.mac`, `15`: the word error rate drops punctuation), the two latencies at p50 and
p90, the setup and the cost per minute. The table goes to stdout, the JSON to
`~/.cache/iterate-speech-bench/results/<date>.json`. Everything that is not code (clips, venvs,
models, results) is in `~/.cache/iterate-speech-bench`, never in the repository. The OpenAI engines
send the bench's clips, and only those, to OpenAI; `run.mjs` reads `OPENAI_API_KEY` from Doppler
(`_shared/dev`) into its environment and never prints or writes it.
`.build/release/speech-bench --model <id> [--words words.md] <file>…` prints one model's segments
and partials for any sound file.

### Testing with no hand

An agent builds, runs, drives and checks the app with no person at the Mac, beside an installed
copy, which it does not touch.

**A home of its own.** `--home <folder>` (or the environment's `ITERATE_MAC_HOME`) puts everything
the app keeps in that folder: config.json, the endpoint's socket, the log (`logs/app.log`), the
captures, inputs, word lists and faces, and the choices (`defaults.plist`). Such a copy registers no
global key, touches no login item, never updates itself, and lends only with `--lend`. It opens no
microphone, and dictation writes its text nowhere (no clipboard, no ⌘V), unless an audio fixture is
set. Its panel closes by its mark alone. Its mark is grey with an orange "test" beside it, and its
label says `iterate test copy: <home>`, so it is never taken for the installed app.
`Sources/VoiceMeetMac/AppEnvironment.swift` resolves all of it at launch.

**Off the screen.** A test copy shows nothing to the person at the Mac
(`Sources/VoiceMeetMac/OffScreen.swift`). Each window, panel, pill and banner it orders in is
transparent (alpha 0) and lets every click through, at its usual frame, with its views laid out and
drawn; none becomes key, so the app in front keeps the keyboard, and the copy never activates
itself. It has no status item: its mark is the same button in a transparent window of its own.
The control socket reads, presses and types into those windows as before, and `ui.key` gives its
keys to the front window when none is key. The capture's ink is transparent too, so a test copy's
capture has none. `--on-screen` shows a test copy as the installed app shows itself, for a person
who wants to watch it. The drawings (`--render-*`, `snapshots.mjs`, `design-diff.mjs`) order no
window in: each view is laid out in a window that is never on the screen and drawn with
`cacheDisplay`. `node harness/run.mjs` checks it: while a scenario runs, it reads the window
server's list every 200 ms (`harness/on-screen.js`, `CGWindowListCopyWindowInfo` through `osascript
-l JavaScript`) and fails the scenario when a window of a copy is on the screen with an alpha above
0 and a frame that meets a display, when a copy is the active app, or when `ui.state` has a window
of it that is key. `node harness/run.mjs boot --on-screen` shows that the check fails without it.

**The control socket**, `<home>/control.sock`, is open in a copy with a home of its own, and only
there: the installed app has none, and always asks with its alert and Touch ID. One line of JSON a
connection, as the endpoint's; a mind never reaches it.

| Method | What it does |
| --- | --- |
| `ui.state` | `perf` (`Perf`: CPU seconds, `rss` as the physical footprint, wake-ups, open files, threads, `mainStallMaxMs` while its watch runs, and `counters`: `stateChanges`, `statusWrites`, `panelBodies`, `lendTicks`, `presenceLooks`, `recordLooks`, `windowChanges`, `grantProbes`, `cameraSearches`), the lend, the minds, the mind session (generation, mind, name), the windows on the screen, the panel, the input bar, the dictation (with its last text), the listening layers (`listening`), the history (`history`: whether it is kept and read, its entries, the newest one's text, kind, outcome and app), the capture, the activity (its context, and each row's act id and whether it is in the mind), the Activity window's log (`log`: how many events it holds and shows, their types, whether older ones are left, its `mode`, and in the Dictations mode the texts it lists, `dictations`), the banner, the record, the choices, the question that waits |
| `ui.tree` | The accessibility tree of the app's own windows: role, `id`, label, value, frame |
| `ui.press {id, label?}` | Presses the control with that accessibility identifier; `label` picks a segment (`{"id":"sharing.commands","label":"Ask"}`) or a pop-up button's item (`{"id":"settings.approvalMinutes","label":"1 hour"}`) |
| `ui.type {id, text, replace?}` | Types into it (`input.text`), at its end or in place of its text |
| `ui.scroll {id}` | Scrolls a list to its end (`log.list`), as a person does to read older rows |
| `ui.key {key, shift?, command?}` | A key as the keyboard sends it (`tab`, `return`, `escape`, or `a`, `c`, `v`, `w`, `x`, `z` with `command`) to the key window, else the frontmost that can be key: its shortcuts, then the main menu's, then its `keyDown` |
| `perf.input {kind, count, every?}` | `count` keys (`key`), moves (`move`) or scrolls (`scroll`) of another app, one every `every` ms (100), into the path of **Keyboard and mouse** as its monitor gives them: what that path costs, with no key of the person and no move of the pointer. The counters `inputSeen`, `published`, `focusAsks` (a key that asked the app in front for its focus), `focusMoves` and `eventsSectionBodies` (the panel's "Events to the mind" drawn) count it |
| `perf.reset {watchMain?}` | The counters of `ui.state`'s `perf` start again from zero; `watchMain: true` starts the watch of the main queue's longest delay (it wakes the app 20 times a second, so it is off until asked), `false` stops it |
| `input.toggle`, `capture.toggle`, `capture.mark {points}` | ⌥⇧Space, ⌥⇧S, and ink (points of the display from its top left) |
| `dictation.start`, `dictation.stop` | A hold of fn: fn down, and fn up at least 0.35 s after it |
| `dictation.fn {down}`, `dictation.esc` | fn down (`true`) or up (`false`), and Esc: a hold, a tap, or two taps that keep it on |
| `listen.write` | ⌥⇧W, "Paste the last transcript": the newest entry of the history is written ("Dictation") |
| `approval.answer {allow, keep?}` | Answers the Ask question that waits; `keep` approves for `approval.minutes` (30 unless set). While the socket is open, the question's panel shows and its buttons answer too (`ui.press` on `approval.once`, `approval.minutes`, `approval.deny`), and no Touch ID is asked |

The identifiers: `statusItem`, `panel.reconnect`, `panel.openInput`, `panel.copyPrompt`, `panel.quit`,
`sharing.<thing>`, `device.input`, `device.keep`, `record.<source>`, `record.windowText`,
`activity.all`, `activity.back`, `activity.context`, `activity.showsPill`, `activity.window`, `approval.once`,
`approval.minutes`, `approval.deny`, a banner's buttons `banner.button.<n>`, in the Activity window `log.mode` (a segment by its label: `Acts`, `Every event`, `Dictations`),
`log.filter.<acts|presence|app|window|record|live|inputs|keys>`, `log.search`, `log.list`, `log.row`, `log.context`,
`log.sharing`, `log.endApproval`, `log.copy`, `log.showsPill`, `log.close`, `dictations.list`, `dictations.row`,
`dictations.copy`, `dictations.paste` (a row's), `dictations.chosen.copy`, `dictations.chosen.paste`, `input.text`, `input.send`, `input.mind`, `input.microphone`, `input.copyFix`, `capture.send`,
`capture.discard`, `speech.model.<id>` (a model in the list of Settings › Dictation), `panel.settings`, and in Settings `settings.page.general`,
`settings.page.dictation`, `settings.page.mind.<address>`, `settings.addMind`, `settings.login`,
`settings.showsPill`, `settings.approvalMinutes`, `settings.key.capture`, `settings.key.input`,
`settings.doubleTap`, `settings.dictationKey`, `settings.alwaysListen`, `settings.key.writeSaid`, `settings.pillWords`, `settings.keepHistory`, `settings.clearHistory`,
`settings.clearHistory.confirm`, `settings.clearHistory.cancel`, `settings.write`, `settings.speechWhere`,
`settings.openAIKey` (and `.set`, `.remove`),
`settings.wordsExpression`, `settings.mind.name`, `settings.mind.wordsSource`,
`settings.mind.expression` (and `.save`), `settings.mind.fetch`, `settings.mind.use`, `settings.mind.remove`. The tree is read in the app's own process and needs no permission of macOS; to
have SwiftUI's elements in it, the socket sets the app's "enhanced user interface" attribute, as an
assistive app does.

```sh
.build/debug/VoiceMeetMac --home /tmp/mac-test &
printf '{"method":"ui.press","id":"statusItem"}\n' | nc -U /tmp/mac-test/control.sock
printf '{"method":"ui.tree"}\n' | nc -U /tmp/mac-test/control.sock
```

**The audio fixture.** With `ITERATE_MAC_AUDIO_FIXTURE=<file.wav|.aiff|.m4a>`, the microphone
stream (dictation, the input bar, Always listen) hears that file in place of the microphone, at
the pace of the clock, from each start of the stream, then silence; no audio device opens, and the copy loads the speech model in the background as the
installed app does. A Swift test passes the file to `FixturePlayer`, or its own source and engine
to `SpeechSession`.

**The frame fixture.** With `ITERATE_MAC_FRAME_FIXTURE=<image file|synthetic>`, the live view of
this Mac's pages shows that image (or a gradient of 2560 × 1600 pixels), with a bar that moves at
each frame, in place of the display: no screen capture and no Screen Recording. The display's
choice still decides.

**The drawings** (`--render-*`) take nothing from this Mac: fixed minds and faces, a fixed clock
(UTC), the things of a Mac with one display and one camera, the scroll bars, accent and locale held
in the process, 2 pixels to a point. `node harness/snapshots.mjs` draws every view and compares it
with `harness/baselines/`; `--update` writes new baselines after a change you meant. Fonts and
controls can draw a pixel otherwise on another macOS build, so the check is strict (equal sizes, at
most 0.5% of the pixels more than 24 off in a channel) only on the build in
`harness/baselines/made-on.json`. On another build, as on CI's runner, it checks the layout: sizes
within 2%, at most 1% of the 16 × 16 blocks more than 24 off in their mean. A missing or moved row
fails it, antialiasing does not; the pixel differences are reported, and a picture of each is in
`<out>/diff/` (CI uploads it as the artifact `snapshots`).

**The design.** The views take their colours, sizes and radii from `Theme.swift`, made from
`design/tokens.json`. `node harness/design-diff.mjs [--only v2-Live,v2-Pills] [--tone dark]`
measures each drawing against its mock in `design/html`: headless Chrome (its own profile in
`/tmp`, the mocks' web fonts blocked, so both draw in SF) draws the mock at 2 pixels to a point,
the script cuts out each panel and pill, puts the app's drawing beside it, and prints the mean
difference of a channel (`mad`, 0 is the same picture), the same with each band of 16 points where
it fits best (`banded`: a row the mock lacks moves what is under it), and the difference of size.
The pictures (`<view>-side.png`, `<view>-diff.png`) and `scores.json` go to
`~/.cache/mac-app-night/fidelity`. It needs Google Chrome in /Applications and nothing from npm.

**The scenarios.** `node harness/run.mjs <scenario|ci|all>` runs the app that `swift build` made
(`--app <path>` for another) in a new home, drives it, and prints one JSON line a scenario:
`boot` (the panel opens, the tree has its controls, a segment is pressed), `panel-pages` (**All**
shows the Activity page, and its back button the main page), `input-send` (a text
typed into the bar reaches the bridges' fake mind as `device/input-submitted`), `settings` (the panel's
Settings button opens the window with This Mac's pages and the mind's; "1 hour" for an approval is
`approval.minutes` 60 in the home's defaults; Open at login and a mind's own word-list expression
go into config.json through `cli.mjs set`, which keeps the keys it does not know; that expression
runs at once in the fake mind, and its answer is the app's copy of the list), `activity` (a
command run through the endpoint is `device/act-started` and `device/act-ended` in the fake mind,
and `ui.state` shows its row once, echoed from the context), `record-upload` (a slot that waits in
the home's spool goes to the fake mind, its file before `record/slot-stored`, and leaves the
spool), `pages-live` (Pages at Off refuses `/state.json`; at Shared, with the frame fixture,
`/live.mjpeg` gives 3 JPEGs between multipart boundaries, and the cancel ends the view and its
act), `approval` (a
command on Ask is approved and denied through the socket, then through the question's buttons, and
"Approve for 30 Minutes" lets the next use run with no question), `log-window` (on a context that
holds mixed events, "Open in a Window" reads the newest page of every kept type and no ephemeral
key, scrolls to the end read the pages below to the start, a new act comes in as it happens, and
the close lets go of the events), `mind-switch` (two fake minds: an
approval for 30 minutes given while lent to A does not hold after config.json switches to B, and no
device event reaches A after the switch), `banner` (a banner shown 50 ms after the last one's
button stays on the screen), `keys` (Tab and ⇧Tab in the input bar choose the next and the last
mind, Esc closes it, ⌘W closes the Add a Mind form through the main menu), `log-bound` (a log of
25 MB is set aside at the start), and two measurements: `idle` (lent to the fake mind with
`--lend`, every switch off, the panel closed: 20 s live, then 10 s refused with its next try in
5 minutes; limits on CPU, wake-ups and counters, and the figures in the result's `perf`) and
`panel-open` (5 s with the panel open and a countdown: the panel's body is drawn at most once,
its countdown row each second). The fake iterate CLI answers `provide` with the state in
`fake-iterate/provide.json`, live by default. The approval scenario presses Return and Esc through `ui.key`,
which gives them to the question's panel (never key in a test copy); when its shortcuts do not take
them, its result says `skipped`. Then the local ones, which need the speech models in
`~/Library/Application Support/FluidAudio`: `dictation-fixture` (a sentence from `say -o` is
written with the word list's Herdr, Beelink and Doppler; its `perf` has the seconds from the start to the first word and the model's load. Core ML
compiles the model for the Neural Engine once for each build of the executable, in
`~/Library/Caches/<bundle id or process name>/com.apple.e5rt.e5bundlecache`: the first run after a
build waits 12 to 24 s, every later process of that build about 0.2 s), `dictation-fn` (one tap of fn
listens until its window ends and leaves no line; a hold writes the sentence; a double tap locks
it until the next press of fn, which writes it; a lock that Esc ends writes nothing), `capture-transcript-fixture` (the
sentence after 2 s of silence, pushed as a capture's buffers with their times, gives segments with
the terms that start after the silence), `listen-always` (Always listen on, the fixture and no
key: the sentence is one stretch with the terms, `listen.write` writes it, the fake mind gets it
as one line of a slot's `transcript` track, and the mark's label says that the microphone is open;
then 20 s of the fixture's silence, its figures in the result), `speech-model` (the default is Oruk Fourier when its
files are on this Mac, else Parakeet v3; Ultra chosen through `ui.press` is the stored choice) and
`dictation-fourier` (Oruk Fourier chosen hears the fixture: the pill has words before the end,
and the text has Herdr, Beelink and Doppler; with no Fourier files, in
`~/Library/Application Support/iterate-speech/oruk-fourier-2b` or `ITERATE_MAC_FOURIER_FOLDER`,
its result says `skipped`). CI runs `ci`, every scenario but the local ones. `--keep` keeps the homes and their logs.

## Licence

The app is under the Apache License 2.0 ([LICENSE](LICENSE)): use it, change it and ship it, for
any purpose, commercial too. It includes work derived from [Hex](https://github.com/kitlangton/Hex)
and [Scrawl](https://github.com/kitlangton/scrawl) by Kit Langton, both MIT; [NOTICE](NOTICE)
keeps their copyright and permission notices, which every copy must carry. The speech models are
not in this repository: each Mac downloads its own, under the model's own licence. Oruk Fourier
2B is CC BY-NC 4.0, non-commercial.
