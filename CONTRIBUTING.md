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

`scripts/screenshots.sh` renders the panel and Settings window into `docs/images/` using the debug build. It briefly opens AppWrangler's windows on your screen.

## Releasing (maintainers)

1. Run `./test.sh` and `./Tests/e2e/run.sh`.
2. Update `CHANGELOG.md`, and build with `VERSION=1.1.0 ./build.sh --zip`.
3. Tag the release (`git tag v1.1.0 && git push origin v1.1.0`), create a GitHub release for the tag, and attach `build/AppWrangler-1.1.0.zip`.

GitHub Actions ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)) builds the app and runs the unit tests on every push and pull request, on Apple Silicon. Two kinds of test don't run there, because shared CI machines are too noisy for measurements of real CPU time:
- the limiter's timing tests (they skip themselves when `CI` is set);
- the end-to-end tests.

Run `./test.sh` and `./Tests/e2e/run.sh` locally before sending a change that touches the limiter, the enforcer or Auto mode.

Releases are built locally with `./build.sh --zip`. Uploading one with `gh release create` also needs an update to [`Casks/appwrangler.rb`](Casks/appwrangler.rb) (version and `sha256`).

For a signed, notarized build, which requires an Apple Developer ID, see the comments at the top of `build.sh`.

## License

By contributing you agree that your contributions are licensed under the [GNU GPL v2](LICENSE), like the rest of the project.
