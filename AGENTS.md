# iterate Mac app

The menu-bar app that lends a Mac to an iterate mind. `README.md` is the guide: what the app does,
how it is installed, the files in a mind it writes, and how to develop it.

- Swift in `Sources/`, the Node bridge in `bridge/` (it imports only Node and the published `iterate`
  package), the installer in `cli.mjs`.
- Check before a pull request: `swift build`, `swift test`, `node --test 'bridge/*.test.mjs'`,
  `node harness/snapshots.mjs`, `node harness/run.mjs all`, and `node --check` on each changed script.
- Look at a view without installing: the `--render-*` flags (README, "Developing").
- Run, drive and check the app with no hand, beside the installed copy: `--home`, the control socket,
  `node harness/snapshots.mjs` and `node harness/run.mjs all` (README, "Testing with no hand").
- Install a build on this Mac with `node cli.mjs update`. Only one session reinstalls at a time.
- Every push to `main` is published to npm and reaches installed Macs within the hour.
