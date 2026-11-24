# iterate Mac app: design handoff

For the coding agent that works in `iterate/mac-app`. Put this folder in the repo as `design/` and
start here. It was written against commit `ed82455` ("The activity log is a view of the device's
context (#14)").

## 0. How to use this folder

| Path | What it is |
| --- | --- |
| `HANDOFF.md` | This file: what to build, in which order, in which source files. |
| `targets/<name>-<dark\|light>.png` | Each state, drawn at 2 pixels to a point, as the repo's baselines are. |
| `html/<name>-<dark\|light>.html` | The same state as one standalone HTML file with inline styles. Open it in a browser, or read it for an exact size, gap or colour. |
| `tokens.json` | The colours, type sizes, radii and sizes the mocks used. |

Rules for reading the targets:

1. **They are mocks, not pixel targets.** They were drawn in HTML with the Inter font, not in SwiftUI
   with SF. Match the order of things, the words, the states, what each colour means, and sizes to
   within a few points. Do not chase font rendering or the look of a native control.
2. **Behaviour comes from the repo.** Where this file and `README.md` disagree on what the app
   does, the README and the code are right, except in a paragraph that starts with **CHANGE**.
3. **System colours first.** Where macOS has a colour for the role (the accent, green, orange, red,
   the label colours, the materials), use it. The hex values in `tokens.json` are what the mock
   used in their place.
4. **The icons in the mocks are stand-ins.** Keep the SF Symbols the app uses today (`display`,
   `video`, `mic`, `speaker.wave.2`, `bell.badge`, `text.viewfinder`, `terminal`, `person.wave.2`,
   `keyboard`, `eye.fill`, `icloud.slash`, `exclamationmark.triangle.fill`). The mark in the menu
   bar (`IterateIcon.swift`) does not change at all.

Rules for the work:

- One milestone is one pull request. Milestones 1 to 3 are wanted; 4 and 5 are optional and need a
  yes from Jonas first.
- Before each pull request, run what `AGENTS.md` lists: `swift build`, `swift test`,
  `node --test 'bridge/*.test.mjs'`, `node harness/snapshots.mjs`, `node harness/run.mjs all`.
- A view that changes gets new baselines in the same pull request
  (`node harness/snapshots.mjs --update`). Say in the pull request which baselines changed and why.
- Keep every accessibility identifier the harness uses: `statusItem`, `panel.reconnect`,
  `panel.openInput`, `panel.copyPrompt`, `panel.quit`, `sharing.<thing>`, `device.input`,
  `device.keep`, `record.<source>`, `record.windowText`, `activity.context`, `activity.showsPill`,
  `input.text`, `input.send`, `input.mind`, `input.microphone`, `capture.send`, `capture.discard`.
  `ui.press {"id":"sharing.commands","label":"Ask"}` must still pick a segment by its label.
- Do not change the bridge's contract with the mind (`bridge/mac-endpoint.ts`), the defaults keys
  that exist (`sharing.<id>`, `record.<source>`, `device.input`, `device.keep`,
  `device.windowText`, `activity.pill`), or the words `Off`, `Ask`, `Shared`.
- Write copy the way the repo does: plain words, full sentences, no exclamation marks.
- When something here cannot be built as described, stop and say so in the pull request. Do not
  invent a behaviour to fill the gap. Section 8 lists what is already known to be open.

## 1. What each colour means

One rule set for every view. Today's app already follows the first four.

| Colour | Means | Where |
| --- | --- | --- |
| Green | The lend is live. A banner shows. | The dot on the mind's face, "Live", the call's icon. |
| Orange | Something waits or is held up: connecting, reconnecting, not yet in the mind, macOS has not allowed a permission. | The dot, the phase's words, `icloud.slash`, the warning rows. |
| Red | A mind is using this Mac now, or the Mac records or is watched. Also a lend that stopped or is not allowed. | A running act's icon, "in use" notes, the record's switches and dot, the watcher's row. |
| Accent | How far a thing is opened to a mind. | The segmented control and a thing's icon when it is not Off. Nothing else. |
| Neutral | Everything you do yourself. | Buttons, the three action buttons, Quit. |

The segmented control's fill grows with exposure, so the safe choice is the quiet one:

| Selected segment | Fill | Text |
| --- | --- | --- |
| Off | A neutral knob, as a native segmented control draws its selection. | Primary. |
| Ask | The accent at about 30% (16% in light). | The accent, darkened or lightened to stay readable. |
| Shared | The solid accent. | White, semibold. |

An unselected segment has no fill and secondary text. This needs a small custom control: a native
`Picker(.segmented)` cannot colour one segment. Keep it a group with three buttons labelled Off,
Ask, Shared for accessibility and for the control socket.

## 2. Milestone 1: the panel

Targets: `v2-Live`, `v2-Busy`, `v2-Blocked`, `v2-Activity`, `v2-NoMind`, `v2-Phases`, `v2-Top`.
Source: `Panel.swift`, `MindSwitcher.swift`, `DeviceEvents.swift` (`DeviceEventsSection`),
`DeviceRecord.swift` (`RecordSection`), `DeviceLive.swift` (`LiveSection`), `Activity.swift`
(`ActivityList`).

Nothing the app can do is removed. The panel is 400 points wide (430 today) and its sections are
in this order, top to bottom:

1. The banner, while one shows (unchanged in behaviour).
2. The mind and the lend's phase.
3. Who watches live, while somebody does.
4. Capture, Input, Dictate.
5. A mind can use (the Off / Ask / Shared rows).
6. Events to the mind.
7. Record into the mind.
8. Activity.
9. The footer.

The middle still scrolls when the panel is taller than the screen, as today. The quiet live panel
is about 740 points tall; today's is 891.

### 2.1 The mind and the phase (`v2-Live`, `v2-Phases`, `v2-Top`)

One row, the whole of it the switcher's button: the face (34 pt) with the lend's dot, the name
(15 pt semibold), then `address · itx.<name>` (12 pt secondary), and at the right the phase in two
lines with the up-down chevron.

| `phase` | First line (colour) | Second line | Below the row |
| --- | --- | --- | --- |
| `connecting` | Connecting (orange) | since 14:01 | nothing |
| `live` | Live (green) | since 14:01 | nothing |
| `reconnecting` | Reconnecting (orange) | attempt 2 of 14 | An orange block: "Attempt 2 of 14. Next try in 30 s.", the last failure in monospace, **Reconnect Now**. |
| `stopped` | Stopped (red) | next start in 3 s | A red block: the reason, **Reconnect Now**. |
| `notAllowed` | Not allowed (red) | the key waits | A red block: the reason, **Open the Link to Allow This Mac** (prominent), **Reconnect Now**. |
| `incompatible` | Incompatible (red) | update the CLI | A red block: the reason, the command in monospace, **Copy Command**. |
| `idle` | Not lent (secondary) | no mind is active | See 2.9. |

The words of each reason stay `LendState.statusLine`'s. Only their place changes: the phase's name
moves to the right of the row, and the rest goes into the block.

**CHANGE.** **Reconnect Now** shows only in a block (not while live or connecting). While live it
is the last entry of the open switcher, under **Remove a Mind…**. `panel.reconnect` stays its
identifier in both places.

The open switcher (`v2-Top`, first panel) is today's list with one addition: each mind's line says
its state at the right ("Live", "Key allowed", "Key waits"). See open question 8.2 before building
that addition.

### 2.2 Watched live (`v2-Busy`)

`LiveSection` moves up to directly under the mind, as one red-tinted row for each watcher: the
`eye.fill` icon, "Misha is watching live", "the screen, the microphone · since 14:05", and
**End**. It is the most urgent control in the app, so it is the first thing under the mind.

### 2.3 Capture, Input, Dictate

Three equal buttons in a row (46 pt high) replace the three paragraphs of hints: an icon and a
name, and the key under it: `⌥⇧S`, `⌥⇧Space`, `hold fn` (see milestone 2; `hold ⌥⇧D` until
then). Capture starts a capture, Input opens the bar (`panel.openInput`), Dictate starts a
dictation that stays on.

Under the row, one line (11 pt, secondary) says how the most recent of the three ended, from
`captureLine`, `inputLine` and `dictationLine`: "Last input: …". Show only the newest. Draw it in
orange when it failed.

### 2.4 A mind can use (`v2-Live`, `v2-Busy`, `v2-Blocked`)

One card, three groups divided by a hairline, in the README's own order of inputs, outputs and
compute:

1. Each display, each camera, Microphone, Window text.
2. Speakers, Banners.
3. Commands.

A row is 28 pt high: a lead column of 30 pt, the name (13 pt, one line, truncated at the tail),
and the Off / Ask / Shared control (three segments of 46 × 20 pt).

- **The lead column.** The thing's icon, tinted with the accent when the thing is not Off (as
  today). For a display or a camera that is not Off, the lead is the picture of what a mind would
  get, 30 × 19 pt with a 4 pt radius. **CHANGE:** today that picture is 96 pt high under the row.
  A click on it may show the large one in a popover.
- **A note** goes on a second line under the name (the row is then 40 pt): "Approved until
  14:32" in the accent, "Used 3×" in secondary, and while an act of that thing runs, a red dot
  and its word ("running", "watched"). The first two are today's `note(for:)`. The red one is
  new: it is the row of a running act (`ActivityLog`) or of a watcher's track.
- **A permission macOS has not given** shows under the row, as today, in orange: "macOS has not
  allowed Screen Recording yet" and **Allow…**.

"Set all" at the right of the section's title opens a menu: **Everything Off**, **Ask for
Everything**. Nothing else.

### 2.5 Events to the mind

The title's line says, at the right, what always goes: "Presence and the app in front: always".
The card has one row: Keyboard and mouse, its line, and the switch (`device.input`). While it is
on, the line turns red and says "Every key goes to the mind, a password too", and the tick "Keep
these events in the mind's log" (`device.keep`) shows under it. The Accessibility warning is
today's.

**CHANGE.** The sentence "The app in front and its window's title go to the mind always" moves
here from the Record group, because it is about events and not about the record.

### 2.6 Record into the mind

Five switches in one row (46 pt high each), an icon over a name: Screens, Camera, Microphone,
Speakers, Window text. They are today's four switches and the Window text tick, with the same
identifiers (`record.<source>`, `record.windowText`). A switch that is on is red. One that is on
but held off by a missing permission is orange.

At the right of the title: "Off", or a red dot and "Recording", or a red ring and "Paused". Under
the switches, `record.line` as today when it is more than "Off" ("4 tracks · 2 slots waiting",
"Paused: locked", "upload failing: …"), and the missing permission in orange with **Allow…**.

### 2.7 Activity (`v2-Live`, `v2-Activity`)

Closed, the section shows the two newest acts, the count and "All". A row is today's row: the
time, the thing's icon (red while it runs or when it failed), the title on up to two lines, the
detail in monospace, the orange cloud when it is not yet in the mind, and how long it took.

**CHANGE.** "All" opens the list as a second page of the panel in place of the middle sections,
with a back button, where today a disclosure makes a tall panel taller. The page has today's
context line (`activity.context`), the tick "Show each act on the screen"
(`activity.showsPill`), the rows, and "and 12 before these".

### 2.8 The footer

**Copy Prompt** (`panel.copyPrompt`), the source's line ("Version 0.1.0 · updates by itself", or
"Built from ~/src/mac-app"), a Settings button (milestone 3; leave it out until then), and
**Quit** (`panel.quit`, ⌘Q) as a plain button. **CHANGE:** Quit is no longer red and prominent.

