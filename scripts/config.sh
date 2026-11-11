#!/usr/bin/env bash
#
# The values the scripts share.
#
# Sourced by build.sh, install.sh and uninstall.sh, so the bundle identifier and
# the LaunchAgent label are one value in one place. Nothing here runs a command:
# the file only sets variables, and the script that sourced it goes on.
#
# The one product version lives in VERSION at the package root, and
# Sources/Dot/ProductVersion.swift reads it back out of the built Info.plist, so
# no Swift source spells a version out.

# The variables set here are read by the scripts that source this file.
# shellcheck disable=SC2034

DOT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

MARKETING_VERSION_FILE="$DOT_ROOT/VERSION"
if [ ! -f "$MARKETING_VERSION_FILE" ]; then
  printf 'error: %s is missing\n' "$MARKETING_VERSION_FILE" >&2
  exit 1
fi
MARKETING_VERSION="$(tr -d '[:space:]' < "$MARKETING_VERSION_FILE")"
if [ -z "$MARKETING_VERSION" ]; then
  printf 'error: %s is empty\n' "$MARKETING_VERSION_FILE" >&2
  exit 1
fi

# The bundle identity. `Sources/Dot/LaunchAtLogin.swift` reads the same value
# back from the bundle, so the app and its LaunchAgent are one identity.
BUNDLE_ID="${BUNDLE_ID:-com.anandlo.dot}"
AGENT_LABEL="${AGENT_LABEL:-$BUNDLE_ID}"

# The name of the self-signed code-signing identity, and how long
# scripts/signing-identity.sh makes it valid for. The name is the certificate's
# common name, the label the keys are found under, and the string codesign is
# given; scripts/build.sh and scripts/release.sh sign with it whenever it is
# installed, and fall back to ad-hoc when it is not.
#
# It is also part of every user's designated requirement, through the
# certificate's hash, so changing it means issuing a new certificate, and every
# person who updates has to grant microphone, Accessibility and Automation once
# more. Leave it alone unless the identity is being replaced on purpose.
SIGN_IDENTITY="${SIGN_IDENTITY:-Dot Self-Signed}"
SIGN_IDENTITY_DAYS="${SIGN_IDENTITY_DAYS:-3650}"

# The labels and app names this product used before the identity was unified.
# Their agents and bundles are removed on install and uninstall, so two menu bar
# items can never appear at the same time and no stale agent keeps launching an
# old binary.
LEGACY_AGENT_LABELS="com.mimotalk.app com.local.rune com.local.ion com.local.dot"
LEGACY_APP_NAMES="MimoTalk Rune Ion"
