# Contributing to AppWrangler

Thanks for helping! Bug reports, ideas, documentation fixes, translations and code are all welcome.

## Before you start

- **Bugs:** open an issue with the *Bug report* template. Include the output of `appwrangler rules` and your macOS version.
- **Features:** open an issue first for anything bigger than a small fix, so we can agree on the approach.
- **Security problems:** please don't open a public issue. See [SECURITY.md](SECURITY.md).

By participating you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Setting up

You need macOS 13+ and either Apple's Command Line Tools (`xcode-select --install`) or Xcode.

```bash
git clone https://github.com/IntarsO/AppWrangler.git
cd AppWrangler
./build.sh            # → build/AppWrangler.app
./test.sh             # unit + limiter integration tests (~15 s)
./Tests/e2e/run.sh    # end-to-end against the built app (~45 s)
./build.sh --debug    # debug build (enables screenshot hooks)
```

The tests start short-lived CPU-burning processes and pause and resume them; that's expected. The end-to-end test uses its own data folder, so it never touches your real rules.

## Project layout

See [docs/how-it-works.md](docs/how-it-works.md). In short:
- `Sources/ProcKit` is the C limiter and sampler.
- `Sources/AppWranglerKit` holds all the Swift code, including the UI.
- `Sources/AppWrangler` is the entry point.
- Tests are in `Tests/`.

**The widget** (`Widget/`) is built by `build.sh` with plain `swiftc` into `Contents/PlugIns/AppWranglerWidget.appex`. It shares only `Sources/AppWranglerKit/WidgetSnapshot.swift` with the app, and its buttons are `appwrangler://` links handled in `AppURL.swift`. To check its layout without adding it to the desktop, run `scripts/render-widget.sh`. When testing it from a build:
- `build.sh --install` keeps only the installed copy registered, and stops an old widget process.
- Re-registering (`lsregister -f -R -trusted /Applications/AppWrangler.app`) makes macOS reload it.

## Guidelines

- **Style:** follow the surrounding code. Tabs for Swift, C and shell; comments explain *why*, not what.
- **Tests:**
  - Logic changes need a test in `Tests/AppWranglerKitTests`.
  - Behaviour that touches real processes belongs in `LimiterIntegrationTests` or `Tests/e2e/run.sh`.
- **No new dependencies** without discussion. The project builds with nothing but the Command Line Tools, and we'd like to keep it that way.
- **UI text** must go through `L("English text")`.
  - Add the Russian translation to `Resources/ru.lproj/Localizable.strings`.
  - `LocalizationTests` fails if a key is missing or its placeholders (`%@`, `%d`, `%%`) don't match.
  - Use `%%` for a literal percent sign in strings that take arguments.
- **Safety first:** anything that stops processes must keep the crash-safety guarantee: every stopped PID is recorded in the C module's table before it's signalled.
- **Performance:** with the panel closed, AppWrangler should stay well under 1% of one core. `Tests/e2e/run.sh` reports the overhead.
- **Docs:** update `docs/` and `CHANGELOG.md` when behaviour changes.

## Translations

To add a language:
1. Copy `Resources/ru.lproj/Localizable.strings` to `Resources/<code>.lproj/`.
2. Translate the right-hand sides.
3. Add the code to `CFBundleLocalizations` in `Resources/Info.plist`.
4. Extend `LocalizationTests` to check the new file.

## Icons

The icons are drawn in code by `scripts/make-icons.swift`. Edit it and run `swift scripts/make-icons.swift`; don't edit the PNGs by hand.

## Screenshots

`scripts/screenshots.sh` writes the screenshots used by the README and the User Manual into `docs/images/`. It renders the panel (`panel.png`) and the Help window (`help.png`) with the debug build's capture hook, using a throwaway data folder with sample rules. It renders the widget (`widget-small.png`, `widget-medium.png`) straight from its views. It briefly opens AppWrangler's windows on your screen (they don't take keyboard focus). The panel shows the apps running on your Mac, so check the images before committing them.

## Releasing (maintainers)

1. Run `./test.sh` and `./Tests/e2e/run.sh` (the end-to-end tests don't run on CI).
2. Make sure `CHANGELOG.md` has an `## [Unreleased]` section describing the release.
3. Run `scripts/release.sh X.Y.Z`. It dates the CHANGELOG section, sets the version in `build.sh` and `Resources/AppWrangler-embedded.plist`, commits, tags `vX.Y.Z` and pushes.
4. [`.github/workflows/release.yml`](.github/workflows/release.yml) takes over:
   - it runs the unit tests and builds and checks the zip and the MCP bundle (`scripts/build-mcpb.sh`);
   - it publishes the GitHub release with both files, with notes from that CHANGELOG section (`scripts/release-notes.py`);
   - if the repo variable `MCP_REGISTRY` is `on`, it publishes [`server.json`](server.json) to the [official MCP Registry](https://registry.modelcontextprotocol.io), signing in with GitHub OIDC (no secrets needed);
   - it commits the new version and SHA-256 to [`Casks/appwrangler.rb`](Casks/appwrangler.rb).
5. Afterwards, `git pull` to get the cask commit.

To try the pipeline without publishing anything, run it by hand with *dry run*: `gh workflow run release.yml -f version=X.Y.Z -f dry_run=true`. The zip, the `.mcpb`, `server.json` and the notes are attached to the run as an artifact. Builds are ad-hoc signed; with a Developer ID you'd set `SIGN_IDENTITY` and `NOTARY_PROFILE` (see `build.sh`).

### The MCP bundle

`scripts/build-mcpb.sh` builds `build/AppWrangler-mcp-X.Y.Z.mcpb` from [`Resources/mcpb-manifest.json`](Resources/mcpb-manifest.json): a release build of the `AppWrangler` binary, the icon and the manifest. It validates and packs it with `npx @anthropic-ai/mcpb` (Node needed), and writes `build/server.json` with the version and the bundle's SHA-256. The binary embeds an Info.plist (`Resources/AppWrangler-embedded.plist`), so it knows its bundle ID and version outside the app. The manifest runs `/Applications/AppWrangler.app` when it's installed, and the bundled binary otherwise.

### The wiki

The GitHub wiki is generated from `docs/`, `README.md`, `CHANGELOG.md` and `CONTRIBUTING.md` by `scripts/sync-wiki.py`, so edit those files, never the wiki itself (edits there are overwritten). The script rewrites links between pages, copies the images and checks that every link leads somewhere; `scripts/sync-wiki.py` alone builds a preview in `build/wiki`. [`.github/workflows/wiki.yml`](.github/workflows/wiki.yml) checks it on every change to the docs and, if the repo variable `WIKI_SYNC` is `on`, publishes it when they reach `main`. To publish by hand: `scripts/sync-wiki.py --push` (needs the `gh` login of IntarsO). A new wiki needs its first page created once in the browser.

GitHub Actions ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)) builds the app and runs the unit tests on every push and pull request, on Apple Silicon. Two kinds of test don't run there, because shared CI machines are too noisy for measurements of real CPU time:
- the limiter's timing tests (they skip themselves when `CI` is set);
- the end-to-end tests.

Run `./test.sh` and `./Tests/e2e/run.sh` locally before sending a change that touches the limiter, the enforcer or Auto mode.



For a signed, notarized build, which requires an Apple Developer ID, see the comments at the top of `build.sh`.

## License

By contributing you agree that your contributions are licensed under the [GNU GPL v2](LICENSE), like the rest of the project.
