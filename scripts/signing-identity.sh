#!/usr/bin/env bash
#
# Create the self-signed code-signing identity Dot is signed with.
#
# Why this exists: macOS identifies an app by its designated requirement. For an
# ad-hoc signature there is no certificate, so the requirement is the build's own
# cdhash, which changes on every rebuild. Every privacy permission (microphone,
# Accessibility, Automation, Reminders, Calendar, Contacts) and every Keychain
# "Always Allow" is recorded against that requirement, so an ad-hoc app has to be
# granted everything again after each update. With one fixed certificate the
# requirement is `identifier "com.anandlo.dot" and certificate leaf = H"..."`,
# which does not change when the code does.
#
# This is not a Developer ID and it is not notarized: Gatekeeper still asks once.
# It is not trusted for anything else either. The certificate is imported with
# no trust settings, and only /usr/bin/codesign is allowed to use its key.
#
# Run it once per machine. It never replaces an existing identity: issuing a new
# certificate changes the leaf hash, and every person would have to grant the
# permissions again.
#
# Usage:
#   scripts/signing-identity.sh                  create the identity if it is missing
#   scripts/signing-identity.sh --backup FILE    create it and save the .p12 for a backup
#   scripts/signing-identity.sh --import FILE    import a .p12 made by --backup
#   scripts/signing-identity.sh --show           print fingerprints and expiry
#
# Environment:
#   DOT_SIGN_KEYCHAIN    keychain to use; default ~/Library/Keychains/login.keychain-db
#   KEYCHAIN_PASSWORD    optional; its keychain password, to skip the one-time
#                        key access prompt that codesign otherwise shows
#   DOT_P12_PASSWORD     optional; the passphrase for --backup and --import
#
set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# The identity name and its lifetime come from the one file every script shares.
# shellcheck source=scripts/config.sh
. "$PROJECT_DIR/scripts/config.sh"
# shellcheck source=scripts/signing.sh
. "$PROJECT_DIR/scripts/signing.sh"

IDENTITY="$SIGN_IDENTITY"
DAYS="$SIGN_IDENTITY_DAYS"
KEYCHAIN="${DOT_SIGN_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"

log() { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  awk 'NR > 2 && /^#/ { sub(/^# ?/, ""); print; next } NR > 2 { exit }' "${BASH_SOURCE[0]}"
}

# The passphrase for a .p12 this script reads or writes. It is never printed and
# never passed through a file: a prompt when there is a terminal, otherwise
# DOT_P12_PASSWORD, which is what the release workflow uses.
p12_password() {
  local prompt="$1" pass
  if [ -n "${DOT_P12_PASSWORD:-}" ]; then
    printf '%s' "$DOT_P12_PASSWORD"
    return 0
  fi
  [ -t 0 ] || die "$prompt needs DOT_P12_PASSWORD when there is no terminal"
  read -rsp "$prompt: " pass
  printf '\n' >&2
  [ -n "$pass" ] || die "the passphrase cannot be empty"
  printf '%s' "$pass"
}

certificate_pem() {
  security find-certificate -c "$IDENTITY" -p "$KEYCHAIN" 2>/dev/null || true
}

fingerprint() {
  local algorithm="$1"
  certificate_pem | openssl x509 -noout -fingerprint -"$algorithm" 2>/dev/null \
    | sed 's/^[^=]*=//' || true
}

print_details() {
  local sha1 sha256 enddate
  sha1="$(fingerprint sha1)"
  sha256="$(fingerprint sha256)"
  enddate="$(certificate_pem | openssl x509 -noout -enddate 2>/dev/null | sed 's/^notAfter=//' || true)"
  log "  identity: $IDENTITY"
  log "  keychain: $KEYCHAIN"
  log "  SHA-1:    $sha1"
  log "  SHA-256:  $sha256"
  log "  expires:  ${enddate:-unknown}"
  if [ -n "$sha1" ]; then
    log "  the designated requirement quotes the SHA-1 without its colons:"
    log "  certificate leaf = H\"$(printf '%s' "$sha1" | tr -d ':')\""
  fi
}

print_access_note() {
  log ""
  log "The first codesign run with this key shows one system dialog:"
  log "  \"codesign wants to use key '$IDENTITY' in your keychain\""
  log "Choose Always Allow. That dialog is macOS asking whether the codesign tool"
  log "may read the private key; it is not a trust setting, and this certificate"
  log "stays untrusted for everything except signing code with codesign."
  log ""
  log "To stop that dialog appearing on another Mac, add the key to that keychain's"
  log "partition list once. It needs the login keychain password:"
  log "  security set-key-partition-list -S apple-tool:,apple:,codesign: -l \"$IDENTITY\" -s -k <password> \"$KEYCHAIN\""
}

identity_exists() {
  dot_identity_installed "$IDENTITY"
}