### 2.9 No mind yet (`v2-NoMind`)

When `lend.minds` is empty: a plus in place of the face, "No mind yet", one paragraph, **Add a
Mind…** (the existing form), the terminal command `npx @iterate-com/mac-app`, and three lines on
what the choices mean. Capture and Input are disabled. Dictate is not, since it needs no mind.

### 2.10 Drawing the states

`Panel.render(to:phase:dark:)` draws connecting, live, reconnecting, stopped, not-allowed and
ringing today. Add to it, with fixed sample data in `Rendering`:

| New phase word | Draws | Target |
| --- | --- | --- |
| `incompatible` | The phase exists in `sampleLend`, but `renderAll` does not draw it. | `v2-Phases` |
| `busy` | A watcher, an approval until 14:32, uses, keys on and kept, four record switches on, an act that runs. | `v2-Busy` |
| `blocked` | Screen Recording and Accessibility not given, for a shared display, window text, keys and Screens. | `v2-Blocked` |
| `activity` | The Activity page with the sample acts. | `v2-Activity` |
| `no-mind` | No minds. | `v2-NoMind` |

## 3. Milestone 2: dictation that works like Wispr Flow

Targets: `v2-Pills` (the fourth to seventh pills). Source: `HotKey.swift`,
`Sources/VoiceMeetCore/Spoken.swift` (`DictationKey`), `Dictation.swift`,
`Tests/VoiceMeetCoreTests/SpokenTests.swift`, the README's "Dictation" section.

