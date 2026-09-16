# Grabbit — Product Planning

## What you're building

A free, native-feeling macOS capture tool. Screenshots, screen recording, FigJam-style annotations, and a passive voice log with retroactive "clip that" capture. Positioned against CleanShot X (too bloated), Shottr (no recording, not beautiful), and Xnapper (incomplete).

**Free. No paywall.**

---

## Locked Decisions

| Decision | Choice |
|----------|--------|
| **App name** | Grabbit |
| **Bundle ID** | com.ethanwatson.grabbit |
| **Min macOS** | 13.0 (Ventura) |
| **Distribution** | Direct (not App Store) |
| **Pricing** | Free |
| **Save location** | User picks a root folder during onboarding; every capture lands there flat — no folder suggestion or move happens at capture time (see Capture Library — Finder Sync below) |
| **Organize approach** | **Pivoted 2026-07-11:** no real-time/toast-time folder suggestion. Organizing is a deliberate, post-capture pass that lives in the Capture Library window — rename suggestions, project tagging, and move-into-project, all reviewed/applied by the user, never automatic |
| **Capture Library** | Becomes a live, two-way view of the actual save-folder tree on disk, not a capped 200-item cache — folders and files shown match Finder exactly, and changes made in either place reflect in the other |
| **Default output** | Auto-copy to clipboard + save to folder + toast preview |
| **Toast behavior** | Click toast → opens annotation window |
| **Recording audio** | Screen only by default; mic opt-in; system audio opt-in |
| **Voice transcription** | Skip for now — audio file only |
| **Command bar hotkey** | ⌘6 / ⌘7 (default, fully remappable like Shottr) |
| **Menu bar** | Yes — no Dock icon, lives entirely in menu bar |

---

## Differentiator

| Competitor | Problem |
|------------|---------|
| macOS native | No recording, no annotations, no sharing |
| Shottr | No recording, functional but not beautiful |
| CleanShot X | Bloated, dated UI, subscription creeping in |
| Xnapper | Beautiful but incomplete, no recording |

**Grabbit sits at the intersection nobody owns:** native-feeling, lightweight, genuinely beautiful, complete (screenshots + recording + voice), with annotations that don't get in the way — and a command bar no competitor has.

---

## Priority Use Cases & Competitive Positioning (2026-07-04)

**Use cases Grabbit is built for, in priority order:**

| # | Use case | What it needs from annotation |
|---|----------|-------------------------------|
| 1 | Bug reports / QA feedback | Precise pointing at the broken element, redaction of sensitive data, fast |
| 2 | Design/UX feedback | Text anchored to an exact region ("increase width to 150px"), often several comments per screenshot |
| 3 | Marketing / external sharing | Polished, on-brand, clean output for public posting |

Deprioritized for now: tutorial/step-by-step documentation (needs numbered step badges, a different primitive) and fast text-less support replies.

**Competitors tracked most closely, in priority order:**

| Competitor | Relevance | Their answer to "focus attention" |
|---|---|---|
| CleanShot X | Closest direct competitor — same category (Mac screenshot annotation), same target user | Dedicated Spotlight tool (dim outside a region) + separate Highlight tool. The bar to beat. |
| Loom | Reference point for the recording side, not annotation | Live cursor-follow spotlight during recording only — doesn't apply to static capture, not a real competitor on this feature |
| FigJam | Reference point for whiteboard-style annotation UX (hover-based tool appearance, bendable connectors) | No dedicated tool — "draw a generic shape yourself." This is the gap Grabbit's Spotlight tool fills in the screenshot category |

**Design decisions this produced:**
- No dedicated rigid arrow-only primitive. Explain-focused use cases (2, part of 1) are served by anchored text/callouts; point-focused use cases (1, 3) are served by Rectangle/Highlighter (circle-the-region) plus the new Spotlight tool below — arrow semantics (directional pointing) weren't actually the load-bearing need once the three use cases were made explicit.
- Spotlight ships with all three suppression techniques (dim / blur / desaturate) as a per-annotation setting rather than picking one — precision-first use cases (1, 2) favor Dim + hard edge; polish-first use case (3) is the one place Blur or Desaturate earn their extra cost.

---

## MVP Scope & Use Cases (2026-07-05)

**Who's using it:** designers, engineers, marketing, and product people who need to show or explain a digital product or their own work to someone else.

**Top two use cases, in priority order:**

| # | Use case | Shape |
|---|----------|-------|
| 1 | "Hey, look at this" | Show a tool, feature, or piece of work — screenshot/recording is the point |
| 2 | "This is why X" | Explain a decision or reasoning — sometimes just text, screenshot is supporting evidence |

**Format:** Both use cases apply to screenshots and recordings, but **MVP is screenshot-first** — recording keeps working (already built through v0.6) but isn't the MVP gate.

**Two flagship features for v1.0 MVP:**
1. The screenshot → annotate → share loop above.
2. **Capture Library — Finder Sync** *(pivoted 2026-07-11 from real-time Dynamic Save Location / Auto-Organize)* — instead of guessing a folder at capture time, the Capture Library window becomes a live, two-way mirror of the save folder on disk, with rename suggestions, project tagging, and move-into-project handled there as a deliberate post-capture pass. Full spec below.

**Deprioritized for MVP, not off the table:** background images and other secondary capture/output tools (open to adding more here post-MVP).

This sits above the annotation-need breakdown in "Priority Use Cases & Competitive Positioning" above — that section is about what a screenshot needs once you're in it (precise pointing, anchored text, polish); this section is about who's opening Grabbit and why in the first place. The two aren't in conflict: bug reports/QA and design feedback are both flavors of "hey, look at this."

