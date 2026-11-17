# Fonts

Dot is set in Satoshi, designed by Deni Anggara for the Indian Type Foundry and
published on [Fontshare](https://www.fontshare.com/fonts/satoshi).

Satoshi is free for personal and commercial use and may be embedded in a desktop
application: section 01 of the ITF Free Font License grants use "in any media,
including Print, Websites, Mobile or Desktop Applications" and says "You may
embed the Font Software in mobile or desktop applications and digital documents
for the uses permitted under this License." The same licence forbids
redistributing the font files and forbids modifying them. Section 02 names a
"repository" and "publicly accessible servers" among the places the files may
not be made available, and it forbids modification in terms that name
"subsetting, format conversion, or altering font names, copyright information,
ownership information or other metadata"; section 05 forbids a derivative work
without the licensor's written consent.

That is why the file is not in this repository: `.gitignore` excludes every
`.ttf` here and `scripts/fetch-fonts.sh` is how a working copy gets it, and why
the app imports the file exactly as the foundry ships it, with no subsetting and
no format conversion. `scripts/build.sh` copies whatever it finds in this
directory into `Dot.app/Contents/Resources/Fonts` and declares that directory as
`ATSApplicationFontsPath`, so macOS registers the face at launch.

The app asks for the variable upright file and sets the weight axis directly,
because one file carries the whole axis (300 to 900) and the static files would
register as separate families rather than as one family with weights. The file's
default instance is Black, the top of the axis, so a resolution that did not set
the axis would draw the heaviest face in the family; every resolution sets it.

The file this build was measured against is `Satoshi-Variable.ttf`, sha256
`02ad131926aa46d282b6af73ad2bcaecb0ec6ef3b830a2f08dcabef44f1140ff`.
`scripts/fetch-fonts.sh` refuses a file with any other hash: a different file
means the foundry republished the family and the app's metrics have to be
looked at again rather than the new file taken on trust. A second run over an
intact file does nothing.

Without the file the app still builds and runs: every surface falls back to the
system face, which is also what a checkout without the file reads in the test
suite, since xctest has no app bundle to load fonts from.

Licence: <https://www.fontshare.com/licenses/itf-free-font-license>
(the site's own navigation links the same document as
<https://www.fontshare.com/licenses/itf-ffl>).