### 3.1 The key

**CHANGE.** Dictation is on the **fn** key alone:

- **Hold fn** and talk. Let go, and the text is written where the cursor is.
- **Double-tap fn** (two presses within half a second) and it stays on with no key held. The next
  press of fn ends it and writes the text. **Esc** ends it and writes nothing.

Rewrite `DictationKey` as this state machine. Keep it a pure struct with its tests. `hold` is
today's 0.35 s (`DictationKey.tap`); `window` is 0.5 s from the first press.

| State | Event | Next state | What the app does |
| --- | --- | --- | --- |
| idle | fn down | pressed | Start listening, show the pill. |
| pressed | fn up after `hold` or longer | idle | Finish: write the text. |
| pressed | fn up before `hold` | tapped | Keep listening until `window` ends. |
| pressed | any other key down | idle | Cancel with no sign: fn was used as a modifier (fn-arrow, fn-delete). |
| tapped | fn down before `window` ends | locked | It stays on. The pill shows the lock. |
| tapped | `window` ends | idle | Cancel: throw the sound away, hide the pill. |
| locked | fn up | locked | Nothing. |
| locked | fn down | idle | Finish: write the text. Ignore this press's release. |
| locked | Esc | idle | Cancel: write nothing. |
| any | the listener fails | idle | As today (`key.ended()`). |