---

## Hotkeys (Shottr-style; remappable later)

| Action | Default |
|--------|---------|
| Full screen screenshot | ⌘⇧3 |
| Region screenshot | ⌘⇧4 |
| Capture Bar | ⌘⇧5 |
| Open Capture Library | ⌘7 |

All hotkeys are shown in Settings (read-only for v0.1). Remappable hotkeys are post-v0.1.

> **Current code (2026-09):** `GrabbitApp.swift` registers ⌘⇧3 (full screen), ⌘⇧4 (region), ⌘⇧5 (Capture Bar), and ⌘7 (library). Window capture remains available from the Capture Bar. Clip That and Command Bar are post-v1.

---

## Capture Bar (current, ⌘6)

Visual icon panel triggered by ⌘6. Seven capture modes split across screenshot and recording groups, with camera/mic/system-audio/background toggles and a Capture button. Built as a floating `NSPanel`.

---

## Command Bar (future, ⌘6 or separate hotkey)

Spotlight-style text panel that coexists with or replaces the visual Capture Bar for power users. The idea: press the hotkey, type a short command, hit Return.

**Commands:**

| Input | Action |
|-------|--------|
| `region` | Region screenshot |
| `window` | Window picker |
| `full` | Full screen screenshot |
| `record` | Start/stop recording |
| `record window` | Window recording |
| `record region` | Region recording |
| `clip` | Clip last 60s of voice |
| `clip 30` | Clip last 30s |
| `timer 5` | 5s countdown then capture |
| `history` | Open capture library |
| `cam off` | Disable camera overlay |
| `mic on` / `mic off` | Toggle mic |

**UX design:**
- Borderless `NSPanel`, ~440px wide, centered top-quarter of screen (not bottom like the visual bar)
- Single `NSTextField` with a filtered results list below (max 5 results)
- Results update on each keystroke, first result auto-highlighted
- Return fires the top result; arrow keys navigate; Escape dismisses
- Each result row: icon (SF Symbol) + command name + keyboard shortcut if any
- Partial matching: typing `rec` surfaces `record`, `record window`, `record region`
- History of last 3 used commands surfaced when the field is empty

**Implementation notes:**
- Separate from `CaptureBar` — both can exist; Command Bar is an opt-in power-user layer
- Commands are a static array of `CommandEntry` structs with a name, aliases, SF symbol, and action closure
- Fuzzy match on name + aliases using simple `contains` or `levenshtein` threshold
- Close after any action fires (same as Escape)
- `CommandBar.swift` — new file, no dependency on `CaptureBar`

**Open question:** does ⌘6 toggle between the two, or does Command Bar get its own hotkey (e.g. ⌘Space-style with a user-defined key)?

---

## Post-Capture Flow

