<p align="center">
  <img src="docs/AppIcon-1024.png" width="128" height="128" alt="Dot Icon" style="border-radius: 26px;">
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
  <a href="#why-dot-comparison">Comparison</a> •
  <a href="#features">Features</a> •
  <a href="#technical-architecture">Architecture</a> •
  <a href="#supported-providers">Providers</a> •
  <a href="#install">Install</a> •
  <a href="#license">License</a>
</p>

---

## Overview

**Dot** is a high-speed, privacy-first push-to-talk dictation utility built natively for macOS. Press and hold your shortcut, speak your thoughts, and release: your words are transcribed and automatically pasted into your active application in under 50 milliseconds.

Dot is engineered for developers, writers, and power users who want voice dictation without subscription paywalls, closed-source cloud daemons, or ambient microphone listening.

```
  Hold ⌥⌘D  ──▶  Speak  ──▶  Release  ──▶  Instant Paste (<50ms)
```

---

## Why Dot? (Comparison)

| Feature | Dot | Hex (Anomaly) | MacWhisper | Wispr Flow | Superwhisper |
| :--- | :---: | :---: | :---: | :---: | :---: |
| **License & Price** | **100% Free & Open Source (MIT)** | Free & Open Source (GPL) | Free / €39 Pro | $12–$15/mo subscription | $8/mo or $199 lifetime |
| **Stop-to-Paste Latency** | **<50ms (Provisional VAD)** | Length proportional | Manual / Batch | ~1.5s – 3.0s | ~1.0s – 2.5s |
| **Microphone Activation** | **Hardware Push-to-Talk only** | Push-to-talk | Manual trigger | Continuous background | Toggle / Hold |
| **Ambient Listening** | **Zero (Mic hardware dormant)** | Zero (Hardware dormant) | Zero | Background daemon | App dependent |
| **Model Freedom** | **7+ Providers or Self-Hosted** | English-only (Parakeet) | Local Whisper only | Locked cloud vendor | Whisper / OpenAI |
| **Mandatory Model Download** | **0 MB (Instant startup)** | ~600MB–1.2GB weights | ~150MB–2.8GB weights | None (Cloud-hosted) | Local or Cloud |
| **Upstream Zero Data Retention** | **Enforced by default** | N/A (100% on-device) | N/A (100% on-device) | Proprietary cloud | API key dependent |
| **Credential Storage** | **macOS Keychain isolated** | N/A (Local engine) | Local disk storage | Proprietary cloud | Local disk storage |
| **Memory & CPU Footprint** | **< 15 MB RAM (Pure Swift 6)** | ~450+ MB (Rust / ONNX) | ~200MB–2.8GB | ~350+ MB (Electron) | ~120 MB |

---

## Key Capabilities

### True Hardware Push-to-Talk
The microphone is completely dormant when the shortcut is not held. Audio capture starts only upon the physical key-down event and is immediately severed on key-up. There is zero background monitoring, zero ambient room listening, and zero wake-word detection.

### Sub-50ms Stop Latency
Traditional dictation tools suffer from 2–4 second delays caused by sequential network round-trips and post-processing. Dot streams provisional audio speculation in real-time and leverages trailing-silence Voice Activity Detection (VAD) to commit text instantaneously the moment you release the key.

### Provider Agnostic Freedom
You are never locked into a single proprietary vendor. Connect to industry-leading hosted transcription APIs using your own keys, run completely offline using native Apple On-Device Speech, or point Dot to your private self-hosted endpoint (vLLM, Ollama, Whisper.cpp, or LM Studio).

### Zero Data Retention (ZDR) Enforced
For cloud providers, Dot automatically sends upstream Zero Data Retention headers (`mip_opt_out=true` on Deepgram, `enable_logging=false` on ElevenLabs, `storeAudio=false` on Azure). Your audio is processed in memory and never logged, stored, or used for model training.

### Keychain-Isolated Security
All secrets, tokens, and API keys are stored exclusively in the macOS Keychain (`kSecClassGenericPassword`). No keys or credentials are ever written to configuration files, disk caches, or application logs.

---

## Technical Architecture

Dot is built strictly on Apple native technologies — Swift 6, AppKit, SwiftUI, and AVFoundation. Zero Electron, zero webviews, and zero bulky third-party SPM dependencies.

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
│  • Upstream Streaming Drivers (OpenAI, Groq, Deepgram) │
│  • Hardware-Backed Keychain Credential Store           │
└────────────────────────────────────────────────────────┘
```

---

## Supported Providers

Dot lets you configure and switch between providers at any time via **Settings → Provider** or from the menu bar:

| Provider | Engine / Models | Privacy & Data Retention |
| :--- | :--- | :--- |
| **Apple Speech** | Native macOS on-device speech engine | 100% offline. Zero network traffic, zero key required. |
| **Groq** | Whisper Large v3, Whisper Large v3 Turbo, Distil-Whisper | High-speed hosted inference with custom temperature and prompts. |
| **OpenAI** | Whisper (`whisper-1`) | Industry standard transcription API with custom temperature and prompts. |
| **Deepgram** | Nova-2, Nova-3 speech models via `/v1/listen` | Supports Smart Format, Diarization, and Zero Data Retention (`mip_opt_out`). |
| **ElevenLabs** | Scribe v2 speech-to-text API | Supports Diarization, custom keyterms, and Zero Data Retention (`enable_logging: false`). |
| **Azure Speech** | Cognitive Services REST API | Configurable regions (e.g. `eastus`), output format, and zero audio storage (`storeAudio=false`). |
| **Custom Endpoint** | Any OpenAI-compatible transcription or chat audio endpoint | Connect to your self-hosted Whisper, vLLM, Ollama, LM Studio, or private gateways. |

---

## Shortcuts

| Shortcut | Action | Description |
| :--- | :--- | :--- |
| **⌥⌘D** | **Push-to-Talk** | Hold to record audio, release to transcribe and auto-paste. |
| **⌥⌘V** | **Paste Last** | Re-pastes the most recent transcription without recording. |

*Shortcuts can be customized in **Settings → Shortcuts**.*

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
./scripts/install.sh
```

---

## Permissions

Dot requests only the permissions strictly required to function:
- **Microphone**: Needed to capture audio strictly while your shortcut key is actively held.
- **Accessibility**: Needed only for **Auto-Paste** (synthesizing ⌘V into your active frontmost application).

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