create_identity() {
  local backup="${1:-}" pass
  umask 077
  # The working directory holds the private key until the identity is imported,
  # so it is made unreadable to everyone else, removed on any exit, and named in
  # a global because bash drops a function's locals before an EXIT trap runs.
  DOT_SIGNING_WORK="$(mktemp -d "${TMPDIR:-/tmp}/dot-signing.XXXXXX")"
  trap 'rm -rf -- "${DOT_SIGNING_WORK:-}"' EXIT
  local work="$DOT_SIGNING_WORK"

  # SHA-1 signs, not SHA-512: the designated requirement language supports the
  # SHA-1 of a certificate, which is what codesign records.
  log "creating a self-signed code-signing certificate valid for $DAYS days"
  openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days "$DAYS" \
    -keyout "$work/key.pem" -out "$work/cert.pem" \
    -subj "/CN=$IDENTITY" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1 \
    || die "openssl could not create the certificate"

  # The PBE and MAC algorithms are named instead of taken from the default:
  # OpenSSL 3 and later default to PBES2 with AES-256, which the Security
  # framework cannot import, while these three are read by both OpenSSL and the
  # LibreSSL that /usr/bin/openssl reports itself as.
  pass="$(openssl rand -hex 24)"
  openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" \
    -name "$IDENTITY" -out "$work/identity.p12" -passout pass:"$pass" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 >/dev/null 2>&1 \
    || die "openssl could not package the identity"

  log "importing it into $KEYCHAIN"
  # -T names the one program allowed to use the key without asking. -A is not
  # used: it would let any program on the machine read the key silently.
  security import "$work/identity.p12" -k "$KEYCHAIN" -P "$pass" \
    -T /usr/bin/codesign >/dev/null \
    || die "security import could not add the identity to $KEYCHAIN"

  if [ -n "${KEYCHAIN_PASSWORD:-}" ]; then
    if ! security set-key-partition-list -S apple-tool:,apple:,codesign: \
      -l "$IDENTITY" -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null 2>&1; then
      warn "could not set the key partition list; codesign may ask once for the key"
    fi
  fi

  identity_exists || die "the identity was imported but codesign cannot see it; check $KEYCHAIN"

  if [ -n "$backup" ]; then
    local backup_pass
    backup_pass="$(p12_password "Passphrase for $backup")"
    mkdir -p -- "$(dirname -- "$backup")"
    openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" \
      -name "$IDENTITY" -out "$backup" -passout pass:"$backup_pass" \
      -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
      || die "could not write $backup"
    chmod 600 "$backup"
    log "wrote a backup of the identity to $backup"
    log "Keep it out of the repository. Losing it means every person who installs"
    log "Dot has to grant the privacy permissions again after the next update."
  fi

  log ""
  log "created the identity. Builds signed with it keep their permissions."
  print_details
  print_access_note
  log ""
  log "An app that was ad-hoc signed before this change was granted its"
  log "permissions against its own hash, so grant microphone, Accessibility and"
  log "Automation once more on the first self-signed build. From then on the"
  log "grants survive updates."
}

import_identity() {
  local file="$1" pass
  [ -f "$file" ] || die "no such file: $file"
  if identity_exists; then
    log "the identity already exists; nothing to import."
    print_details
    return 0
  fi
  if security find-certificate -c "$IDENTITY" "$KEYCHAIN" >/dev/null 2>&1; then
    die "a certificate named \"$IDENTITY\" is already in $KEYCHAIN without a usable private key. Delete it in Keychain Access, or restore the .p12 that holds the key, rather than creating a second certificate with the same name."
  fi
  pass="$(p12_password "Passphrase for $file")"
  log "importing $file into $KEYCHAIN"
  security import "$file" -k "$KEYCHAIN" -P "$pass" -T /usr/bin/codesign >/dev/null \
    || die "security import could not read $file. Check the passphrase."
  if [ -n "${KEYCHAIN_PASSWORD:-}" ]; then
    security set-key-partition-list -S apple-tool:,apple:,codesign: \
      -l "$IDENTITY" -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null 2>&1 \
      || warn "could not set the key partition list; codesign may ask once for the key"
  fi
  identity_exists || die "the identity was imported but codesign cannot see it; check $KEYCHAIN"
  log "restored the identity"
  print_details
  print_access_note
}

MODE="create"
P12_FILE=""
case "${1:-}" in
  "") ;;
  --backup)
    MODE="backup"
    P12_FILE="${2:-}"
    [ -n "$P12_FILE" ] || die "--backup needs a file: $0 --backup ~/Documents/Dot-Self-Signed.p12"
    ;;
  --import)
    MODE="import"
    P12_FILE="${2:-}"
    [ -n "$P12_FILE" ] || die "--import needs a file: $0 --import ~/Documents/Dot-Self-Signed.p12"
    ;;
  --show) MODE="show" ;;
  -h|--help)
    usage
    exit 0
    ;;
  *) die "unknown argument: $1 (try --help)" ;;
esac

case "$MODE" in
  show)
    identity_exists || die "no identity named \"$IDENTITY\"; run $0 to create it"
    print_details
    ;;
  import) import_identity "$P12_FILE" ;;
  backup)
    if identity_exists; then
      die "the identity already exists, and its private key can no longer be exported with security(1): that command has no way to name one identity, so it would export every identity in $KEYCHAIN. Export it from Keychain Access instead: My Certificates, right-click \"$IDENTITY\", Export Items, format Personal Information Exchange (.p12)."
    fi
    create_identity "$P12_FILE"
    ;;
  create)
    if identity_exists; then
      log "the identity already exists; leaving it alone."
      print_details
      exit 0
    fi
    if security find-certificate -c "$IDENTITY" "$KEYCHAIN" >/dev/null 2>&1; then
      die "a certificate named \"$IDENTITY\" is in $KEYCHAIN but has no usable private key. Delete it in Keychain Access, or restore the .p12 that holds the key, rather than creating a second certificate with the same name."
    fi
    create_identity
    ;;
esac
