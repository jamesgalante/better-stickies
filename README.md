# Better Stickies

Desktop sticky notes for macOS, rebuilt around **Liquid Glass**: notes are
clear refractive panes that saturate and blur the desktop behind them —
from fully transparent glass to a solid color, one slider.

## Features

- **Real Liquid Glass** notes (macOS 26) — clear glass with edge
  refraction over a saturating backdrop; a Glass slider runs from
  crystal-clear to frosted to opaque
- **Rich text**: bold / italic / underline / strikethrough, text colors,
  highlighter, four typefaces, per-note text size — all from the menu bar
- **Markdown-ish typing**: `- ` becomes a bullet, `[] ` becomes a
  checkbox, `**bold**` and `*italic*` convert as you type
- **Checklists** with clickable checkboxes (⌘L)
- **Links** to websites, files, and folders (⌘K, or drag & drop)
- **Collapse**: double-click a note's top edge to roll it up to a slim
  glass bar
- **Stash & Library**: closing a note stashes it instead of deleting;
  browse and search everything with ⌘⇧L
- **Float on top**, per-note colors and glowing edge colors
- Notes live in a plain JSON file (`~/Library/Application
  Support/BetterStickies/notes.json`) that external tools can safely
  read *and write* — the app watches the file and merges outside edits
  live

## Install

Download the latest zip from
[Releases](../../releases), unzip, and drag **Better Stickies.app** to
`/Applications`.

The app is not code-signed (no Apple Developer membership), so macOS
will refuse to open it at first. Either right-click the app → **Open** →
**Open**, or run:

```sh
xattr -dr com.apple.quarantine "/Applications/Better Stickies.app"
```

Requires **macOS 26** for the Liquid Glass look (earlier macOS falls back
to a frosted-blur pane).

## Build from source

Requires Xcode 26 (the app links `NSGlassEffectView`, which needs the
macOS 26 SDK — the build script pins `DEVELOPER_DIR` accordingly).

```sh
Scripts/make_app.sh      # builds and installs to /Applications
Scripts/make_release.sh  # builds and packages dist/Better-Stickies-*.zip
```

## Notes on the glass

There is no public API for most of what the glass does here. The panes
are built from `NSGlassEffectView` + a rewritten `NSVisualEffectView`
backdrop (fog washes hidden, saturation boosted, full-resolution
sampling), with a handful of carefully-commented private-API overrides
to keep the glass lively when windows lose focus. See
`Sources/Stickies/Window.swift` — every override documents the symptom
it fixes and fails safe if a future macOS renames things.