The struct cannot wait by itself: let `released` answer "wait until this time", and let
`Dictation` hold the timer.

The control socket's `dictation.start` and `dictation.stop` keep working as a hold: fn down and,
after at least `hold`, fn up. The `dictation-fixture` scenario must still pass.

### 3.2 Hearing fn

Carbon hot keys (`HotKey.register`) cannot register fn alone. Hear it with one event tap:
`CGEvent.tapCreate` on the session, for `flagsChanged` and `keyDown`. fn is a `flagsChanged`
event with key code 63 (`kVK_Function`) whose flags gain or lose `.maskSecondaryFn`. Arrow keys
and function keys also carry that flag in their own events, so test the key code, not only the
flag. The tap needs the Accessibility permission, which the app already asks for
(`Permission.accessibility`), and dictation already needs it to paste.

- While the Accessibility permission is missing, keep ⌥⇧D working through Carbon as today, and
  open the permission's guide at the first use.
- While a dictation is locked, the tap swallows Esc so that it does not reach the app in front.
  It swallows nothing else.
- **Check on a Mac, do not assume:** whether macOS still acts on fn itself (System Settings ›
  Keyboard › "Press 🌐 key to": the emoji picker, the input source, or Apple's dictation) while
  the tap hears it. If it does, show the orange row in Settings › Dictation (milestone 3) that
  says to set it to Do Nothing, with **Open Keyboard Settings**. Do not change that setting for
  the person.

### 3.3 The pill: one row

**CHANGE.** The pill is one row that runs sideways, so that a five-minute dictation shows at a
glance that it is heard: 460 × 38 pt, a capsule, at the bottom of the screen as today, and it
still takes no click and no key.

Left to right:

1. `LevelBars`, as today.
2. The words on **one line, set against the right edge**, clipped at the left with a fade of
   about 64 pt. The newest words are always at the right and older ones leave at the left. No
   ellipsis, no second line. Before the first word: "Listening" in secondary, at the left.
3. The lock (`lock.fill`, in the accent) while it stays on.
4. The time since the start, `m:ss`, in monospaced digits, secondary.

In SwiftUI: a `Text` with `lineLimit(1)` and `fixedSize(horizontal: true, vertical: false)`
inside a frame of the free width with `.trailing` alignment, `.clipped()`, and a mask of a
leading-to-trailing gradient. Give the view only the end of the text (the last 200 characters are
plenty), as `tail` does today. The loading and failed pills keep their words and get the same
height. The failed pill gains **Allow Accessibility…** only if you also let the pill take clicks
in that state; otherwise leave it out.

### 3.4 Words to change

- The panel's Dictate button: `hold fn`.
- The README's "Dictation" section and the comment at the top of `Dictation.swift`: hold fn;
  double-tap to keep it on; Esc throws it away.
- `Dictation.render` draws: loading, listening (one row), locked (one row with the lock and
  4:12), failed. New baselines: `dictation-listening-*`, `dictation-locked-*`.

## 4. Milestone 3: Settings, for this Mac and for each mind

Targets: `SettingsGeneral`, `SettingsDictation`, `SettingsMindIterate`, `SettingsMindGarden`.
New source: `Settings.swift`. Also `AppDelegate.swift` (⌘, and the panel's button), `Lend.swift`,
`Words.swift`, `bridge/words-fetch.mjs`, `cli.mjs`, `Rendering.swift`.

### 4.1 The window

One window, 800 pt wide, opened by ⌘, and by the panel's Settings button. A sidebar of 212 pt has
two groups:

- **This Mac**: General, Dictation. What holds whichever mind the Mac is lent to.
- **Minds**: one entry for each mind this Mac knows (its face, its name, a dot for its state),
  then **Add a Mind…** (the existing form). Everything that belongs to one mind is on that
  mind's page and nowhere else.

### 4.2 Where each value lives

| Page | Setting | Lives in | Notes |
| --- | --- | --- | --- |
| General | Open at login | `config.json` `login` | Change it the way `cli.mjs` setup does. |
| General | Show each act on the screen | defaults `activity.pill` | Exists. The same value as the tick in Activity. |
| General | An approval can last | defaults `approval.minutes` (new) | `Approval.window` is a constant of 30 minutes today. The alert's second button says the number. |
| General | Capture, Input keys | defaults `key.capture`, `key.input` (new) | `HotKey.Combo` constants today. A key macOS refuses says so in the row. |
| General | Version, Update Now, Update by itself | `UpdateSource` | For a copy or a trial, the row says "Built from …" and has no switch. |
| General | Prompt for an agent | none | `Panel.prompt`, as the panel's button. |
| Dictation | Hold to talk; double-tap to keep it on | defaults `dictation.key`, `dictation.doubleTap` (new) | Milestone 2. |
| Dictation | Put speech into words | defaults `dictation.model` (new) | Build only "On this Mac". See 8.3. |
| Dictation | Show the words in one row | defaults `dictation.pill` (new) | Off: the level bars and the time, with no words. |
| Dictation | Put the text | defaults `dictation.write` (new) | "Where the cursor is" (today) or "On the clipboard only". |
| Dictation | Default itx expression | `config.json` `wordsExpression` (new) | Absent means the built-in one, 4.3. |
| A mind | Lend to This Mind / Lent now | `config.json` `active` | `Lend.use(_:)`, which runs `cli.mjs use`. |
| A mind | Its name there | `config.json` `minds[].name` | A key is for one name: a new name needs a new key, and a member allows it again. Ask before doing it, then `Lend.add(mind:name:)`. |
| A mind | This Mac's key | the lend's phase | See 8.2. |
| A mind | Your sign-in | the iterate CLI | See 8.1. |
| A mind | Word list: the default or its own expression | `config.json` `minds[].wordsExpression` (new) | Absent means the default. |
| A mind | Forget this mind | `config.json` | The existing Remove form, then `Lend.remove(_:)`. |

The app writes `config.json` only through `cli.mjs`, as the panel does today (`Lend.command`).
Add a command for the new values, for example
`cli.mjs set [--mind <address>] --words-expression <text>`. `cli.mjs` must keep the keys it does
not know when it writes a mind's entry: `add` and `setup` build a new entry today and would drop
`wordsExpression`.

### 4.3 The word list's expression

Today `bridge/words-fetch.mjs` reads one fixed file:
`itx.repos.get("/repos/config").readFile("words.md", { commitOid: tip })`. **CHANGE:** what it
runs is a setting, an itx expression, with a default for this Mac and an override for a mind.

- The built-in default does what the script does today:
  `itx.repos.get("/repos/config").readFile("words.md")`.
- `words-fetch.mjs` gets `--expression <text>`. It connects as today, evaluates the text with
  `itx` in scope (an expression, or an `async (itx) => …` function as a capture's script is),
  awaits it and takes the answer as a string. Keep the 30 s limit.
- The answer must be text in today's format, one `- term: wrong form, wrong form` on a line. It
  answers `{ done: true, terms }` or `{ failed }` as today. An answer that is not a string, or
  that has no term, is `failed` with a reason a person can read ("answered a commit id, with no
  line that starts with '- '"). An empty string is still "no list".
- On `failed` the file of the last good list stays, as today, since the file is only replaced
  after a good read. The mind's page says so: "The list of 13:48 is still used: 12 terms."
- `Words.swift` passes the mind's expression, else the default. Keep the ten minutes. **Fetch
  Now** on a mind's page fetches at once.
- The page of a mind shows the result for that mind only: the count and when it was fetched, and
  the first terms with their wrong forms. The Dictation page shows the default expression and no
  mind's result.
- The expression runs as the person, on their own mind, from their own setting. It is the same
  trust as the script on the clipboard after a capture. Do not run an expression that came from
  anywhere but this setting.

### 4.4 Drawing it

Add `--render-settings <folder>`: general, dictation, a mind that is lent and uses the default,
a mind whose own expression fails, light and dark. Add them to `renderAll` and to the baselines.

## 5. Milestone 4 (optional): the Ask question as the app's own sheet

Target: `v2-Approval`. Source: `Approval.swift`.

The system alert becomes a floating panel of the app with the same three answers and the same
rules (one question at a time, 60 s of patience, then Touch ID, the 30-minute approval, the
control socket's `approval.answer`). What it adds: the mind's face and address, what exactly is
asked in monospace (the command, the display's name), and the seconds that are left. Buttons, top
to bottom: **Approve Once** (the default), **Approve for 30 Minutes**, **Deny** (Esc).

## 6. Milestone 5 (optional): Activity in a window

Target: `Log`. Source: `Activity.swift`, `bridge/device-events.mjs`.

A window on the device's context: the same rows as the panel's list, a switch between "Acts" and
"Every event", and at the right the selected event's fields with the thing's Off / Ask / Shared.
"Every event" needs the bridge to read back more types than `device/act-started` and
`device/act-ended`, which is all it reads today. Build "Acts" first, and "Every event" only after
Jonas says which types to read.

## 7. Not in this handoff

The three "takes" on the canvas (a plain menu, a level for each mind, the stream as the panel)
are explorations. Build none of them. The input bar (`v2-Input`) and the act, watch and capture
pills (`v2-Pills`, first three) are today's views with small changes of layout; change them only
if Jonas asks.

## 8. Open questions: ask Jonas, do not guess

1. **How long your sign-in still lasts.** The mock says "Signed in · 3 h 12 min left". Does the
   iterate CLI tell when a session ends? If not, show "Signed in" or "Not signed in" alone.
2. **A key's state for a mind the Mac is not lent to.** The mock says "Allowed by a member" for
   such a mind. The app knows it only for the active mind, from the lend's phase. Without a way to
   ask, say "Not checked" there, and leave the state off the switcher's list.
3. **Speech in the mind.** The mock has "Put speech into words: On this Mac / In the mind" with a
   model's name. There is no contract for it yet. Build "On this Mac" only.
4. **fn and macOS.** See 3.2: whether the tap alone keeps macOS from acting on fn.
5. **Sharing for each mind.** The choices are one set for every mind today, and this handoff
   keeps that. A mind's page would be the place for them if that changes.

## 9. Every target, and how the repo draws it

| Target | State | Drawn in the repo by |
| --- | --- | --- |
| `v2-Live` | The panel, live and quiet. | `--render-panel <file> live` |
| `v2-Busy` | Live, watched, recording, an act running. | new phase `busy` |
| `v2-Blocked` | macOS has not given two permissions. | new phase `blocked` |
| `v2-Activity` | The Activity page. | new phase `activity` |
| `v2-NoMind` | No mind yet. | new phase `no-mind` |
| `v2-Phases` | The top of the panel in five phases. | `connecting`, `reconnecting`, `stopped`, `not-allowed`, `incompatible` |
| `v2-Top` | The switcher open; a call that rings. | `--render-switcher`, phase `ringing` |
| `v2-Pills` | The act and watch pills, the capture pill, the dictation pills. | `--render-activity`, `--render-input`; the capture pill has no drawing yet |
| `v2-Input` | The input bar, filled and failed. | `--render-input` |
| `v2-Approval` | The Ask question. | new `--render-approval` (milestone 4) |
| `SettingsGeneral`, `SettingsDictation` | Settings for this Mac. | new `--render-settings` |
| `SettingsMindIterate`, `SettingsMindGarden` | Settings for one mind: all well, and its own expression failing. | new `--render-settings` |
| `Log` | Activity in a window. | new, milestone 5 |

The sample data in the targets is the repo's own (`Rendering.minds`, the sample acts in
`Activity.swift`, the README's examples), so a drawing of the app and its target show the same
words.
