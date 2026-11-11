# The cask for anandlo/homebrew-tap. This copy is the template the project
# repository tracks, so the stanza is version-controlled and reviewable next to
# the code it ships. The published copy is the one `scripts/release.sh` renders
# into build/release/homebrew/Casks/dot.rb and attaches to the release: it is
# identical to this file except for the two volatile lines below, which the
# script rewrites from VERSION and from the checksum of the DMG that build
# produced. A checksum belongs to one set of bytes, so a script cannot render it
# here without lying about artifacts built elsewhere — hence the placeholder.
#
# There is deliberately no `quarantine` stanza and no `postflight`: Homebrew
# calls `quarantine()` on every cask download and offers no way to skip it, so a
# stanza here would either do nothing or be rejected in review. Dot is ad-hoc
# signed and not notarized, so the first launch goes through
# System Settings → Privacy & Security → Open Anyway. That is documented in
# README.md, which is the only supported route.
cask "dot" do
  version "0.1.0-beta"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/anandlo/dot/releases/download/v#{version}/Dot-#{version}-arm64.dmg"
  name "Dot"
  desc "Push-to-talk voice dictation"
  homepage "https://dot.anandlo.com/"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Dot.app"

  zap trash: [
    "~/Library/Application Support/Dot",
    "~/Library/Caches/com.anandlo.dot",
    "~/Library/LaunchAgents/com.anandlo.dot.plist",
    "~/Library/Logs/Dot",
    "~/Library/Preferences/com.anandlo.dot.plist",
    "~/Library/Saved Application State/com.anandlo.dot.savedState",
  ]
end
