# The speech bench's sentences

The test set of `harness/speech-bench`: what the owner dictates to a coding agent, with the text
that a transcript must give. `record.mjs` shows one at a time and records it; `run.mjs` scores each
engine against these texts. Every term of iterate.com's `words.md` (24 November 2026) is in at
least one sentence.

Each line `NN. text` is one sentence; the text is the reference, written as the transcript must
write it (`AGENTS.md`, `/devices/jonas.mac`). Say it the way you would say it to an agent: "agents
dot md", "slash devices slash jonas dot mac". The headings give each sentence its kind.

## Terms

01. Ask Claude Code to open a Herdr workspace on the Beelink and run pnpm install, then check that oxlint and knip both pass before you push.
02. The facet should keep its liveState in a Durable Object on Cloudflare, so that a restart of workerd does not lose the session.
03. Use capnweb for the call, and return an RpcTarget from the server, so the client holds an RpcStub and not a plain object.
04. Tell Misha Kaletsky that the sqlfu migration broke in CI, and ask mmkal whether tsdown or the tRPC types changed.
05. Read AGENTS.md first, then make the itx command print the mind's address and its os.iterate.com link.
06. Jeeves should answer on the voice-meet line and hand the call to Jev if Jonas Templestein does not pick up.
07. Put the OpenAI key in Doppler and set DOPPLER_CONFIG to dev before you start the Playwriter session in Chrome.
08. Codex and OpenCode both got the codemode prompt wrong, so try Fable or Grok on the same task and compare them.
09. Open the Plannotator review, then draw the flow in tldraw and paste the picture into Scrawl for Leah.
10. The passkey login needs the YubiKey on this Mac, and after that Tailscale lets the Beelink reach the garple mind.
11. Build the settings page with shadcn and TanStack Router, and send each click to PostHog with the facet's name.
12. Copybara copies the iterategrations folder from the private repo to the public one every night.
13. Ask Kenton whether the middlewright hook in workerd runs before or after the Durable Object wakes up.
14. Matt Pocock has a good thread on that type error, so send the link to Astra and Misha before the call.
15. Nustom pays for Depot, so move the iterate build cache there and drop the old runner.
16. Wispr Flow writes Mind Meld as one word, so add it to the word list and see if Claude gets it right now.

## Plain

17. Can you look at why the tests are slow today and tell me which one takes the longest?
18. Please rename the function to something clearer, keep the behaviour the same, and add a short comment above it.
19. I think the second approach is better because it keeps the state in one place, so go with that one.
20. Before you change anything, write down the plan in three steps and wait for me to say yes.

## Numbers and paths

21. Open AGENTS.md in the mac-app repo and add a line that says the device lives at /devices/jonas.mac.
22. Look at PR 15 and the two comments on line 240, then rebase it on main and push it again.

## Rambling

23. Okay, so what I want is that when the Mac app starts, it loads the speech model in the background, no wait, actually only if the files are already on disk, otherwise it should wait until somebody opens the panel and then show the download with a progress bar, and also write a line to the log, so we can see how long the load took on the Beelink versus the MacBook.
24. So the thing with Herdr is that each workspace gets its own worktree, right, and I want Claude Code, sorry, I mean Codex, to open three of them, one for the bridge, one for the Swift side and one for the docs, and then each one runs pnpm test, and if any of them fails it should tell me in Slack, no, not Slack, just in the terminal, and stop.
