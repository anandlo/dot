# Fonts

Dot is set in Switzer, designed by the Indian Type Foundry and published on
[Fontshare](https://www.fontshare.com/fonts/switzer).

Switzer is free for personal and commercial use and may be embedded in a desktop
application. The ITF Free Font License forbids redistributing the font files, so
they are not in this repository: `.gitignore` excludes every `.ttf` here and
`scripts/fetch-fonts.sh` is how a working copy gets the file. `scripts/build.sh`
copies whatever it finds in this directory into `Dot.app/Contents/Resources/Fonts`
and declares that directory as `ATSApplicationFontsPath`, so macOS registers the
face at launch.

The app asks for the variable file and sets the weight axis directly, because
one file carries the whole axis (100 to 900) and the static files would register
as separate families rather than as one family with weights. The file's default
instance is Regular, so the weights the app draws are variations on top of it.

The file this build was measured against is
`Switzer-Variable.ttf`, sha256
`373c2d2ad8f1f811ca58ae725e9591db2e72cf726dc6e8066cd7f64b4c283cdf`.
`scripts/fetch-fonts.sh` refuses a file with any other hash: a different file
means the foundry republished the family and the app's metrics have to be
looked at again rather than the new file taken on trust.

Without the file the app still builds and runs: every surface falls back to the
system face, which is also what the test suite reads, since xctest has no app
bundle to load fonts from.

What the licence allows and what it does not:

- Embedding the face in the licensee's own application is allowed, which is why
  the build script copies it into `Dot.app` and the app ships with it.
- Redistributing the font files on their own is not, and neither is serving them
  from a public repository, which is why the file is fetched instead of
  committed and why `.gitignore` keeps every `.ttf` out of the history.

Licence: <https://www.fontshare.com/licenses/itf-free-font-license>
