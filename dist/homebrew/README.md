# The Homebrew tap for Dot

The site tells people to run:

```sh
brew install --cask anandlo/tap/dot
```

That command resolves to the GitHub repository **`anandlo/homebrew-tap`**, which
has to exist and to contain `Casks/dot.rb`. Until it does, the command fails
because Homebrew cannot find the tap. `Casks/dot.rb` in this directory is that
file.

It is tracked here so the stanza is version-controlled and reviewed with the code
it ships, and so this repository can never drift from what the tap publishes.

## What has to be true before the tap works

1. A GitHub release exists, tagged `v<VERSION>` (`v0.1.0-beta`, say), with
   `Dot-<VERSION>-arm64.dmg`, `Dot-<VERSION>-arm64.zip`, `SHA256SUMS`, and
   `dot.rb` attached.
2. `anandlo/homebrew-tap` exists and is public.
3. `anandlo/homebrew-tap`'s `Casks/dot.rb` carries the same `version` and
   `sha256` as the release asset. A cask whose checksum does not match its
   download cannot install.

## Publishing it, in order

**1. Cut the release.** The tag and `VERSION` have to agree, and `release.yml`
enforces that, so derive the tag from the file instead of typing it:

```sh
git tag "v$(cat VERSION)"
git push origin "v$(cat VERSION)"
```

The Release workflow runs `swift test --parallel` and `./scripts/release.sh`, then
attaches four files to the release. Wait for it to finish before going on; the
next step reads what it uploaded.

**2. Take the cask from the release, not from this directory.** This is the step
worth being pedantic about. `scripts/release.sh` renders `dot.rb` with the
checksum of the DMG *that machine built*. Run it on a laptop and you get the
checksum of a different artifact from the one the release published, byte for
byte. So the cask to publish is the one rendered on the runner and attached to
the release:

```sh
mkdir -p /tmp/dot-cask
gh release download "v$(cat VERSION)" --pattern dot.rb --dir /tmp/dot-cask
gh release download "v$(cat VERSION)" --pattern 'Dot-*.dmg' --dir /tmp/dot-cask
gh release download "v$(cat VERSION)" --pattern SHA256SUMS --dir /tmp/dot-cask
```

Confirm the three agree before publishing anything:

```sh
cd /tmp/dot-cask
shasum -a 256 -c SHA256SUMS                  # both artifacts are intact
grep '^  sha256' dot.rb                      # equals the DMG line in SHA256SUMS
grep '^  version' dot.rb                     # equals VERSION
```

If you ever have to rebuild the cask by hand — the release asset is missing, say
— the two volatile lines are the only ones to touch, and `scripts/release.sh` is
what writes them:

```sh
sha="$(awk '/\.dmg$/ { print $1 }' SHA256SUMS)"
sed -i '' -e "s/^  sha256 \".*\"$/  sha256 \"$sha\"/" dot.rb
sed -i '' -e "s/^  version \".*\"$/  version \"$(cat /path/to/dot/VERSION)\"/" dot.rb
```

**3. Create the tap repository.** Homebrew finds a tap by repository name, so it
has to be called `homebrew-tap` under the account the site names:

```sh
gh repo create anandlo/homebrew-tap --public \
  --description "Homebrew casks for anandlo's apps"
```

**4. Copy the release's cask into it and push.**

```sh
gh repo clone anandlo/homebrew-tap /tmp/homebrew-tap
mkdir -p /tmp/homebrew-tap/Casks
cp /tmp/dot-cask/dot.rb /tmp/homebrew-tap/Casks/dot.rb
cd /tmp/homebrew-tap
git add Casks/dot.rb
git commit -m "dot $(sed -n 's/^  version "\(.*\)"$/\1/p' Casks/dot.rb)"
git push origin HEAD
```

**5. Verify the exact command the site prints** — the string from the site, not a
local path and not a file argument:

```sh
brew trust --cask anandlo/tap/dot
brew audit --cask --online anandlo/tap/dot
brew install --cask anandlo/tap/dot
```

`brew trust` is not optional on Homebrew 7: until a third-party tap is trusted,
Homebrew refuses to even load the cask (`Refusing to load cask … from untrusted
tap`). Trusting the single cask rather than the whole tap keeps the permission as
narrow as it can be. `brew audit` downloads the release asset to compute its
checksum, so it only passes once the asset is public. A first install ends with an
ad-hoc signed app in `/Applications`. Homebrew does not bypass Gatekeeper and the
cask cannot make it: the first launch goes through **System Settings → Privacy &
Security → Open Anyway**, exactly as `README.md` describes.

**6. Uninstall, including the leftovers.**

```sh
brew uninstall --cask dot          # removes /Applications/Dot.app
brew uninstall --cask --zap dot    # also the config, logs and the agent
```

## Later releases

Each release repeats steps 1, 2, and 4. `version` and `sha256` change and the
rendered `Casks/dot.rb` is pushed to the tap. Nothing else in the file should
ever need editing — `url` is built from the version, so it follows on its own.

A `-beta` version is still installable from the tap. Homebrew follows the URL, so
a release GitHub marks as a prerelease installs exactly like a stable one; the
prerelease flag only changes what `releases/latest` returns.

## What is deliberately not in the cask

- **No `quarantine` stanza.** Homebrew 7 removed `--no-quarantine` and calls
  `quarantine()` on every cask download unconditionally, with no cask-side way
  out. A stanza claiming otherwise would be false.
- **No `postflight` that strips `com.apple.quarantine`.** The quarantine
  attribute is a Gatekeeper signal, and the Homebrew maintainers reject casks
  that clear it. Letting the app in is the user's decision, made on the Security
  settings pane, and `README.md` says so.
- **No `livecheck` block.** Not needed: `version` is written by
  `scripts/release.sh` from `VERSION` at release time, which is more accurate
  than guessing from the release page.
- **No `verified:` on the `url`.** Homebrew 7 deprecates the parameter and warns
  on every load ("Use the default URL verification behaviour instead"); the URL
  verification it replaced is now the default.
