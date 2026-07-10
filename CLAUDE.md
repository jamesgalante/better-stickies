# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & run

**Never use plain `swift build`.** The system `xcode-select` points at the Command Line
Tools (old SDK); `NSGlassEffectView` linked against a pre-macOS-26 SDK crashes at
runtime (`_NSWindowTransformAnimation` over-release). Always build through the script,
which pins `DEVELOPER_DIR` to Xcode 26:

```sh
Scripts/make_app.sh        # release build → assembles Better Stickies.app → installs to /Applications
Scripts/make_release.sh 1.2  # make_app.sh + dist/Better-Stickies.zip (STABLE name — do not version it;
                             # /releases/latest/download/Better-Stickies.zip depends on it)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build   # manual builds
```

Dev loop (no tests exist): `pkill -x "Better Stickies"; zsh Scripts/make_app.sh && open "/Applications/Better Stickies.app"`.
Publish: `gh release create vX.Y.0 dist/Better-Stickies.zip`. Landing page = `docs/`
(GitHub Pages from main); local preview server is configured in `.claude/launch.json`.
Icon: `swift Scripts/make_icon.swift` regenerates `Resources/AppIcon.icns` from code.

Headless probes beat guesswork for AppKit issues: compile scratch `main.swift` together
with the relevant source files (`swiftc main.swift Sources/Stickies/Models.swift ...`)
to test decode round-trips, dump private-API surfaces via the ObjC runtime, or inspect
layer trees off-screen.

## Architecture

SwiftPM executable, deliberately plain AppKit lifecycle (`Main` → `AppDelegate`), no
SwiftUI `WindowGroup` — SwiftUI-owned windows fight transparent/borderless panes.

**Data:** `NotesStore` (Models.swift) owns one JSON file,
`~/Library/Application Support/BetterStickies/notes.json`. Saves are debounced (0.4s) +
flushed on quit. **External tools are allowed to rewrite the file while the app runs**
(this is an advertised feature): the store watches the *directory* (file watchers die on
atomic replace), ignores its own writes by byte comparison, and merges per note — a note
with unsaved local edits beats the external version. `externalReloadCount` fans out: the
AppDelegate diffs windows open/closed, and `reloadToken` pushes new text into open
editors. New `Note`/`Span` fields must `decodeIfPresent` with defaults (old files must
keep decoding) and encode flags only when set; `Note` also carries a legacy v1 migration.

The store watches both the file and its directory, so in-place writes and atomic
replaces are both detected (if you touch `startWatching()`, re-verify three paths
against the running app: in-place, atomic, in-place-after-atomic); undecodable external
writes are logged (subsystem `com.jamesgalante.better-stickies`, category `store`) and
then overwritten by the next save. External writers should prefer atomic replaces,
match notes by `id` (never array index), round-trip unknown keys, and leave
actively-edited notes alone — a note with unsaved local edits wins the merge.
The full on-disk schema and agent recipes live in `AGENTS.md`; keep it in sync
when `Note`/`Span` fields change.

**Windows:** `AppDelegate.openWindow` per unstashed note. `WindowFactory` (Window.swift)
builds a borderless `StickyWindow`; `WindowContext` is the SwiftUI↔AppKit bridge
(close/stash, pin, collapse, fit-to-text height pinning via contentMin/MaxSize, glass
updates). Closing a non-empty note **stashes** it (Library window lists all notes);
only empty notes are deleted on close.

**The glass stack (Window.swift) is settled — don't refactor without a reported bug.**
Every private-API override documents the symptom it fixes and fails safe. The stack,
bottom to top: `SaturatingFrostView` (an NSVisualEffectView with its fog washes hidden
and its backdrop filters driven directly) → `LivelyGlassView` (NSGlassEffectView,
`.clear` style) → `NSHostingView` **inside** `glass.contentView` (the only placement
that gets full refraction; siblings render flat). Hard-won invariants:

- The glass cannot sample behind the window; the frost pane exists to pull desktop
  imagery in-window for it to bend.
- **Never mutate attached CAFilters** — Core Animation diffs by object identity, so
  in-place mutation silently never reaches the window server (app-side reads lie).
  Copy each filter, set values on the copy, assign a fresh array (`applyOptics`).
- Optics re-apply on `updateLayer`, `layout` (resizes rebuild the material), and via a
  1s watchdog that logs deviations to os_log subsystem
  `com.jamesgalante.better-stickies` before healing.
- Unfocused dimming is defeated by `StickyWindow` answering the private
  key-appearance queries with yes (the pull path — intercepting setters wasn't enough).
- Window shadows are off on macOS 26 (a transparent window's shadow traces the square
  frame); frost corners round via `maskImage`, not layer cornerRadius.

**Editor (RichEditor.swift):** custom `NSAttributedString.Key`s (`.stickyBold`, ink,
highlight, links…) are the source of truth; `restyle()` translates them to rendering
attributes wholesale, so never store style state in rendering attrs. `serialize()`/
`load()` map to the `Line`/`Span` model. Typing shorthands (`- `, `[] `, `**bold**`)
convert once on input; **no Enter-triggered continuation of lists — explicit owner
preference, do not add auto-continuation**. Text views have `usesFontPanel = false and
focus rings disabled on purpose (color-panel feedback loop; square focus ring).

**Menus & commands:** the sticky itself shows only a close × — all controls live in the
menu bar (Note = pane appearance, Format = text). Menu actions post `StickyCommand`
notifications; the key sticky applies them (`handleCommand` in StickyView.swift), with
checkmark state via `validateMenuItem` on the AppDelegate. **No custom views (sliders)
in menu items** — NSMenu re-hosts item views on reopen and garbles them (frames,
rebuild-on-open, and Auto Layout all failed); use preset submenu items. The exception
path for the color panel: it steals key status, so `colorPanelDidPick` writes to the
note captured at open time, guarded against echoes (NSTextView pushes colors back into
the shared panel otherwise → infinite main-thread loop).

⌥⌘S summon hotkey uses Carbon `RegisterEventHotKey` (HotKey.swift) — the only global
shortcut API needing no Accessibility permission.
