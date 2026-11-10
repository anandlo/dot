<p align="center">
  <img src="Resources/AppIcon-1024.png" width="120" height="120" alt="Dot Icon" style="border-radius: 26px;">
</p>

<h1 align="center">Dot</h1>

<p align="center">
  <strong>Write as fast as you can think.</strong><br>
  <em>Native, privacy-first push-to-talk voice dictation for macOS (Public Beta v0.1.0-beta)</em>
</p>

<p align="center">
  <a href="https://github.com/anandlo/dot/releases"><img src="https://img.shields.io/github/v/release/anandlo/dot?include_prereleases&style=flat-square&color=black" alt="Release"></a>
  <a href="https://buymeacoffee.com/anandlo"><img src="https://img.shields.io/badge/Buy%20Me%20a%20Coffee-Support%20Dot-FFDD00?style=flat-square&logo=buy-me-a-coffee&logoColor=black" alt="Buy Me A Coffee"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg?style=flat-square" alt="MIT License"></a>
</p>

<p align="center">
  <a href="#overview">Overview</a> •
  <a href="#the-landscape-comparison">Comparison</a> •
  <a href="#features">Features</a> •
  <a href="#technical-architecture">Architecture</a> •
  <a href="#supported-providers">Providers</a> •
  <a href="#install">Install</a> •
  <a href="#license">License</a>
</p>

---

## Overview

**Dot** is a high-speed, privacy-first push-to-talk dictation utility built natively for macOS. Press and hold your shortcut, speak your thoughts, and release: your words are transcribed in real-time and pasted directly at your cursor upon release.

Dot is engineered for developers, writers, and power users who want voice dictation without subscription paywalls, closed-source cloud daemons, or ambient microphone listening.

```
  Hold ⌃⌥R  ──▶  Speak  ──▶  Release  ──▶  Direct Cursor Paste (<50ms)
```

---

## The Landscape (Comparison)

| Feature | Dot | Hex (Anomaly) | MacWhisper | Superwhisper |
| :--- | :---: | :---: | :---: | :---: |
| **Price & License** | **100% Free · Open Source (MIT)** | Free · Open Source (GPL) | Free / €39 Pro · Closed | $96–$180/yr · Subscription |
| **Stop-to-Paste Latency** | **<50ms (Provisional streaming)** | Length proportional | Batch / Manual | ~1.0s – 2.5s |
| **Microphone Activation** | **Hardware Push-to-Talk only** | Push-to-talk | Manual trigger | Toggle / Hold |
| **Ambient Listening** | **Zero (Mic hardware dormant)** | Zero (Hardware dormant) | Zero | App dependent |
| **Model Freedom** | **8+ Providers or Self-Hosted** | English-only (Parakeet) | Local Whisper only | Whisper / OpenAI |
| **Mandatory Model Download** | **0 MB (Instant startup)** | ~600MB–1.2GB weights | ~150MB–2.8GB weights | Local or Cloud |
| **Network & Privacy** | **Zero Dot servers · Offline or BYOK** | 100% on-device | 100% on-device | Third-party cloud |
| **Credential Storage** | **macOS Keychain isolated** | N/A (Local engine) | Local disk storage | Cloud / Local |
| **Memory Footprint** | **< 15 MB RAM (Pure Swift 6)** | ~450+ MB (Rust / ONNX) | ~200MB–800MB | ~250–400 MB (Electron) |

---

## Features

### True Hardware Push-to-Talk
The microphone is completely unhooked and hardware-dormant while idle. Audio capture initializes only upon physical key-down and is immediately severed on key-up. There is zero background monitoring, zero ambient room listening, and zero wake-word detection.

### Sub-50ms Stop Latency
Instead of waiting for recording to end before starting transcription, Dot streams provisional audio in real-time while you hold the shortcut. On key release, the trailing boundary is committed in under 50 milliseconds.

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
│  • Global Shortcut Monitor (CGEventTap)                │
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
| **⌃⌥R** | **Push-to-Talk** | Hold to record audio, release to transcribe and auto-paste. |
| **⌥⌘V** | **Paste Last** | Re-pastes the most recent transcription without recording. |
| **Esc** | **Cancel** | Cancels the active recording without pasting. |
| **⌘,** | **Settings** | Opens Settings and Provider configuration. |

*Shortcuts can be customized to any key or modifier combination in **Settings → Shortcuts**.*

---

## Install

### Option A: Direct Download

1. Download the latest `Dot.dmg` from [GitHub Releases](https://github.com/anandlo/dot/releases).
2. Open `Dot.dmg` and drag **Dot** into your **Applications** folder.
3. Open **Dot** from `/Applications`.

*If macOS asks for confirmation on first launch, right-click `Dot.app` in `/Applications` and select **Open**.*

### Option B: Homebrew Cask

```bash
brew tap anandlo/tap
brew install --cask dot
```

### Option C: Build from Source

```bash
git clone https://github.com/anandlo/dot.git
cd dot
./scripts/build.sh
```

---

## Permissions

Dot requests only the permissions strictly required to function:
- **Microphone**: Needed to capture audio strictly while your shortcut key is actively held.
- **Accessibility**: Needed only for **Auto-Paste** (synthesizing text input into your active frontmost application).

*Dot does not request Screen Recording permissions and contains zero background analytics or telemetry.*

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
