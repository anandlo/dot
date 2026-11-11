#!/usr/bin/env bash
#
# Code signing for Dot, shared by build.sh and release.sh.
#
# Three identities are possible, in this order of precedence:
#
#   developer-id  DEVELOPER_ID is set. `Developer ID Application: <name>`, a
#                 secure timestamp, and the only kind Gatekeeper accepts.
#   self-signed   The identity named in config.sh is in a keychain. Dot's own
#                 certificate, no timestamp, and a designated requirement of
#                 `identifier "com.anandlo.dot" and certificate leaf = H"..."`.
#   adhoc         Neither. The pseudo-identity `-`, which records no certificate
#                 at all, so the designated requirement is the build's cdhash.
#
# The identity decides the designated requirement, and the designated
# requirement is what macOS stores when a person grants a privacy permission
# (TCC) or clicks "Always Allow" on a Keychain item. A cdhash changes with every
# build, so an ad-hoc app is a stranger to macOS after each update; the
# certificate hash does not, so a self-signed app is the same app forever.
#
# Sourced, not run. A script that sources this file may define its own log
# function, which dot_log then uses; without one it prints the line itself.

# The variables set here are read by the scripts that source this file.
# shellcheck disable=SC2034
set -euo pipefail

DOT_SIGNING_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# Hardened runtime resource access. The runtime refuses the microphone to a
# hardened process that does not carry the audio-input entitlement, without even
# showing the permission prompt, and it refuses Apple Events without the
# automation entitlement (the AppleScript call fails with -1743 and no prompt).
# Both are declared once here and applied to every signature, whatever the
# identity, so an ad-hoc build behaves the same as a signed one.
DOT_SIGN_ENTITLEMENTS="$DOT_SIGNING_ROOT/scripts/Dot.entitlements"

dot_log() {
  if declare -F log >/dev/null 2>&1; then
    log "$*"
  else
    printf '%s\n' "$*"
  fi
}

dot_is_macho() {
  file -b "$1" 2>/dev/null | grep -q 'Mach-O'
}

# The code inside the bundle that carries its own signature: dylibs, frameworks,
# plug-ins, and the executable of every nested bundle. `find -depth` lists
# children before their parents, so each piece is signed before the code that
# seals it.
dot_nested_code() {
  local bundle="$1"
  find "$bundle/Contents" -depth \
    \( -name '*.dylib' -o -name '*.so' \) -print -o \
    \( -type d \( -name '*.framework' -o -name '*.appex' -o -name '*.app' \
      -o -name '*.xpc' -o -name '*.bundle' -o -name '*.plugin' \) \) -print -o \
    \( -type f -path '*/Contents/MacOS/*' \) -print
}

# An identity is a certificate with its private key. -v is deliberately absent:
# it asks for identities that satisfy the policy through a trusted anchor, and a
# self-signed certificate is reported as CSSMERR_TP_NOT_TRUSTED and hidden, even
# though codesign signs with it. DOT_SIGN_KEYCHAIN narrows the search to one
# keychain for the build machines that keep the identity out of the search list.
dot_identity_installed() {
  local name="$1"
  if [ -n "${DOT_SIGN_KEYCHAIN:-}" ]; then
    security find-identity -p codesigning "$DOT_SIGN_KEYCHAIN" 2>/dev/null | grep -qF "\"$name\""
  else
    security find-identity -p codesigning 2>/dev/null | grep -qF "\"$name\""
  fi
}

# Sets DOT_SIGN_IDENTITY, DOT_SIGN_KIND, DOT_SIGN_TIMESTAMP and DOT_SIGN_LABEL
# from DEVELOPER_ID, the keychain and config.sh. DEVELOPER_ID is read from the
# environment, so the Developer ID path stays reachable without touching a file.
dot_resolve_signing() {
  if [ -n "${DEVELOPER_ID:-}" ]; then
    DOT_SIGN_IDENTITY="Developer ID Application: $DEVELOPER_ID"
    DOT_SIGN_KIND="developer-id"
    DOT_SIGN_TIMESTAMP="secure"
    DOT_SIGN_LABEL="Developer ID"
  elif dot_identity_installed "$SIGN_IDENTITY"; then
    DOT_SIGN_IDENTITY="$SIGN_IDENTITY"
    DOT_SIGN_KIND="self-signed"
    DOT_SIGN_TIMESTAMP="none"
    DOT_SIGN_LABEL="self-signed ($SIGN_IDENTITY)"
  else
    DOT_SIGN_IDENTITY="-"
    DOT_SIGN_KIND="adhoc"
    DOT_SIGN_TIMESTAMP="none"
    DOT_SIGN_LABEL="ad-hoc"
  fi
}

# Signs the nested code first and the bundle last. `--deep` is not used for
# signing: as of macOS 13 it is deprecated there, it applies every option to
# every nested piece whether that fits or not, and it signs in an order the
# caller cannot see.
#
# The entitlements are applied to every piece, including libraries, where they are
# inert. A nested executable is the case that matters: if Dot ever ships a helper
# that opens the microphone, it is the process macOS asks, and a helper without
# the entitlement would be refused silently.
dot_sign_bundle() {
  local identity="$1" bundle="$2" timestamp="$3" entitlements="$4"
  local item
  local -a timestamp_args=()
  case "$timestamp" in
    secure) timestamp_args=(--timestamp) ;;
    none) timestamp_args=(--timestamp=none) ;;
    *)
      printf 'error: unknown timestamp mode: %s\n' "$timestamp" >&2
      return 1
      ;;
  esac

  while IFS= read -r item; do
    if [ -f "$item" ] && ! dot_is_macho "$item"; then
      continue
    fi
    dot_log "signing nested code: ${item#"$bundle/"} ($identity)"
    codesign --force --options runtime "${timestamp_args[@]}" \
      --entitlements "$entitlements" --sign "$identity" "$item"
  done < <(dot_nested_code "$bundle")

  dot_log "signing the bundle: ${bundle##*/} ($identity)"
  codesign --force --options runtime "${timestamp_args[@]}" \
    --entitlements "$entitlements" --sign "$identity" "$bundle"
}

# Verifies each nested signature against its own requirements, then the bundle.
# This states more than one `--deep` pass would: a nested piece is checked as
# itself, not only as bytes sealed by the parent.
dot_verify_bundle() {
  local bundle="$1" item
  while IFS= read -r item; do
    if [ -f "$item" ] && ! dot_is_macho "$item"; then
      continue
    fi
    codesign --verify --strict --verbose=2 "$item"
  done < <(dot_nested_code "$bundle")
  codesign --verify --strict --verbose=2 "$bundle"
}

# The requirement macOS will match this build against, on one line. Older
# versions of codesign prefix the line with a comment marker; macOS 26 does not.
dot_designated_requirement() {
  codesign --display --requirements - "$1" 2>&1 | sed -n 's/^#* *designated => //p'
}
