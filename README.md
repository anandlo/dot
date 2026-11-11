<p align="center">
  <img src="Resources/AppIcon-1024.png" width="120" height="120" alt="Dot Icon" style="border-radius: 26px;">
</p>

<h1 align="center">Dot</h1>

<p align="center">
  <strong>Write as fast as you can think.</strong><br>
  <em>Native, privacy-first voice dictation for macOS. Public beta.</em>
</p>

<p align="center">
  <a href="https://github.com/anandlo/dot/releases"><img src="https://img.shields.io/github/v/release/anandlo/dot?include_prereleases&style=flat-square&color=black" alt="Release"></a>
  <a href="https://buymeacoffee.com/anandlo"><img src="https://img.shields.io/badge/Buy%20Me%20a%20Coffee-Support%20Dot-FFDD00?style=flat-square&logo=buy-me-a-coffee&logoColor=black" alt="Buy Me A Coffee"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg?style=flat-square" alt="MIT License"></a>
</p>

<p align="center">
  <a href="#overview">Overview</a> •
  <a href="#what-dot-does-and-what-it-refuses-to-do">Scope</a> •
  <a href="#features">Features</a> •
  <a href="#technical-architecture">Architecture</a> •
  <a href="#supported-providers">Providers</a> •
  <a href="#controls">Controls</a> •
  <a href="#install">Install</a> •
  <a href="#first-launch">First launch</a> •
  <a href="#permissions">Permissions</a> •
  <a href="#license">License</a>
</p>

---

## Overview

**Dot** is a high-speed, privacy-first dictation utility built natively for macOS. Press your shortcut, speak your thoughts, and press it again: your words are transcribed and pasted directly at your cursor.

Dot is engineered for developers, writers, and power users who want voice dictation without subscription paywalls, closed-source cloud daemons, or ambient microphone listening.

```
  Press ⌥⌘D  ──▶  Speak  ──▶  Press again  ──▶  Direct Cursor Paste
```

Prefer to hold the key while you speak? **Settings → General → Start and stop**
switches the shortcut to hold-to-talk, where the release ends the recording.

---

## What Dot does, and what it refuses to do

This section used to be a table comparing Dot to four other dictation apps. It was
removed: competitor pricing, licences and memory figures change faster than a
README does, at least one cell in it was wrong (Hex is MIT, not GPL), and a table
that cannot be kept accurate is worse than no table at all.

What Dot does:

- **Records only while you dictate.** One shortcut: press it to start, press it
  again to stop. There is no always-on listening state to fall out of.
- **Pastes at the cursor,** into whichever app has focus, using the Accessibility
  API. No clipboard dance, no floating window to click.
- **Works with no account and no server of ours.** The on-device Apple engine
  needs no key and no network. Every other provider is your key, your endpoint.
- **Keeps keys in the macOS Keychain** and nowhere else — not in the config file,
  not in a log.
- **Is MIT licensed,** with no paid tier and no telemetry.

What it deliberately refuses to do:

- **Listen in the background.** No wake word, no voice activity detection while
  idle, no standby microphone. If a recording is not running, the microphone is
  not open.
