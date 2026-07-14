# AGENTS.md — interacting with Better Stickies

This file is for AI agents and scripts that read or write Better Stickies notes.
The app is *designed* for this: it watches its data file and merges external edits
live — no restart, no API, no SDK. One JSON file is the whole interface.

## Where the data lives

```
~/Library/Application Support/BetterStickies/notes.json
```

A single JSON array of note objects. The app saves ~0.4 s after the user stops
typing and on quit, so a read is at most half a second stale while the user is
actively typing.

## The write contract

1. **Re-read immediately before writing.** Read-modify-write on a stale copy
   silently discards whatever the user typed in between.
2. **Prefer atomic writes** — write a temp file *in the same directory*, then
   rename over `notes.json` (`os.replace()` in Python). In-place writes are also
   detected, but an atomic write can never be read half-finished.
3. **Match notes by `id` (a UUID string), never by array position.** The app
   merges per-UUID; index 0 is not stable.
4. **Round-trip unknown keys.** Load → mutate → dump. Never reconstruct a note
   from scratch: fields you drop silently reset to their defaults (the schema
   grows over time, and absent keys mean "default").
5. **Leave actively-edited notes alone.** If the user has unsaved edits in a
   note, the app keeps its local version of that note and quietly drops yours.
   Other notes in the same write are still applied.
6. **Write valid JSON.** A malformed file is ignored (logged to os_log,
   subsystem `com.jamesgalante.better-stickies`, category `store`) and will be
   overwritten by the app's next save.

## What happens after your write

The app notices within ~1 s and merges: new unstashed notes open as windows on
the desktop, notes you removed or stashed have their windows closed, and open
editors refresh in place (preserving the user's cursor). Your changes then get
re-saved in the app's own field order — don't expect byte-identical round-trips.

## Schema

A note with every field spelled out (booleans/flags are often *absent* in real
files — absent means the default):

```jsonc
{
  "version": 2,                  // schema version; always write 2
  "id": "9B2C41F0-...-A1",       // UUID string, unique per note — REQUIRED
  "tintHex": "FFFFFF",           // pane color (RGB hex, no #)
  "tintStrength": 0.35,          // 0 = clear glass … 1 = solid color
  "edgeHex": "FFD60A",           // optional glowing edge color; omit for none
  "pinned": false,               // floats above all windows
  "fontKey": "rounded",          // rounded | serif | mono | hand
  "textSize": 13,                // base point size (UI offers 10–24)
  "cornerRadius": 16,            // pane rounding in points (UI: 4–28)
  "saturation": 1.6,             // backdrop color boost (1.0 = none … 3.4)
  "wrapText": true,              // false = long lines scroll horizontally
  "textAlignment": "left",       // left | center | right
  "lineSpacing": "normal",       // tight | normal | roomy
  "textPadding": "normal",       // compact | normal | comfy
  "fitToText": false,            // window height hugs the content
  "stashed": false,              // true = lives in the Library, no window
  "collapsed": false,            // true = rolled up to a slim bar
  "expandedHeight": 320,         // height to restore on expand (optional)
  "lines": [                     // the content: one object per paragraph
    {
      "todo": true,              // renders a checkbox
      "done": false,             // checked state (strikes the line)
      "image": "ABC….png",       // block-image line: filename inside
                                 //   …/BetterStickies/images/ (see below)
      "imageWidth": 260,         // display width in points (height follows
                                 //   the image's aspect ratio)
      "spans": [                 // runs of styled text within the line
        {
          "text": "call dad",    // the only required span field
          "bold": true,          // inline styles: bold, italic,
          "italic": false,       //   underline, strike (all optional)
          "underline": false,
          "strike": false,
          "colorHex": "E5484D",  // optional text color override
          "highlightHex": "FFE066", // optional highlighter
          "link": "https://…",   // optional link target
          "kind": "web"          // link kind: web | folder | file
        }
      ]
    }
  ]
}
```

Plain paragraphs omit `todo`/`done`. A bullet is literally the text `• ` at the
start of a span. An empty line is `{"spans": [{"text": ""}]}`.

**Images:** a line with `image` set renders that file as a block (its spans are
ignored — write `[{"text": ""}]`). Image files live in
`~/Library/Application Support/BetterStickies/images/`; to add one, copy your
file there under a fresh unique name, then reference the filename. Files no
note references are deleted at app launch, so never share an image between
notes by hand-copying the same filename reference *after* deleting its last
use, and don't park unrelated files in that directory.

## Recipes (Python)

```python
import json, os, uuid

PATH = os.path.expanduser(
    "~/Library/Application Support/BetterStickies/notes.json")

def read():
    with open(PATH) as f:
        return json.load(f)

def write(notes):                      # atomic: rename over the original
    tmp = PATH + ".tmp"
    with open(tmp, "w") as f:
        json.dump(notes, f)
    os.replace(tmp, PATH)

# Add a note (appears on the desktop within a second)
notes = read()
notes.append({
    "version": 2, "id": str(uuid.uuid4()).upper(),
    "lines": [{"spans": [{"text": "Reminder from your agent"}]},
              {"todo": True, "spans": [{"text": "reply to Katie"}]}],
})
write(notes)

# Check off a todo by text
notes = read()
for n in notes:
    for line in n["lines"]:
        if line.get("todo") and any("reply to Katie" in s.get("text", "")
                                    for s in line["spans"]):
            line["done"] = True
write(notes)

# Stash a note (its window closes); delete = remove it from the array
notes = read()
for n in notes:
    if n["id"] == "9B2C41F0-...":
        n["stashed"] = True
write(notes)
```

## If the app isn't running

Just edit the file — the app reads it fresh at launch. The watcher/merge
behavior only matters while it's running.
