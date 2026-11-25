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
while it is paused, none while it is off. `--render-icons <folder>` draws each mark on a light and
a dark bar, and `marks-light.png` and `marks-dark.png`: each colour of the mark with each dot.

Needs macOS 14 or later and Node 22.18 or later.

### Settings

**Settings…** in the panel's footer (or ⌘, while the panel shows) opens one window, 800 points
wide. Its sidebar has two groups. **This Mac** is what holds whichever mind the Mac is lent to:

- **General**: open at login (config.json's `login`), show each act on the screen (the same tick
  as on the Activity page), how long an approval lasts (5, 15, 30, 60 or 120 minutes; the Ask
  question's second button says it: "Approve for 30 Minutes"), the keys of capture and the input
  (a click records a new one, with ⌘, ⌥ or ⌃; × removes it; a key that macOS refuses says so and
  the one before stays), the version with **Update Now** and **Update by itself** (from npm only:
  a trial and a copy are updated by hand), and **Copy Prompt**.
- **Dictation**: fn to hold and talk (× removes it: ⌥⇧D stays), double-tap to keep it on, the
  orange row when macOS acts on 🌐 too, the speech model and its list, whether the pill shows the
  words, where the text goes (where the cursor is, or on the clipboard only), and the default
  expression of the word list (below).

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
of this Mac are in the app's defaults: `approval.minutes`, `key.capture`, `key.input`,
`dictation.key`, `dictation.doubleTap`, `dictation.pill`, `dictation.write`, `update.byItself`.
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
`InputDraft.swift` and `bridge/input.mjs`, `Presence.swift`, and their tests (and their jobs in
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
await mac.record.state(); // { sources: { screens, cameras, mics, speakers }, windowText, recording, paused, line, tracks, … }
await mac.record.set({ screens: true, mics: false }); // the new state; "on" is a use, as a snapshot is
await mac.http({ path: "/state.json" }); // { status, headers, body }: this Mac's own pages (below)
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
`--render-log <folder>` draws the window with sample events.

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
| `device/input-submitted`  | You sent an input with ⌥⇧Space (below, "Input"). It goes to the mind you chose, which need not be the one this Mac is lent to                                             | `id`, `text`, `at`, `files`                                   |

A key event holds the key itself, so what you type goes to the mind, a password too. Keyboard and
mouse is off until you turn it on. Its events are ephemeral: they reach whoever listens at that
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
the clock, that plays by itself, and a video track has a small picture of the slot's start:

```
/devices/<name>/record/<track>/<YYYY-MM-DD>/<HH>/<MM>-<SS>.mp4   HEVC or AAC, fragmented MP4, time zero at the slot's start
/devices/<name>/record/<track>/<YYYY-MM-DD>/<HH>/<MM>-<SS>.jpg   640 px wide
```

Screens are 10 frames a second at the display's own pixels (only frames that changed), cameras
720p at 15, both HEVC at quality 0.45 with a keyframe at the slot's start and every 10 s. Sound is
AAC at 48 kHz, on the same clock as the picture. Windows of password managers are left out of
the screens.

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

The text is a line for each **numbered picture** with the words you said at it, and the two ways
to the pictures:

```
[capture 0:15 · Ghostty “my project” · jonas.mac → example.com]
The words point at red marks on the screen: look at the pictures before you answer. Each # is a numbered picture.
On jonas.mac: read sheet.jpg and 1.jpg, 2.jpg together, in /Users/…/iterate-mac-app/captures/<id>. Those files are the whole capture: answer from them, and open nothing else in that folder
If you cannot read that folder (you are an agent of the mind example.com, or you have its MCP tool and no file tool), run this as your first step. It answers the words and the marks, and it shows you the pictures as images: async (itx) => { … one script, about 600 characters: it waits for capture/ready, reads context.json, and shows the pictures … }
- #1 (0:06) drew “what is this here?”
- #2 (0:12) clicked “Save” “and this is slow”
```

Each mark and each click gets a numbered picture: the part of the display around it, cut out
while you talk. `sheet.jpg` is all of them on one. While you talk the pictures go up, and this Mac
puts your voice into words at each pause, with the speech model of dictation ("Dictation" below)
and the `words.md` list of the capture's mind; no sound leaves the Mac for it, and no cloud model
hears it. The pill shows the last words: the sign that the microphone hears you. So at the end
only your last words can be missing: the first text says so, and the same text with all the words
takes its place on the clipboard a moment later, unless you copied something else.

**Who reads the text, and what they get** (tested with real agents on 21 November 2026):

| The agent                                         | What it does                                | Does its model see the pictures?                                                                                                               |
| ------------------------------------------------- | ------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| On this Mac (Claude Code, Codex)                  | Reads the numbered pictures from the folder | Yes                                                                                                                                            |
| In the mind (the Dash, Slack)                     | Runs the text's script                      | Yes: the script sends them to that agent as the files of a message                                                                             |
| Elsewhere, with the mind's MCP tool and a shell   | Runs the text's script                      | Yes                                                                                                                                            |
| With the mind's MCP tool alone (no shell, no web) | Runs the text's script                      | Yes: the tool answers the pictures as images. A mind that does not have that yet answers text, with `seen`: what a model read off each picture |

Each of them answers in one turn: one reply to the one message with the text.

The script waits for the event `capture/ready`, so a text that is pasted before the capture is
whole still gives the whole capture. The folder stays on this Mac for 7 days.

A capture is a set of **observations**, each with its time in milliseconds from the start. They
are files of the mind under `/captures/<id>/`, and the capture is a context of its own at that
path, with two events: `capture/ready` (the words, the marks and the pictures are there) and
`capture/received` (the movie too):

| File                   | What it holds                                                                                                                                                                                                                                                                                                                 |
| ---------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `summary.md`           | The text on the clipboard, with all the words                                                                                                                                                                                                                                                                                 |
| `1.jpg` …, `sheet.jpg` | The numbered pictures, at most 12, and all of them on one. A capture with no mark and no click has one: the display at the end                                                                                                                                                                                                |
| `context.json`         | What the text's script answers: the words, the marks, and the pictures under `"itx/images"`                                                                                                                                                                                                                                   |
| `seen.json`            | What a model read under each mark, for a reader that gets no picture: a model's claim                                                                                                                                                                                                                                         |
| `transcript.json`      | The words with their times (`segments`: `t`, `to`, `text`, `words`), as this Mac's speech model heard them (`by`): a model's claim, not an observation                                                                                                                                                                         |
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
  say it, on this Mac ("Dictation" below), with the word list of the mind the input goes to. The
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
- **Keys.** ⇧Return and ⌥Return make a new line. Escape closes the bar and keeps what you wrote;
  ⌥⇧Space opens it again.

Return closes the bar at once. One input goes at a time: while it goes, the bar shows it and takes
no new one. The input goes up as you, as a capture does: the job `input` of that mind's process
(`bridge/input.mjs`) uses the iterate CLI's own sign-in to that mind (`iterate login <mind>`, once). When it did not go
(no sign-in, no network, a file that failed), the bar comes back with your text, your files and the
reason, and Return sends the same input again (the same id: the mind keeps it once). An input you
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

- **fn needs Accessibility.** The app hears fn with event taps of the session, which macOS
  gives only to an app with Accessibility (the permission that also writes the text for you). One
  tap hears the modifier keys; the tap for key presses is on only while fn is down or a dictation
  goes, so the rest of the Mac's typing passes no tap of this app. It swallows one key: Esc while
  a dictation stays on, so that Esc does not reach the app in front. Without the permission, ⌥⇧D still works, its first use opens the permission's guide, and
  the panel's speech row and Settings › Dictation say so. macOS can act on 🌐 too (the emoji
  picker, or its own dictation): when System Settings › Keyboard › "Press 🌐 key to" is not "Do
  Nothing", Settings › Dictation says to set it, with **Open Keyboard Settings**. The app changes
  no setting. Settings › Dictation can turn fn off (⌥⇧D stays) and the double tap off (a short
  tap then does nothing).
- **One listening at a time.** Dictation and the input bar share one microphone listening
  (`SpeechSession`). When one starts while the other listens, the other ends first: its last words
  are written where they belonged.
- **It runs on this Mac.** The speech model runs as Core ML through
  [FluidAudio](https://github.com/FluidInference/FluidAudio), the library of the Swift Hex. No
  sound and no text leaves the Mac. Settings › Dictation (the panel's speech row opens it) chooses the model for dictation,
  the input and captures; each one shows its size and whether it is on this Mac:

  | Model                       | Download | License   | Note                                                     |
  | --------------------------- | -------- | --------- | -------------------------------------------------------- |
  | Parakeet TDT 0.6B v3        | 480 MB   | CC BY 4.0 | The default: 25 European languages                       |
  | Parakeet Ultra              | 632 MB   | CC BY 4.0 | A post-training of v3, which FluidAudio 0.18.4 recommends |

  A model that is not on this Mac downloads when you choose it, with its progress in the panel,
  into `~/Library/Application Support/FluidAudio`, and is the model once it loaded. The choice is
  kept in the app's defaults (`speechModel`). It needs Apple silicon. v3 stays the default: on the
  owner's own captures and a fixture of the list's hard terms, Ultra got more terms wrong
  (`harness/speech-bench`, 24 November 2026).
- **No wait on first use.** Core ML prepares a model for the Neural Engine at its first load after
  each start of the app (about 25 s on a MacBook Pro). The app loads the chosen model in the
  background a few seconds after it starts, when its files are on this Mac, so the first
  dictation is at once. You can talk during a load: the microphone is open and what you say is
  kept (the last 60 s). The pill says "Getting the speech model: N%" only while files download,
  and "Loading the speech model" while they only load.
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
  from anywhere but this setting. The list does two things. A second, small model (Parakeet CTC 110M, 100 MB)
  listens for the terms in what you said and puts a term in where the sound fits it; it works
  with each model above, as all of them share v3's tokenizer. Then each wrong form, and each term
  in another case, is written as the term. Dictation uses the list of the mind this Mac is lent
  to; the input bar uses the list of the mind the input goes to; a capture uses its mind's. A mind
  with no `words.md` gives no list.
- **How the text goes in.** The text is put on the clipboard, ⌘V is pressed for you, and the
  clipboard gets back what it held. That needs the **Accessibility** permission. Without it the
  text stays on the clipboard, and the app opens the guide for the permission. Settings ›
  Dictation, "Put the text: On the clipboard only", leaves it there, with no ⌘V.
- **Permissions.** The microphone, at the first use. The line under the panel's three buttons
  says how the last dictation ended, when it is the newest. `app.log` holds counts and times, never the words.

While you talk, the text is written again twice a second from the stretch of speech that is going.
A stretch ends at a pause of 0.7 s, or after 14 s at its quietest moment; then its text is final:
one segment, with its times from the start.

## Online and local (a proposal, not built)

What the speech bench measured on 24 November 2026 (`harness/speech-bench`, the synthetic set: 48
clips of `say -o`, two voices; an M4 Max on a home connection). The owner's own voice
(`--set owner`) must confirm it before anything is built.

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
  mind with online speech: it must be a choice of the mind, said in the panel's speech section.
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
| `record`  | the record's spool into the mind                                             | `DeviceRecord`     | `record.mjs`    |
| `capture` | one capture into the mind, by its id                                         | `Capture`          | `capture.mjs`   |
| `input`   | one input into the mind, by its id                                           | `MindInput`        | `input.mjs`     |
| `words`   | the mind's `words.md` into the app's copy                                    | `Words`            | `words.mjs`     |

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
swift test                    # the state machines' tests (needs Xcode): microphone, camera, lend, banner, the record, the mark, record.set's rule, live, the input's draft
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

`.build/release/VoiceMeetMac --render-panel panel.png` draws the panel to a file without opening
anything, with fixed minds, things and clock (see "Testing with no hand"). A third word draws the lend in one phase: `live`, `reconnecting`, `stopped` or
`not-allowed`, `incompatible`; `ringing` draws a call's banner at the top; `busy` (watched,
recording, an act that runs), `blocked` (Screen Recording and Accessibility not given), `activity`
(the Activity page) and `no-mind` draw the panel's own states. `--render-banner banner.png ring`
draws a banner (`ring`, `request` or `notice`; add `dark` for the dark appearance);
`--render-ring ring.png` is the ring's. `--render-switcher <folder>` draws the mind switcher,
closed and open, light and dark, four files. `--render-input <folder>` draws the input bar (empty,
listening, with a text and files, while it sends, not sent) and the dictation pill (loading,
listening, locked, failed), light and dark, eighteen files. `--render-settings <folder>` draws the Settings window's pages, light and dark, eight files. `--render-approval <folder>` draws the
Ask question, and `--render-log <folder>` the Activity window, light and dark, two files each. `--render-all <folder>` draws every
view, light and dark.

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
| `fluid-speech-pro` | Core ML, the FluidVoice fork of FluidAudio, patched for Xcode 16 | The fork's CTC boosting |
| `phonon-2.5-english` | Core ML on the Neural Engine, the package's C library | 25 hotwords (its most) |
| `oruk-fourier-2b` | MLX 8-bit, Python mlx-audio (CC BY-NC 4.0) | The terms in its prompt |
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
set. Its panel closes by its mark alone. Its mark in the menu bar is grey with an orange "test"
beside it, and its tooltip says `iterate test copy: <home>`, so it is never taken for the installed
app. `Sources/VoiceMeetMac/AppEnvironment.swift` resolves all of
it at launch.

**The control socket**, `<home>/control.sock`, is open in a copy with a home of its own, and only
there: the installed app has none, and always asks with its alert and Touch ID. One line of JSON a
connection, as the endpoint's; a mind never reaches it.

| Method | What it does |
| --- | --- |
| `ui.state` | The lend, the minds, the mind session (generation, mind, name), the windows on the screen, the panel, the input bar, the dictation (with its last text), the capture, the activity (its context, and each row's act id and whether it is in the mind), the Activity window's log (`log`: how many events it holds and shows, their types, whether older ones are left), the banner, the record, the choices, the question that waits |
| `ui.tree` | The accessibility tree of the app's own windows: role, `id`, label, value, frame |
| `ui.press {id, label?}` | Presses the control with that accessibility identifier; `label` picks a segment (`{"id":"sharing.commands","label":"Ask"}`) or a pop-up button's item (`{"id":"settings.approvalMinutes","label":"1 hour"}`) |
| `ui.type {id, text, replace?}` | Types into it (`input.text`), at its end or in place of its text |
| `ui.scroll {id}` | Scrolls a list to its end (`log.list`), as a person does to read older rows |
| `input.toggle`, `capture.toggle`, `capture.mark {points}` | ⌥⇧Space, ⌥⇧S, and ink (points of the display from its top left) |
| `dictation.start`, `dictation.stop` | A hold of fn: fn down, and fn up at least 0.35 s after it |
| `dictation.fn {down}`, `dictation.esc` | fn down (`true`) or up (`false`), and Esc: a hold, a tap, or two taps that keep it on |
| `approval.answer {allow, keep?}` | Answers the Ask question that waits; `keep` approves for `approval.minutes` (30 unless set). While the socket is open, the question's panel shows and its buttons answer too (`ui.press` on `approval.once`, `approval.minutes`, `approval.deny`), and no Touch ID is asked |

The identifiers: `statusItem`, `panel.reconnect`, `panel.openInput`, `panel.copyPrompt`, `panel.quit`,
`sharing.<thing>`, `device.input`, `device.keep`, `record.<source>`, `record.windowText`,
`activity.all`, `activity.back`, `activity.context`, `activity.showsPill`, `activity.window`, `approval.once`,
`approval.minutes`, `approval.deny`, in the Activity window `log.mode` (a segment by its label: `Acts`, `Every event`),
`log.filter.<acts|presence|app|window|record|live|inputs|keys>`, `log.search`, `log.list`, `log.row`, `log.context`,
`log.sharing`, `log.endApproval`, `log.copy`, `log.showsPill`, `log.close`, `input.text`, `input.send`, `input.mind`, `input.microphone`, `capture.send`,
`capture.discard`, `speech.model` (the panel's speech row: it opens Settings › Dictation),
`speech.model.<id>` (a model in its list), `panel.settings`, and in Settings `settings.page.general`,
`settings.page.dictation`, `settings.page.mind.<address>`, `settings.addMind`, `settings.login`,
`settings.showsPill`, `settings.approvalMinutes`, `settings.key.capture`, `settings.key.input`,
`settings.doubleTap`, `settings.dictationKey`, `settings.pillWords`, `settings.write`,
`settings.wordsExpression`, `settings.mind.name`, `settings.mind.wordsSource`,
`settings.mind.expression` (and `.save`), `settings.mind.fetch`, `settings.mind.use`, `settings.mind.remove`. The tree is read in the app's own process and needs no permission of macOS; to
have SwiftUI's elements in it, the socket sets the app's "enhanced user interface" attribute, as an
assistive app does.

```sh
.build/debug/VoiceMeetMac --home /tmp/mac-test &
printf '{"method":"ui.press","id":"statusItem"}\n' | nc -U /tmp/mac-test/control.sock
printf '{"method":"ui.tree"}\n' | nc -U /tmp/mac-test/control.sock
```

**The audio fixture.** With `ITERATE_MAC_AUDIO_FIXTURE=<file.wav|.aiff|.m4a>`, every listening
(dictation, the input bar) hears that file in place of the microphone, at the pace of the clock,
then silence; no audio device opens, and the copy loads the speech model in the background as the
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
device event reaches A after the switch), and the local ones, which need the speech models in
`~/Library/Application Support/FluidAudio`: `dictation-fixture` (a sentence from `say -o` is
written with the word list's Herdr, Beelink and Doppler), `dictation-fn` (one tap of fn
listens until its window ends and leaves no line; a hold writes the sentence; a double tap locks
it until the next press of fn, which writes it; a lock that Esc ends writes nothing), `capture-transcript-fixture` (the
sentence after 2 s of silence, pushed as a capture's buffers with their times, gives segments with
the terms that start after the silence) and `speech-model` (Ultra chosen through `ui.press` is
the stored choice). CI runs `ci`, every scenario but the local ones. `--keep` keeps the homes and their logs.