1. Capture fires (screenshot or clip)
2. File auto-saved to user's chosen root folder (never blocks on analysis — see Dynamic Save Location below)
3. Image auto-copied to clipboard
4. On-device analysis runs in the background and, if confident, attaches a suggested destination to the toast
5. Toast appears bottom-right (thumbnail + filename + suggested-folder chip if one was found, 4s timeout — extends slightly if a chip is showing so it isn't missed)
6. Clicking the thumbnail → opens Annotation Window. Clicking the folder chip → moves the file into the suggested (sub)folder, creating it if needed
7. Annotation Window: full capture with floating toolbar, FigJam-style
8. Escape or ✓ button → copies annotated version to clipboard, dismisses

---

## Dynamic Save Location (Auto-Organize)

> **⚠️ Superseded 2026-07-11 — see "Capture Library — Finder Sync" below.** Real-time, capture-time folder suggestion is being dropped. Reasoning: the analysis only ever gets one shot, taken under time pressure, off a `WindowSignature` snapshot grabbed the instant the capture fires — thin signal, and it sits in the critical path of the app's fastest, most-used loop (snip → annotate → ship). A deliberate pass *after* capture gets richer signal (multiple captures reviewed together, full image content, no latency budget) without ever risking the annotate/share flow. Everything below this point is kept as a historical record of what was built and why it didn't stick — none of it is being ripped out (the mapping cache, `moveCapture`, `CaptureDestination` model all get reused by the new approach), it's just no longer wired to fire automatically at save time.

**Concept:** instead of every capture landing in one flat folder, Grabbit figures out *what product or tool* a capture is of and proposes a home for it — a top-level folder per product, nested and reused automatically as more captures come in. The goal: someone doing "screenshot everything I look at across a dozen tools" ends up with a self-sorting folder tree instead of a junk drawer, without ever opening Finder.

**Priority:** MVP, alongside the screenshot-first flow — this is the second flagship feature for v1.0, not a post-launch nice-to-have.

**Analysis approach — on-device only, no cloud calls, nothing leaves the Mac. Fully rule-based and deterministic — no LLM tier (removed 2026-07-08, see reworked note below):**
- **Primary signal — app/window metadata (free, deterministic):** at capture time, read the frontmost app's bundle identifier and window title (ScreenCaptureKit / Accessibility APIs already have this). "Figma," "Google Chrome — Linear," "Xcode" are strong, reliable product names with zero image analysis needed.
- **Project signal — resolved project/tab name:** for Xcode/JetBrains-style editors, walk the open document's directory up to the nearest `.xcodeproj`/`.xcworkspace`/`.git` ancestor; for Safari/Chrome/Brave/Edge/Arc, ask the browser for its active tab's URL via AppleScript and derive a folder name from the domain + path (e.g. `github.com/you/repo` → "GitHub - repo"). Falls back to window-title parsing when neither is available.
- **Secondary signal — Vision framework OCR (on-device):** run text recognition on the captured image to pull page/section names, headings, or button labels visible on screen (e.g. "Design System," "Settings," "Pricing"). Used to propose a *subfolder* under the primary product folder, and to disambiguate generic window titles (e.g. a browser tab titled "New Tab").
- **Fallback chain (never blocks, never errors visibly):**
  1. Mapping cache hit → reuse the previously confirmed folder.
  2. Resolved project/tab name (Xcode project, browser tab URL) → use it directly.
  3. Rule-based app-metadata + window-title + OCR matching.
  4. Neither signal resolves anything usable (e.g. full-screen capture spanning apps, empty OCR, ambiguous title) → **drop the file into the user's root save folder untouched, no chip shown.** This is the same behavior as today's flat save — auto-organize is additive, never a blocker, and a failed analysis should be indistinguishable from the feature not existing.
- No CoreML classifier and no local LLM needed — app metadata + resolved project/tab name + OCR text covers "what product" and "what part of it" deterministically and instantly, with no "loading" wait.

**Behavior (suggest, user confirms):**
1. File saves immediately to the root folder the user picked in onboarding — capture speed never waits on analysis.
2. Analysis runs in the background (should resolve well within the toast's visible window).
3. If confident, the toast grows a folder chip: `→ Figma / Design System`. Tapping it creates the folder path if it doesn't exist and moves the file there.
4. If the user ignores the chip, the file simply stays where it landed — nothing is silently moved without a tap.
5. Confirmed product → folder mappings are remembered (same "recents" pattern as stroke color / Spotlight technique), so the same app/window-title pattern gets suggested consistently next time without needing OCR to re-confirm it.
6. Folder tree grows organically: `<root>/Figma/Design System/`, `<root>/Chrome — github.com/`, etc. — created on demand, never pre-generated.

**Scope:** applies to both screenshots and recordings (same capture pipeline, same metadata available at capture time) — screenshots remain the priority surface to polish first, but there's no separate implementation needed to cover recordings once this ships.

> **⚠️ Bug found and fixed (2026-07-07), confirmed working:** initial debug testing showed region captures always classifying as Grabbit itself, regardless of what was actually on screen (e.g. an Xcode capture came back `bundleID: "ewew.design.Grabbit"`, `windowTitle: nil`). Root cause: `CaptureClassifier.gatherWindowInfo()` was being called from `finishScreenshot`/`takeScreenshot`'s completion closures, i.e. *after* `RegionSelector`/`CaptureBar` had already called `NSApp.activate`/`makeKeyAndOrderFront` — by then `NSWorkspace.shared.frontmostApplication` correctly but uselessly reports Grabbit's own panel, not the app the user was actually looking at. Fixed by capturing `WindowSignature` at the earliest possible point in each flow — top of `CaptureBar.show()` (stored in new `CaptureBar.capturedWindowInfo`) and top of `GrabbitApp.takeScreenshot()` — before any Grabbit UI takes focus, then threading that captured value through to the `classify` call instead of re-reading frontmost app after capture completes. **Verified against a real build via the debug-print hook — working as intended.**
>
> **Follow-up shipped:** `CaptureClassifier` now also resolves, for region/full-screen captures spanning multiple windows, which app occupies the most area of the captured rect (`dominantAppBundleID`/`dominantAppName`, via on-screen window geometry intersected against the final capture rect, excluding Grabbit's own overlay windows) and a specific project name for that app (`resolvedProjectName`, via `kAXDocumentAttribute` → nearest `.xcodeproj`/`.xcworkspace`/`.git` ancestor, falling back to window-title parsing, falling back to OCR heading extraction). Both signals fed the Foundation Models prompt and the Tier 2 rules directly. Confirmed working via the extended debug print.
>
> **Reworked (2026-07-08):** the Foundation Models tier was cut entirely — project resolution needs to be instant and deterministic, not something that "loads." `CaptureClassifier` is now a single rule-based pass: mapping cache → `resolvedProjectName` (see below) → window-title parsing → OCR heading extraction → dominant app name → nil. Also added real browser-tab resolution: for Safari, Chrome, Brave, Edge, and Arc, `resolveProjectName` now asks the browser for its active tab's URL via a one-line AppleScript (`resolveBrowserProjectName`/`runAppleScript` in `CaptureClassifier.swift`) instead of parsing the window title text. The URL's host + first path segment(s) are turned into a folder name via `projectName(fromHost:path:)` — e.g. `github.com/you/repo` → "GitHub - repo", `linear.app/acme/issue/...` → "Linear - acme", unrecognized hosts fall back to a capitalized domain label, `localhost`/`127.0.0.1` → "Localhost". Requires one-time Automation permission (new `NSAppleEventsUsageDescription` in the Xcode build settings); if the user hasn't granted it yet, or the AppleScript fails for any reason, resolution silently falls back to window-title parsing exactly as before — never blocks, never errors visibly. `CaptureDestination.Source.localLLM` is kept as an enum case only so any previously-cached `mappings.json` entries still decode.

**Data model:** `CaptureDestination { productFolder: String, subfolder: String?, confidence: Double, source: .windowMetadata | .ocr | .localLLM }` (`.localLLM` kept only so old cached mappings still decode; nothing produces it anymore). A small on-disk mapping cache (`[WindowSignature: CaptureDestination]`) backs the "remembered" behavior in step 5 — once rules resolve a mapping, it's reused without re-running inference.

**Open questions:**
- Whether "no confident answer" should still drop a silent file in the root folder (current lean, see fallback chain above) vs. showing an explicit "Unsorted" folder chip — leaning toward silent root-drop so a cold/unavailable model never degrades the base experience.
- Whether the folder-chip mapping cache should be editable/visible in Settings (a simple list of "Figma → Design System" rules the user can rename or delete).
- Latency budget for the LLM tier — needs to resolve within the toast's visible window (~4s) or the chip should simply not appear rather than appearing late.

---

## Capture Library — Finder Sync (Post-Capture Organize)

**Added 2026-07-11**, replacing the real-time Auto-Organize toast chip above as flagship feature #2.

**Concept:** the Capture Library window (`CaptureLibraryWindow.swift`) stops being a capped 200-item "recents" cache and becomes a live, two-way mirror of the actual save-folder tree on disk. What you see in the library sidebar is exactly what's in Finder at the root folder you picked in onboarding — same folders, same files, same names — because it's reading (and writing) the same files Finder is, not a separate index. Organizing a capture into a project happens here, deliberately, after the fact — never automatically at save time.

**Why here, not at capture time:** captures already save as real PNG/MP4 files under `AppSettings.destinationFolderURL`, and `CaptureHistory` already does real `FileManager` moves and renames when a capture is organized or renamed. There's only one copy of the data — the library window just needs to read the same directory tree Finder reads, live, instead of relying on its own capped manifest.

**Three things the library adds:**
1. **Suggested renames** — for captures still sitting on their default `Grabbit YYYY-MM-DD HH-mm-ss` name, the library can propose a more descriptive name (derived from window/project signal already captured, or an image-content pass — see Analysis approach below). Shown inline per-item or as a batch review list; user accepts, edits, or dismisses each suggestion. Nothing renames itself.
2. **Project tagging** — a capture (or a multi-select batch) can be tagged with a project name. Tags are just the folder-mapping concept already built (`CaptureDestination`, `CaptureDestinationMappingCache`) surfaced as an explicit user action instead of an inferred toast chip.
3. **Reorganize / move into project** — drag-and-drop within the library, or "move selected to…" on a batch, moves the underlying files into a project folder (created on demand under the root), reusing `AutoOrganizer.moveCapture` / `CaptureHistory.moveCapture`, which already do this via real `FileManager` operations.

**What "Finder sync" requires, concretely (none of this is a rewrite, all additive):**
- **Live directory scan** — walk the actual save-folder tree instead of relying solely on the 200-item manifest, so folders/files added or moved outside Grabbit (i.e. directly in Finder) show up.
- **Filesystem watcher (FSEvents)** — so changes made in real Finder while the library is open update live, and changes made in the library appear instantly in Finder. This is the actual "sync" — there's no separate store to reconcile, just one filesystem being watched from both sides.
- **Tree/outline UI** — the sidebar's flat `List` becomes a folder-aware `OutlineGroup`/tree view (still `NavigationSplitView`-based), so project folders and their contents are browsable, not just a flat recency-sorted list.
- **Reconciling the manifest with the scan** — files that exist on disk but were never added via `CaptureHistory.add` (e.g. moved in from Finder, or from before the cache trimmed them) need a path, not just an id, as their identity — so the tree view can show them even without a manifest entry.

**Analysis approach — open question, not locked:** what powers rename suggestions and project-tag suggestions. Since this no longer needs to resolve instantly (it's not blocking a toast anymore), a real model tier is back on the table, discussed but not decided:
- **Apple Intelligence (Foundation Models framework, WWDC 2026)** — now supports multimodal prompts (image input) fully on-device, plus Vision-backed OCR tools. Free, private, no network, no key management — the natural fit given `CaptureClassifier` already leans on on-device Vision OCR. Gated on Apple Intelligence–capable hardware + a very recent OS; likely still stabilizing post-WWDC26 as of this writing.
- **BYOK cloud fallback for everyone else** — never bundle a developer-paid API key (unbounded per-user cost for a free app with no billing infrastructure). If cloud analysis is offered, user supplies their own key. Gemini's free tier covers image understanding with generous limits (not just Flash generation) and is a reasonable free default; Claude API sits alongside as a paid, higher-quality option for users who want it.
- Whichever tier resolves it, output is always a *suggestion* surfaced in the library, never applied without a tap — same "suggest, user confirms" principle as the original Auto-Organize spec, just relocated from the toast to the library.

**Data model / plumbing reused as-is:** `CaptureDestination`, `CaptureDestinationMappingCache`, `AutoOrganizer.moveCapture`, `CaptureHistory.moveCapture`/`renameCapture` — all already do exactly what this needs; the change is *when* and *where* they're invoked (user-driven, in the library) rather than *what* they do.

**Open questions:**
- Batch review UI shape — a dedicated "review suggestions" pane/sheet vs. inline affordances per row in the tree.
- Whether project tags are strictly folder-based (tag = folder, matching today's model) or a separate lighter-weight tag that doesn't require a move — leaning folder-based for v1 since it maps directly to what already exists.
- Which analysis tier ships first — likely start with the existing deterministic on-device signal (reuse of `CaptureClassifier`, just repointed at "suggest" instead of "auto-apply at save"), with Apple Intelligence / BYOK cloud layered in once the Finder-sync UI itself is solid.

---

## Annotation Design (FigJam-inspired)

**Principles:** tool appears near cursor, not in a distant toolbar. Switch modes with single key presses. Stroke weight and color follow recents.

| Key | Tool |
|-----|------|
| M | Marker (freehand) |
| H | Highlighter |
| A | Arrow |
| R | Rectangle |
| T | Text label |
| N | Number stamp (①②③) |
| B | Blur / redact |
| F | Focus / Spotlight |
| Cmd+Z | Undo |
| Escape | Finish + copy |

8 curated colors, no custom color picker in v1. No layers. No fill options. The goal is 10 seconds from capture to annotated clipboard.

---

## Bendable Arrow Tool (FigJam-style elbow)

Arrow starts as a straight line (unchanged default behavior). When selected, it shows a handle at its midpoint that can be dragged to bend the line into two straight segments with a soft rounded joint — same idea as FigJam's connector bend, minus auto-routing (this is Option 1 from the arrow-tool exploration: fixed single bend, user-controlled, not a full multi-point polyline).

**Behavior:**
- Default: straight `from → to`, arrowhead at `to` — same as today.
- Select tool: a draggable handle appears at the current bend point (or the line's midpoint if no bend yet).
- Dragging that handle creates/moves the bend; line becomes `from → bend → to` with a rounded corner.
- Double-click the arrow (or its bend handle) → clears the bend, snaps back to straight.
- Endpoint dragging (start/end) and tip style behavior are unchanged.

**Data model:** `Annotation.arrow` gains an optional `bend: CGPoint?` (`nil` = straight, current behavior).

- [x] Implement in `AnnotationWindow.swift` — done. `arrowBendHandle`, `appendArrowShaft`, and the drag-handle/rounded-joint/double-click-to-reset behavior are all in place and match this spec exactly.

---

## Focus / Spotlight Tool

Draws attention to a region without a pointer or text — the "hey, look over here" tool identified as the gap in FigJam/Miro/draw.io (generic shapes only, no dedicated tool) and matched against CleanShot X (has it, the bar to beat). Same drag-to-define interaction as Rectangle (`R`) and `RegionSelector`; press `F`, drag out the region, release.

**Behavior:**
- On release, the floating pill toolbar shows a 3-icon technique picker (Dim / Blur / Desaturate) in place of the color swatches
- Default technique: **Dim** — cheapest to render, matches CleanShot X's baseline, best fit for the two precision-first use cases (bug reports, design feedback)
- Region renders as a rounded rectangle with a **hard-edge cutout** — no feather/vignette in v1. Precision beats polish for 2 of the 3 priority use cases; the one case where a soft edge would help (marketing) isn't worth the added rendering complexity yet
- Last technique used is remembered for the next Spotlight annotation (same "recents" principle already used for stroke weight/color)
- Selecting a placed Spotlight annotation shows the same drag-handle bounding box as the `S` select tool, for resize/reposition
- Switching technique on an existing annotation re-renders live — no redraw needed
- Escape / ✓ commits like every other tool

**Data model:** `Annotation.spotlight` — `region: CGRect`, `technique: SpotlightTechnique` (`.dim | .blur | .desaturate`), fixed `cornerRadius` (not user-exposed in v1)

**Rendering — all three lean on the GPU-backed `CIContext` pipeline already used for camera-bubble compositing (`RecordingBackgroundRenderer`/`ShipItPanel`), no new pipeline needed:**
- **Dim**: ~45% black overlay composited everywhere outside `region` (clip-invert mask)
- **Blur**: `CIGaussianBlur` on a full-image copy; sharp original composited back in only inside `region`
- **Desaturate**: `CIColorControls` with `saturation: 0` applied outside `region`, full color preserved inside

Not in v1: feathered/vignette edge, non-rectangular spotlight shapes.

---

## The Voice Feature ("Clip That")

**Concept:** Silent rolling audio buffer in memory. Hit ⌘⇧5 ("clip that") and it saves the last N seconds as an M4A file. Like Twitch clips for your own voice.

**Technical:**
- `AVAudioEngine` taps the mic into a circular ring buffer (never written to disk)
- "Clip that" → flush buffer to temp file → appear in history
- No transcription in v1
- Buffer duration: configurable (30 / 60 / 120s), default 60s

**Privacy:** a subtle dot on the menu bar icon indicates when the buffer is active. Nothing is ever uploaded. The buffer lives only in RAM.

---

## Recording Modes

| Mode | Default | Toggle in |
|------|---------|-----------|
| Screen video | On | Always on when recording |
| Mic audio | Off | Menu bar quick toggle or Settings |
| System audio | Off | Menu bar quick toggle or Settings |

All three are independent. Grabbit asks for mic and system audio permissions only when the user turns those on.

---

## Tech Stack

**Swift + SwiftUI + AppKit**

| API | Use |
|-----|-----|
| ScreenCaptureKit | Screenshots + screen recording |
| AVFoundation | Video encoding |
| AVAudioEngine | Rolling voice buffer + mic recording |
| Speech framework | Transcription (future) |
| Core Graphics | Image processing |
| NSEvent global monitor | System-wide hotkeys |
| NSStatusItem | Menu bar |
| NSPanel | Overlay windows (region selector, command bar, toast, annotation) |
| UserDefaults | Hotkey preferences, settings |
| Vision (on-device) | OCR text extraction for Auto-Organize subfolder suggestions |
| Accessibility / NSWorkspace | Frontmost app bundle ID + window title at capture time — primary Auto-Organize signal |
| AppleScript (NSAppleScript / Apple Events) | Reads the active tab URL from Safari/Chrome/Brave/Edge/Arc for browser-based project resolution — one-time Automation permission, silent fallback to window-title parsing if denied |

---

## App Architecture

```
Grabbit/
├── GrabbitApp.swift             ✅ @main, AppDelegate, NSStatusItem, menu bar
├── RegionSelector.swift          ✅ Transparent overlay, crosshair, drag-to-select
├── ScreenshotEngine.swift        ✅ ScreenCaptureKit capture, coordinate conversion
├── ToastView.swift               ✅ Bottom-right preview toast, tap to annotate/reveal
├── AnnotationWindow.swift        ✅ Full annotation suite, smooth strokes, select/drag, emoji, toolbar
├── RecordingEngine.swift         ✅ ScreenCaptureKit + AVFoundation H.264 MP4
├── VideoAnnotationWindow.swift   ✅ AVPlayerView, annotate frame, reveal in Finder
├── CaptureBar.swift              ✅ Floating capture mode panel (⌘6), all modes + camera/mic/audio toggles
├── CaptureHistory.swift          ✅ In-memory + on-disk capture history, JSON manifest
├── CaptureLibraryWindow.swift    ✅ NavigationSplitView history panel — sidebar list + detail preview
│                                     🔜 pivoting to a live Finder-synced tree (FSEvents watcher, folder
│                                     outline, rename/tag/move-into-project UI) — see Capture Library spec
├── SettingsWindow.swift          ✅ Save location picker, read-only shortcut badges
├── ShipItPanel.swift             ✅ Undocumented until now — recording export panel: side-by-side compare,
│                                     background-style swatches for the recording composite
│
│   — TO BUILD —
├── AudioRingBuffer.swift         # AVAudioEngine tap → circular buffer in RAM
├── ClipEngine.swift              # Flush buffer → M4A on "clip that"
├── CommandBar.swift              # Future: Spotlight-style text command panel
├── CaptureClassifier.swift       ✅ Deterministic classifier: mapping cache → resolved project/tab name
│                                     (Xcode project ancestor, browser tab URL via AppleScript) → Vision OCR →
│                                     rule-based bundle ID/window-title matching → nil. No LLM tier — never "loads."
└── AutoOrganizer.swift           # ⚠️ real-time toast-chip wiring superseded 2026-07-11; `moveCapture` /
                                     mapping-cache logic is reused by the Capture Library instead
```

**Info.plist — required keys:**
- `LSUIElement = true` → hides Dock icon, menu bar only
- `NSScreenCaptureUsageDescription` → screen recording permission string
- `NSMicrophoneUsageDescription` → mic permission string
- `NSAppleEventsUsageDescription` → if needed for accessibility

---

## Feature Roadmap

### v0.1 — Core screenshot loop ✅
Region screenshot, toast notification, and clipboard capture are all wired up via ScreenCaptureKit with correct display-relative coordinates. Global hotkeys (⌘⇧3 for region — see deviation note above, ⌘⇧4, ⌘6) live via NSEvent global monitor with accessibility permission gating.

### v0.1.5 — Hotkeys (partial ✅)
**Corrected 2026-07-04:** the live global hotkeys are actually ⌘⇧3 (region screenshot, mislabeled — see deviation note above), ⌘⇧4 (recording), and ⌘6 (Capture Bar), gated by accessibility permission with a guard against double-triggering recording.
- [ ] ⌘⇧1 → full screen screenshot (capture logic exists via `CaptureBar`'s `.screenshotFullScreen` mode; global hotkey not wired)
- [ ] ⌘⇧2 → region screenshot per the Hotkeys table above (currently fires on ⌘⇧3 instead — reconcile table vs code)
- [ ] ⌘⇧3 → window screenshot per the Hotkeys table above (capture logic exists via `CaptureBar`'s `.screenshotWindow` mode; global hotkey not wired — that combo is currently taken by region capture)
- [ ] ⌘7 → open capture library (wire in global monitor + AppDelegate)
- [ ] Better onboarding UX for accessibility permission

### v0.2 — Annotations ✅
Full annotation suite ships in `AnnotationWindow.swift` — marker, highlighter, arrow, rectangle, text, number stamps, key-driven tool switching, 8-color palette, undo, and a floating pill toolbar.
- [ ] Blur / redact region (deferred)

---

## Upcoming Priorities

### v0.3 — Annotation upgrades ✅
Added emoji stamp tool (E key) with searchable picker, select tool (S key) with drag-to-reposition and delete, and a dashed bounding box selection visual.
- [ ] Stroke pressure simulation — vary lineWidth based on mouse speed
- [ ] Blur / redact region tool (B key)
- [ ] Focus / Spotlight tool (F key) — dim/blur/desaturate technique picker, see Focus / Spotlight Tool spec above
- [ ] Snap-to guides when drawing arrows and rectangles near edges

### v0.4 — Video previewer + recording annotation ✅
`VideoAnnotationWindow.swift` opens from recording toast with play/pause scrubber, and "Annotate Frame" grabs the current frame into `AnnotationWindow`.
- [x] Record selected region (not just full screen) — done. `CaptureBar`'s `.recordRegion` mode calls `executeRecording(captureTarget: .region(rect), ...)`.
- [x] Audio toggles: mic on/off, system audio on/off — done. `CaptureBar` has `micEnabled`/`systemAudioEnabled` state wired through to `executeRecording`, with a popover menu for system audio and a mic device picker.

### v0.5 — Capture Bar ✅
`CaptureBar.swift` is a floating bottom panel (⌘6) covering screenshot, record, and voice clip modes with active state highlighting and Escape to dismiss.
- [ ] Options popover (mic toggle, system audio, timer, save location)

### v0.5.5 — Settings ✅
`SettingsWindow.swift` launched with save location picker and read-only shortcut badges. Output folder preference stored in UserDefaults via `AppSettings`.
- [ ] Wire save location into screenshot export — `CaptureHistory.saveScreenshot` currently ignores `AppSettings.destinationFolderURL` and always saves to Application Support
- [ ] Remappable hotkeys (future)

### v0.6 — Loom-style recording with camera ✅
Floating circular camera bubble composited into the MP4 via GPU-backed CIContext, with mic support, feathered mask, selfie mirror, and camera/mic toggles in CaptureBar.
- [ ] Draggable camera bubble position baked into composite (currently always bottom-right regardless of bubble position)
- [ ] Camera bubble size presets (Small / Medium / Large)

### v0.7 — History ✅ (partial)
`CaptureLibraryWindow.swift` ships as a NavigationSplitView with sidebar list + detail preview pane. Accessible via "Show All…" in the menu bar. Screenshots and recordings both shown; right-click → Show in Finder / Move to Trash.
- [ ] Wire ⌘7 hotkey to open the library
- [x] Re-open screenshot for annotation from the library — done. The preview pane's "Open" button (⏎) calls `CaptureLibraryWindow.open(entry)`, which routes screenshots into `AnnotationWindow` and recordings into `VideoAnnotationWindow`.
- [ ] OCR — copy text from screenshot (Vision framework)

### v0.8 — Onboarding ✅ (v0.1 library-ready)
First-launch flow: Screen Recording → Accessibility → save folder (`OnboardingWindow.swift`), gated by `AppSettings.hasCompletedOnboarding`. Existing installs with a configured save folder are treated as already onboarded.
- [x] First-launch flow: request screen recording permission → request accessibility permission → pick save folder
- [x] Each step is a single focused sheet, not an alert dump
- [x] Don't proceed to the next step until the prior permission is granted (poll + retry)
- [x] Save folder step: show a picker, persist to `AppSettings`

### v0.9 — Dynamic Save Location (Auto-Organize) — superseded 2026-07-11
Real-time toast-chip organizing is no longer the plan (see pivot note in the spec section above). Work already done here isn't wasted — `CaptureClassifier`'s signal-gathering and `CaptureDestinationMappingCache` carry forward into the Capture Library's suggestion engine, just no longer auto-firing at save time.
- [x] `CaptureClassifier.swift` — read frontmost app bundle ID + window title at capture time (`gatherWindowInfo()`, AXUIElement-based)
- [x] Vision OCR pass on the captured image for subfolder signal (page/section names, headings) — `recognizeText(in:)`
- [x] ~~Foundation Models availability check + local LLM call~~ — **removed 2026-07-08**: the LLM tier added latency ("loading") and was replaced with deterministic project resolution (Xcode project ancestor, browser tab URL) instead.
- [x] Fallback chain implemented and **verified working end-to-end via debug print**: cache → resolved project/tab name → rule-based metadata/OCR matching (~35 known bundle IDs + window-title parsing) → nil
- [x] Frontmost-app timing bug fixed (see deviation note above) and confirmed correct on a real build
- [x] Dominant-app-by-capture-area resolution for region/full-screen captures spanning multiple windows, plus project name resolution (`kAXDocumentAttribute` → project root, falling back to title parsing → OCR heading) — confirmed working via debug print
- [x] `classify()` already invoked post-capture in `GrabbitApp.swift:takeScreenshot` and `CaptureBar.swift:finishScreenshot` (debug-only — prints result, no UI yet)
- [x] Mapping cache stub so confirmed product → folder choices are remembered without re-running OCR or the LLM (`CaptureDestinationMappingCache`) — read path done; write path (`confirm`) now gets called from the Capture Library's tag/move actions instead of a toast-chip tap
- [x] ~~`AutoOrganizer.swift` — folder chip on toast~~ — **dropped**. **Confirmed removed 2026-07-12**: `AnnotationWindow.swift`'s save action is now a plain `performSave()` (renamed from `performSaveAndShowOrganizeToast()`) — just `flattenAndSave()` + the "Saved to PNG" toast. `organizeSuggestionPanel`, the `AnnotationOrganizeSuggestionPanel` class, and the `AutoOrganizer.registerCaptureContext` call in `show(...)` are all gone. `AutoOrganizer.swift`/`CaptureClassifier.swift`/`CaptureHistory.swift` themselves are untouched — `moveCapture` plumbing is still there, just waiting to be called from the Capture Library instead

### v0.9 — Capture Library — Finder Sync (replaces Auto-Organize toast, added 2026-07-11)
**MVP flagship feature #2** for v1.0. **Partial as of v0.1 library-ready:** Capture Library ships with disk reconcile on open, project/flow tagging, Auto Organize suggest → review → apply, and index-only history trim (never deletes user capture files). Full live Finder Sync (FSEvents + folder outline) remains open.
- [x] Reconcile manifest entries with on-disk files (path-based identity fallback) — on launch / library open / destination change
- [x] Rename-suggestion UI — Auto Organize batch, accept/edit/dismiss per item, nothing auto-renames
- [x] Project tagging UI — soft controls + Auto Organize, backed by `CaptureDestination` / tags
- [x] Move-into-project — via Accept / project tag (`CaptureLibraryOrganizer` / `CaptureOrganizer.moveCapture`)
- [ ] Live FSEvents watcher — library reflects external Finder changes live
- [ ] Sidebar becomes a folder-aware tree/outline view instead of a flat/grouped recency list
- [ ] Drag-and-drop / batch "move selected to…"
- [ ] Decide whether the mapping cache / tag list is user-editable in Settings
- [x] Analysis tier: on-device Foundation Models when available + deterministic fallback (project-only)

### v1.0 — Launch
**MVP gate is the screenshot loop plus the Capture Library / Finder Sync** (capture → annotate → share as "look at this" / "here's why", with organizing handled as a deliberate post-capture pass in a Finder-synced library instead of an automatic real-time guess). Recording and background tools keep shipping, but full Finder Sync still blocks the v1.0 label.
- [x] Full screen + region screenshot as **global hotkeys** (⌘⇧3 / ⌘⇧4); Capture Bar for window / record
- [x] App icon wired into `Assets.xcassets/AppIcon.appiconset`
- [x] First-launch onboarding + `NSScreenCaptureUsageDescription` + marketing version 0.1
- [ ] Notarization
- [ ] Website / download page
- [ ] FSEvents + folder-tree Capture Library (remaining v0.9 items)

---

## Future / Post-v1
- Voice "Clip That" — rolling audio buffer, ⌘⇧5 to clip last N seconds (`AudioRingBuffer.swift` + `ClipEngine.swift`)
- Command Bar (`CommandBar.swift`) — Spotlight-style text panel, power-user layer on top of the visual Capture Bar
- Loom-style hosted sharing (upload + shareable URL)
- Remappable hotkeys in Settings
- Blur / redact annotation tool (B key, deferred from v0.2)
- Snap-to guides in annotation canvas
- Camera bubble drag position baked into recording composite (currently always bottom-right)
- Camera bubble size presets (Small / Medium / Large)

---

## Permissions Flow (design this well — it's the first impression)

| Permission | Trigger | Dialog copy suggestion |
|------------|---------|----------------------|
| Screen Recording | First launch | "Grabbit needs screen access to capture screenshots and recordings. Nothing is ever uploaded without your action." |
| Accessibility | First launch | "Needed so your keyboard shortcuts work from any app." |
| Microphone | When voice buffer is turned on | "Grabbit keeps a short audio buffer in memory so you can clip the last 60 seconds. It's never saved or uploaded until you clip it." |
| System audio | When system audio recording toggled on | Standard macOS prompt — no custom copy needed |

---

## Design System Consistency (evaluation, 2026-07-04)

There's no shared design-tokens file. Each window/panel defines its own private `Style` enum with its own numbers, so values that should be identical drift silently:

- **Corner radii vary with no evident pattern**: 4 (`CaptureLibraryWindow`, arrow selection handles), 5 (`SettingsWindow`), 6 (toast, several `AnnotationWindow` chips), 8 (`CaptureBar` hover state, one `ShipItPanel` element), 10 (`CaptureBar` panel, `RecordingBackgroundPreviewWindow`), 12 (toast panel, `CaptureBar` outer panel, `ShipItPanel` outer panel, several `AnnotationWindow` panels). Similar-purpose surfaces (a floating panel vs. a floating panel) don't consistently share a radius.
- **The recording-background brand palette is duplicated as raw literals** in two places — `RecordingBackgroundRenderer.swift` (SwiftUI `Color(red:green:blue:)`) and `ShipItPanel.swift` (`NSColor(red:green:blue:alpha:)`) — with the same five RGB triples typed out independently instead of referencing one shared constant. If the palette changes, it's easy to update one file and miss the other.
- **Two different color-definition conventions coexist**: semantic system colors (`NSColor.separatorColor`, `.controlAccentColor`, `.quaternaryLabelColor`) are used freely, alongside custom brand colors defined ad hoc (`NSColor.annotationSelectionAccent`, `.regionSelectionAccent` as an extension in `AnnotationWindow.swift`, plus the raw literals above). No single palette file ties these together.
- **Typography is mostly hand-set AppKit `NSFont.systemFont(ofSize:weight:)` calls** (sizes 9.5, 11, 12, 13, 14, 18 appear across files with no named scale), **except `CaptureLibraryWindow.swift`**, which is built in SwiftUI and uses semantic Dynamic Type fonts (`.headline`, `.caption`) instead. That one window will respond to Dynamic Type / accessibility text-size changes differently than every other window in the app, and its type sizing won't necessarily match the fixed-pixel sizes used elsewhere.
- **`ShipItPanel.swift` is a real, shipped file** (recording export panel — side-by-side compare view, background-style swatches) **that was missing from the App Architecture list entirely** until this pass. Worth folding into the architecture doc so it isn't orphaned from planning.

None of this breaks anything today, but it's the kind of drift that gets expensive right around v1.0 polish — recommend a `DesignTokens.swift` (or similar) centralizing corner radii, the brand palette, and a small type scale before the launch push.

---

## Cursor Prompting Notes (for when you start building)

- **Always give Cursor the file path and class name you want it to work in.** Vague prompts produce generic code.
- **Paste in the architecture tree above** when starting a new file so Cursor knows where it fits.
- **For SwiftUI + AppKit bridging**, Cursor tends to mix them incorrectly — specify which layer you're working in.
- **ScreenCaptureKit is newer API** — Cursor may suggest deprecated CGWindowList approaches. Correct it: "Use ScreenCaptureKit, not CGWindowList."
- **For the ring buffer**, ask Cursor to implement `AVAudioEngine.inputNode.installTap` with a circular array — specify you don't want it to write to disk.
- **Hotkey registration**: NSEvent.addGlobalMonitorForEvents requires Accessibility permission. Cursor may forget to check for this.
