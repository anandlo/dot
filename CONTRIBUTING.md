# Contributing to Dot

Thank you for your interest in contributing to Dot! We welcome contributions, bug fixes, feature proposals, and improvements from the community.

---

## Development Setup

### Prerequisites
- macOS 14.0 (Sonoma) or macOS 15.0+ (Sequoia)
- Xcode 15.0+ or Swift 6.0+ Command Line Tools
- Git

### Getting the Code
```bash
git clone https://github.com/anandlo/dot.git
cd dot
```

---

## Building and Testing

Dot uses standard Swift Package Manager tooling.

```bash
# Run all unit and integration tests
swift test

# Build debug binary
swift build

# Build release .app bundle
./scripts/build.sh

# Build DMG distribution package
./scripts/release.sh
```

All 330+ unit tests must pass cleanly before any code is merged.

---

## Architecture Overview

Dot is divided into two primary targets:

1. **`DotCore`**: Foundation library containing headless business logic, data models, audio recording interfaces (`Recorder`), configuration storage (`DotConfig`), provider client drivers (`ProviderRegistry`, `OpenAIProvider`, `DeepgramProvider`, `GroqProvider`, etc.), and Keychain credential management (`CredentialStore`).
2. **`Dot`**: The native macOS application shell containing AppKit window controllers, menu bar management, the floating dynamic HUD (`HUDView`), Settings window (`SettingsView`), and the first-run onboarding tour (`WelcomeView`, `WelcomeTour`).

---

## Code Guidelines

- **Native macOS Craftsmanship**: Dot adheres strictly to Apple's Human Interface Guidelines. Avoid non-standard UI paradigms.
- **Zero Heavy Dependencies**: Avoid adding bulky third-party SPM packages. Dot is built on native Foundation, AppKit, AVFoundation, and SwiftUI.
- **Strict Concurrency**: Code should conform to modern Swift concurrency (`async`/`await`, `@MainActor`, `Sendable`).
- **Clean Documentation**: Code comments should explain design decisions and non-obvious invariants rather than redundant restatements of code. Avoid ephemeral bug notes or ad-hoc task comments.
- **Privacy First**: Dot never phones home, collects telemetry, or leaks credentials. Secrets must remain strictly within macOS Keychain.

---

## Submitting Pull Requests

1. Fork the repository and create your feature branch:
   ```bash
   git checkout -b feature/your-feature-name
   ```
2. Make your changes with focused, descriptive commits.
3. Verify that all tests pass:
   ```bash
   swift test
   ```
4. Push your branch to GitHub and open a Pull Request against `main`.
5. Provide a clear PR description explaining the motivation, changes made, and any manual verification performed.