- **Ask for permissions it does not use.** See [Permissions](#permissions).
- **Ship a comparison table, a leaderboard, or a benchmark it has not re-run.**
- **Pretend it is notarized.** The public builds are self-signed and Apple has
  not seen them; [First launch](#first-launch) says what that costs you.

---

## Features

### Press to Start, Press to Stop
The microphone is completely unhooked and hardware-dormant while idle. Audio capture initializes only when the shortcut is pressed and is immediately severed when it is pressed again. There is zero background monitoring, zero ambient room listening, and zero wake-word detection. Hold mode is one setting away for anyone who prefers the key down on both ends of the sentence.

### Streaming Transcription
Instead of waiting for recording to end before starting transcription, Dot streams provisional audio in real-time while the recording runs. At the end — the second press, or the release in hold mode — the trailing boundary is committed and the text goes to the cursor.

### Direct System-Wide Cursor Paste
Dot commits transcripts directly into Xcode, VS Code, Slack, Terminal, Obsidian, or whatever text field has focus via the macOS Accessibility API.

### Provider Agnostic Freedom
You are never locked into a single proprietary vendor. Run 100% offline using Apple On-Device Speech with zero network access, connect low-latency cloud APIs (Groq, OpenAI, Deepgram, Xiaomi, ElevenLabs, Azure), or point Dot to your self-hosted endpoint (vLLM, Ollama, Whisper.cpp).

### Keychain-Isolated Security
All API keys and secrets are stored exclusively in the macOS Keychain (`kSecClassGenericPassword`). No keys are ever written to configuration files, disk caches, or application logs.

---

## Technical Architecture

Dot is built strictly on Apple native technologies: Swift 6, AppKit, SwiftUI, and AVFoundation. Zero Electron, zero webviews, and zero bulky third-party dependencies.

```
┌────────────────────────────────────────────────────────┐
│                      Dot.app                           │
├────────────────────────────────────────────────────────┤
│  • Global Shortcut Monitor (Carbon hot key)            │
│  • Floating Spectrogram HUD (Metal & CoreGraphics)     │
│  • High-Precision VAD Engine (Trailing Silence Filter) │
│  • Synthetic Paste Dispatcher (Accessibility API)      │
└──────────────────────────┬─────────────────────────────┘
                           │
┌──────────────────────────▼─────────────────────────────┐
│                     DotCore                            │
├────────────────────────────────────────────────────────┤
│  • Circular Audio PCM Ring Buffer                      │
│  • Dynamic Model Catalog & Language Registry           │
│  • Streaming Drivers (Apple, OpenAI, Groq, Deepgram)   │
│  • Hardware-Backed Keychain Credential Store           │
└────────────────────────────────────────────────────────┘
```

---

## Supported Providers

Dot lets you configure and switch between providers at any time via **Settings → Provider** or from the menu bar:

| Provider | Engine / Models | Network & Privacy |
| :--- | :--- | :--- |
| **Apple Speech** | Native macOS on-device speech engine | 100% offline. Zero network traffic, zero API key required. |
| **Groq** | Whisper Large v3, Whisper Large v3 Turbo, Distil-Whisper | Direct connection to Groq API using your own key. |
| **OpenAI** | Whisper (`whisper-1`) | Direct connection to OpenAI API using your own key. |
| **Deepgram** | Nova-2, Nova-3 speech models via `/v1/listen` | Direct connection to Deepgram API. Passes `mip_opt_out` parameter. |
| **Xiaomi ASR** | Hosted MiMo speech-to-text (`mimo-v2.5-asr`) | Direct connection using your own endpoint and API key. |
| **ElevenLabs** | Scribe v2 speech-to-text API | Direct connection. Passes `enable_logging: false` parameter. |
| **Azure Speech** | Cognitive Services REST API | Direct connection to Azure. Passes `storeAudio=false`. |
| **Custom Endpoint** | Any OpenAI-compatible transcription or chat audio endpoint | Connect to self-hosted Whisper, vLLM, Ollama, or LM Studio. |

---

## Controls

| Shortcut | Action | Description |
| :--- | :--- | :--- |
| **⌥⌘D** | **Record** | Press to start recording, press again to transcribe and auto-paste. |
| **⌥⌘V** | **Paste Last** | Re-pastes the most recent transcription without recording. |
| **Esc** | **Cancel** | Cancels the active recording without pasting. |
| **⌘,** | **Settings** | Opens Settings and Provider configuration. |

*Shortcuts can be customized to any key or modifier combination in **Settings → Shortcuts**.*

The shortcut is press-twice by default. **Settings → General → Start and stop**
switches it to hold-to-talk, where the recording ends when you let go.

---

## Install

The version of every release comes from [`VERSION`](VERSION) at the root of this
repository; the badges above read the latest published one.

### Homebrew

```sh
brew trust --cask anandlo/tap/dot   # Homebrew 7 refuses casks from third-party taps until they are trusted
brew install --cask anandlo/tap/dot
```

The cask lives in [anandlo/homebrew-tap](https://github.com/anandlo/homebrew-tap),
and this repository holds the source of truth for it in
[`dist/homebrew/Casks/dot.rb`](dist/homebrew/Casks/dot.rb). If Homebrew says it
cannot find the tap, it has not been published yet — use the DMG or the curl line
below.

### DMG

Download `Dot-<version>-arm64.dmg` from
[GitHub Releases](https://github.com/anandlo/dot/releases), open it, and drag
**Dot** into **Applications**.

There is also a `Dot-<version>-arm64.zip` next to it, and a `SHA256SUMS` covering
both. To check a download before you open it, put the files in one folder and run:

```sh
shasum -a 256 -c SHA256SUMS
```

### curl

This is the only lane with no Gatekeeper step: `curl` does not set the quarantine
attribute, so macOS never puts the app through the first-launch check. It
verifies the release's SHA256, installs to `/Applications`, and loads the login
item:

```sh
curl -fsSL https://raw.githubusercontent.com/anandlo/dot/main/scripts/install-remote.sh | sh
```

Pin a version instead of taking the newest, if that is what you want:

```sh
curl -fsSL https://raw.githubusercontent.com/anandlo/dot/main/scripts/install-remote.sh \
  | DOT_VERSION=<version> sh
```

It replaces an existing `/Applications/Dot.app` only when it can read that
bundle's identifier and find it to be Dot's, verifies the checksum before it
installs anything, and never deletes an app it cannot identify.

### From source

```sh
git clone https://github.com/anandlo/dot.git
cd dot
./scripts/build.sh                     # builds build/Dot.app
./scripts/install.sh                   # builds, installs to /Applications, loads the login item
```

Requires Xcode 16 or later (Swift 6). `./scripts/uninstall.sh` removes the app and
the login item and leaves your configuration and logs alone.

### Signing, and what it changes for updates

Dot is signed with its own self-signed certificate. There is no Apple Developer ID
behind it and nothing is notarized, so Gatekeeper still stops the first launch
until you approve it once, exactly as [First launch](#first-launch) describes.
What the certificate changes is the part macOS keeps: the microphone,
Accessibility, Automation and any Keychain "Always Allow" are recorded against the
signing identity rather than against the build, so they survive an update. An
ad-hoc build, which is what no certificate gets you, is identified by its own hash
instead, and every update looks like a new app that has to be granted everything
again. Moving to this certificate costs one round of re-granting: the approvals
given to the old ad-hoc builds were recorded against their hashes and do not match
the new identity.

Building from source does not require the certificate. `scripts/build.sh` signs
ad-hoc and says so when no identity is installed. To keep your own permission
grants across rebuilds, create the identity once:

```sh
./scripts/signing-identity.sh
```

That creates "Dot Self-Signed" in your login keychain, valid for ten years, and
every later build signs with it. The first build that uses it shows one keychain
dialog asking whether `codesign` may use the private key; choose **Always Allow**.
Nothing is marked trusted: the certificate has no trust settings, and only
`codesign` is allowed to read its key, so it cannot vouch for a website, an email
signature or any other app.

Keep a copy of the identity if you plan to use it for long. A new certificate is a
new identity, and every permission would have to be granted again:

```sh
./scripts/signing-identity.sh --backup ~/Documents/Dot-Self-Signed.p12
./scripts/signing-identity.sh --import ~/Documents/Dot-Self-Signed.p12   # another Mac
```

Release builds sign with the same identity when the machine that builds them has
it, and fall back to ad-hoc when it does not. `./scripts/build.sh` and
`./scripts/release.sh` both print which one was used, together with the designated
requirement that `codesign -dr -` reports for the result.

---

## First launch

The public builds are **self-signed** with Dot's own certificate: there is no
Apple Developer ID behind them and they are not notarized, so the first launch is
blocked until you say otherwise. macOS gives you the switch:

1. Open **Dot** from `/Applications`. macOS says it cannot verify the developer.
2. Open **System Settings → Privacy & Security**, scroll to **Security**, and click
   **Open Anyway** next to the message about Dot.
3. Confirm with **Open**. Dot starts, and macOS remembers the decision.

That button is there for about an hour after the first attempt. If it is gone,
open Dot again so macOS records a fresh attempt, then look again.

**If macOS says "Dot is damaged and should be moved to the Trash":** that is the
download quarantine flag meeting a signature Gatekeeper cannot evaluate, not a
damaged file. Clear the flag and open it again:

```sh
xattr -dr com.apple.quarantine "/Applications/Dot.app"
```

Homebrew installs get this check too — `brew` quarantines every cask it downloads
and no longer offers `--no-quarantine`, and a cask cannot opt out on your behalf.
Use the same Open Anyway path. The `curl` lane above is the one that skips it,
because `curl` downloads never carry the flag in the first place.

---

## Requirements

| | |
| :--- | :--- |
| **macOS** | 14 Sonoma or later (`LSMinimumSystemVersion` is `14.0`; the cask declares `depends_on macos: :sonoma`) |
| **Architecture** | Apple silicon (arm64) for the published DMG and zip. They are built by GitHub's `macos-latest` arm64 runner and `scripts/build.sh` builds for the host only, so nothing x86_64 is published. |
| **Building from source** | Xcode 16 or later, for Swift 6 (`Package.swift` is `swift-tools-version: 6.0`). Building on an Intel Mac produces an x86_64 app; that path is untested. |

The installed app is about 9 MB.

---

## Permissions

Dot asks for two, and only when it first needs them:

- **Microphone** — to capture audio, and only while a recording is running.
- **Accessibility** — to paste the transcript at your cursor, by synthesizing the
  keystroke into the frontmost app. Without it, Dot still transcribes; it just
  cannot type for you.

**Input Monitoring is not required and is never requested.** The global shortcut
is a Carbon hot key, and the key state is read from the window server's keyboard
state, so Dot never installs an event tap.

Dot does not request Screen Recording, runs no second background process — the
menu bar app is the only process — and contains no analytics or telemetry.

---

## Supporting Dot

Dot is completely free and open source. If Dot saves you time or makes your daily workflow smoother, you can support future development:

<p align="left">
  <a href="https://buymeacoffee.com/anandlo">
    <img src="https://img.shields.io/badge/Buy%20Me%20a%20Coffee-Support%20Dot-FFDD00?style=for-the-badge&logo=buy-me-a-coffee&logoColor=black" alt="Support Dot on Buy Me a Coffee">
  </a>
</p>

---

## License

Dot is licensed under the [MIT License](LICENSE).
