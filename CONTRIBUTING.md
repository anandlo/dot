# Contributing to Dot

## Development setup

Build with Xcode 26 or later. Dot targets macOS 14. Building requires the macOS 26 SDK or newer for APIs such as Apple Speech and Liquid Glass. Apple Speech is unavailable on macOS 14 and 15.

```sh
git clone https://github.com/anandlo/dot.git
cd dot
```

## Build and test

The Satoshi font is fetched rather than committed. Fetch it before any build or test run:

```sh
./scripts/fetch-fonts.sh
```

Then run:

```sh
swift build --build-tests
swift test
./scripts/build.sh
```

`swift build --build-tests` compiles the source and test targets. Fix any compiler warnings before opening a pull request. Run `swift test` without `--parallel`, because the suite is serial: some tests composite offscreen windows and time motion, and parallel processes disturb their measurements. `./scripts/build.sh` assembles and signs the local `build/Dot.app` bundle. Release packaging is separate and is not a contributor step.

## Architecture

- `DotCore`: shared library for configuration, credentials, provider and assistant clients, audio and transcript models, and other logic used by the app.
- `Dot`: the macOS executable target, containing the menu bar, hotkeys, recorder, HUD, Settings, dictation palette, history, and rendering.

## Contributions

- Keep each pull request focused on one change and target `main`.
- Match the existing Swift concurrency and AppKit or SwiftUI patterns. The package has no third-party dependencies; discuss one before adding it.
- Write comments for non-obvious decisions and invariants.
- Use synthetic data in logs and screenshots shared with an issue or pull request. Remove credentials, personal transcripts, and private audio before sharing.

## CI

CI runs on pushes to `main` and pull requests targeting `main`. Its current checks fetch the font, require a warning-free `swift build --build-tests`, run serial `swift test`, and build the app bundle. The `Test & Build` check is required on `main`. A workflow triggered by a fork pull request can require maintainer approval before it starts; if `Test & Build` is waiting for approval, request that approval rather than treating the missing check as a pass.

Run the build and test commands above locally before opening a pull request. State what you ran and any manual verification in the pull request description.
