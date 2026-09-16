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

## Distribution (notarization)

Release builds currently sign with **Apple Development** for local run. For a shareable zip/DMG you need a **Developer ID Application** certificate, then:

```bash
# After archiving / exporting a Developer ID–signed .app:
xcrun notarytool submit Grabbit.zip --keychain-profile "AC_PASSWORD" --wait
xcrun stapler staple Grabbit.app
```

Friends can still run a Development-signed build from Xcode / `make run` on this Mac.
