# Grabbit

A free, native macOS capture tool — screenshots, screen recording, FigJam-style annotations, and a Capture Library with Auto Organize.

**Requirements:** macOS 13.0 (Ventura) or later · Xcode 15+

## Build & run

```bash
make run
```

Or open `Grabbit.xcodeproj` in Xcode and run the **Grabbit** scheme.

The app is menu-bar only (`LSUIElement`) — look for the rabbit icon in the status bar.

## Permissions

On first launch, Grabbit walks you through:

1. **Screen Recording** — capture screenshots and recordings
2. **Accessibility** — global keyboard shortcuts from any app
3. **Save folder** — where captures are written (change later in Settings)

## Default shortcuts

| Shortcut | Action |
|----------|--------|
| ⌘⇧3 | Grab full screen |
| ⌘⇧4 | Grab region |
| ⌘⇧5 | Capture Bar |
| ⌘7 | Show All (Capture Library) |
| ⌘, | Settings |

## Version

Current marketing version: **0.1** (library-ready).

## Distribution (DMG + GitHub Releases)

Release builds for sharing need a **Developer ID Application** certificate. Local `make run` can stay on Apple Development.

### 1. Sign, notarize, and staple the `.app`

```bash
# After archiving / exporting a Developer ID–signed .app:
xcrun notarytool submit Grabbit.zip --keychain-profile "AC_PASSWORD" --wait
xcrun stapler staple Grabbit.app
```

### 2. Build the installer DMG

Requires [create-dmg](https://github.com/create-dmg/create-dmg) (`brew install create-dmg`).

```bash
make dmg RELEASE_APP=/path/to/stapled/Grabbit.app
# defaults to ./Grabbit.app if present
```

This writes `dist/Grabbit.dmg` with a drag-to-Applications window. It does **not** notarize.

### 3. Notarize and staple the DMG

```bash
xcrun notarytool submit dist/Grabbit.dmg --keychain-profile "AC_PASSWORD" --wait
xcrun stapler staple dist/Grabbit.dmg
spctl --assess --type open --context context:primary-signature -v dist/Grabbit.dmg
```

### 4. Publish a GitHub Release

Repo must be **public** (or release assets won’t download anonymously). Install/auth `gh` once: `brew install gh && gh auth login`.

```bash
make release TAG=v0.1.0
```

Keep the asset name **`Grabbit.dmg`** every release. Stable download URL for your site:

```text
https://github.com/ethanwatsonj/Grabbbit/releases/latest/download/Grabbit.dmg
```

Friends can still run a Development-signed build from Xcode / `make run` on this Mac.
