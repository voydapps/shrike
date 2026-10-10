# Shrike scripts

Shrike ships two ways, with no App Store and no Apple notarization:

1. **Local install** in `/Applications` on this Mac: `install-local.sh`.
2. **A downloadable DMG** for the website: `make-package.sh`.

Both sign with the **Apple Development** certificate (hardened runtime +
secure timestamp). If that certificate is not in the keychain, they fall
back to **ad-hoc** signing and print a warning, so they also work on
another Mac. The install steps for people are in the main `README.md` and in
the text file inside the DMG (`Scripts/dmg/How to open Shrike.txt`).

Requirements: macOS 14+, Xcode 26 (Swift 6), `brew install xcodegen`.
No `sudo`: `/Applications` is writable by admin users.

## `install-local.sh` — build and install into /Applications

```sh
Scripts/install-local.sh              # build, sign, verify, install
Scripts/install-local.sh --no-build   # re-install the last build
Scripts/install-local.sh --keep-old   # move the replaced app to the Trash
SHRIKE_INSTALL_DIR=~/Applications Scripts/install-local.sh   # other folder
```

What it does:

1. `xcodegen generate`, then `xcodebuild archive` of the **working tree**
   (uncommitted changes included): Release, arm64 + x86_64, stripped
   (~8 MB instead of ~16 MB). Build number = `git rev-list --count HEAD`.
   Xcode does not sign; the script signs once, explicitly (next step).
2. `codesign --options runtime --timestamp --entitlements
   App/Resources/Shrike.entitlements` (so no `get-task-allow`).
3. Checks, before anything in the destination is touched:
   `codesign --verify --deep --strict`, hardened runtime, certificate-based
   identity, timestamp, no `get-task-allow`, both architectures, app icon.
4. If Shrike is running **from the destination**, sends it SIGTERM (the
   same "sudden termination" macOS uses; no Automation prompt). Other copies
   (Xcode builds) are left alone. If it does not quit in 5 s, the script
   stops and changes nothing.
5. Copies the new app next to the old one (`.Shrike.app.new-<pid>`),
   verifies the copy, then renames it into place. If anything fails, the
   old app is put back.
6. `lsregister -f` on the installed app, and `lsregister -u` on stale Shrike
   builds (Xcode DerivedData, `.derived/`, `build/`, archives, temp dirs),
   so Finder's "Open With" does not pick an old Debug build.
   `--no-prune` skips this.

Environment: `SHRIKE_INSTALL_DIR` (default `/Applications`),
`SHRIKE_SIGN_IDENTITY` (SHA-1, name, or `adhoc`), `SHRIKE_WORK_DIR`
(default `build/local`). `SHRIKE_QUIT_MATCH_EXE` is a test hook only.

## `make-package.sh` — the website DMG

```sh
Scripts/make-package.sh               # dist/Shrike-<version>.dmg + .sha256
Scripts/make-package.sh 1.0           # same, but first checks the version
Scripts/make-package.sh --zip         # also dist/Shrike-<version>.zip
Scripts/make-package.sh --force       # overwrite an existing DMG
Scripts/make-package.sh --adhoc       # sign ad-hoc: the PUBLIC download (no name in the signature)
```

What it does:

1. Exports the **last commit** (`git archive HEAD`) into `build/package/src`.
   Uncommitted changes are never packaged; every DMG maps to one commit.
2. Version = `MARKETING_VERSION` in `project.yml`. An optional argument
   must match it. An existing DMG of the same version is kept unless
   `--force` is given.
3. Same build + sign + checks as `install-local.sh`. Here, signing without a
   secure timestamp (offline) is an error unless `SHRIKE_ALLOW_NO_TIMESTAMP=1`.
4. DMG contents: `Shrike.app`, an `Applications` shortcut, and
   `How to open Shrike.txt` (from `Scripts/dmg/`, `@VERSION@` filled in).
   Format ULMO (LZMA, needs macOS 10.15+; Shrike needs 14).
5. `hdiutil verify`, then mounts the image hidden from Finder
   (`-nobrowse`) and runs the same checks on the app inside it, plus an
   informational `spctl --assess` (expected: `rejected`, because the app
   is not notarized). Nothing is opened.
6. Writes `dist/Shrike-<version>.dmg` and `dist/Shrike-<version>.dmg.sha256`.
   Publish the checksum next to the download link.

## Public release (GitHub Actions)

`.github/workflows/release.yml` runs on a `v*` tag (the number must equal
`MARKETING_VERSION`, and the tag must be on `main`). It uses the `macos-26`
runner (Apple silicon, Xcode 26.4.1 selected), runs
`Scripts/make-package.sh --adhoc <version>`, and publishes a GitHub Release
made by `github-actions[bot]` with two files: `Shrike.dmg` and
`Shrike.dmg.sha256`. The stable name gives the permanent link
`https://github.com/voydapps/shrike/releases/latest/download/Shrike.dmg`.

The public DMG is signed ad-hoc on purpose: an Apple Development
certificate writes the developer's real name into the signature.
`verify_app` also fails the build when the binary contains the builder's
home folder or the repo path. (Swift cannot remap `#file` strings, so
`build_archive` puts DerivedData in a neutral `/tmp/shrike-dd.<pid>`
folder and deletes it afterwards.)

## Shared code

`lib/common.sh` holds the steps both scripts use: pick the signing
identity, build the archive, sign, verify, and the Launch Services helpers.
Change them there so the two scripts cannot drift apart.

Dependency pinning: `Packages/ShrikeKit/Package.resolved` is committed. Xcode
keeps its own copy inside the generated (git-ignored) `Shrike.xcodeproj`;
the scripts seed it from the committed file when it is missing and compare
the two after the build.

## Other files

| File | Purpose |
|---|---|
| `dmg/How to open Shrike.txt` | First-launch steps shown inside the DMG (macOS 14 / 15 / 26). |
| `generate-test-fixtures.swift` | Writes the small image fixtures for `ShrikeCoreTests`. |
| `make-icon.sh` | Builds the AppIcon PNGs from `Resources/Icon/shrike-icon*.svg`. |
| `generate-embedded-preview-fixture.py` | Writes the JPEG fixture with an embedded EXIF thumbnail (Pillow + piexif). |

## Troubleshooting

- **`xcodebuild archive failed`** — the script prints the `error:` lines;
  the full log is `build/local/build.log` (or `build/package/build.log`).
- **"no valid Apple Development certificate"** — the app is signed ad-hoc.
  It works, but macOS forgets folder permissions after each install.
  Fix: Xcode > Settings > Accounts > Manage Certificates > `+` > Apple
  Development. Check with `security find-identity -v -p codesigning`.
- **Plain `xcodebuild`** signs ad-hoc unless `Config/Local.xcconfig` exists
  (copy `Config/Local.xcconfig.example`; see the README).
- **"Shrike is still running"** — quit Shrike (Cmd-Q) and run again.
