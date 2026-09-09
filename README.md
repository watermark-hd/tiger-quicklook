# Tiger QuickLook

**日本語: [README.ja.md](README.ja.md)** / English (this file)

A tiny Quick Look stand-in for **Mac OS X 10.4 "Tiger" (PowerPC)**.

Quick Look is a Leopard (10.5) feature, so Tiger never had it. This brings the
Leopard gesture back: select a file in the Finder, tap **Space**, get a preview
window. Tap Space again (or Esc) to close it. With a preview open, the **arrow
keys** step to the next/previous file in the same folder, so you can flip through
images and compare them without touching Space.

Supported formats are deliberately limited. The goal is **"which file is this,
again?"**, not faithful rendering.

## Requirements

- Mac OS X 10.4 Tiger, PowerPC.
- For the Space-key agent: **System Preferences → Universal Access → "Enable
  access for assistive devices"** must be ticked (a one-time checkbox).
  Intercepting a bare Space needs a `CGEventTap`, and Tiger gates that behind this
  setting. The app tells you and quits if it is off. The one-shot mode below needs
  no setup.

## Install & use

1. Download `TigerQuickLook-x.y.zip` from the [Releases](../../releases) page and
   unzip it. Put `TigerQuickLook.app` wherever you like.
2. Tick "Enable access for assistive devices" (see above).
3. Launch it with **`open TigerQuickLook.app`**, a double-click, or by adding it
   to your Login Items.

   **Always launch via `open` / double-click / Login Items.** Running the
   executable directly (`.../Contents/MacOS/TigerQuickLook`) skips LaunchServices,
   so the process never registers with the GUI session: the menu-bar item, the
   Finder query and the preview window all silently do nothing (only the event
   tap still fires, which makes this easy to misdiagnose).
4. Once it is running, a **"QL"** item appears at the right of the menu bar. Quit
   it from there (or `killall TigerQuickLook`).
5. In the Finder, select one file and press **Space**.
   - **Space** again, or **Esc**, closes the preview.
   - **← / → / ↑ / ↓** move to the previous / next previewable file in the same
     folder (name order); it stops at both ends.
   - When something other than the Finder is frontmost, Space behaves normally.

### One-shot mode (no setup)

```
open -a TigerQuickLook.app /path/to/file
```

Shows a single preview; closing the window quits the app. This mode does not need
the assistive-devices checkbox.

### As a Finder "Open With" handler

The bundle registers the supported extensions, so you can right-click a file →
Open With → Tiger QuickLook, or make it the default for a type in Get Info.

## Supported formats

| Kind | Formats | How |
|---|---|---|
| Images | JPG, PNG, PDF, TIFF, GIF, BMP | ImageIO / Quartz directly. PDF = first page only |
| Text | TXT, MD, CSV, JSON, XML, and many source-code extensions | first 64 KB, shown as-is in a monospaced view |
| No extension | — | shown as text if the first few KB look like text |
| Legacy Office | **DOC** (Word 2004-era), RTF, HTML | Tiger's own `textutil -convert txt` |
| Modern Office | **DOCX, PPTX, XLSX**, ODT, ODS, ODP | body XML pulled with `unzip -p`, tags stripped |

Not supported: camera RAW, faithful layout, multi-page / multi-sheet coverage.
No extra libraries are bundled — the only external dependencies are `textutil`
and `unzip`, both shipped with Tiger.

## How it works

- **One binary, two modes.** With a file argument it shows a single throwaway
  preview. With no argument it runs as a background agent (`LSUIElement`, no Dock
  icon).
- The agent installs a `CGEventTap` (`kCGSessionEventTap`, head-insert) and, only
  while the Finder is frontmost or a preview is showing, swallows a bare Space and
  asks the Finder for its selection via `NSAppleScript`.
- The tap is enabled/disabled by polling the front app every 0.3 s. Left always
  on, an active tap makes the Window Server finalise key events through the
  current input source, which turns Space into a full-width space (U+3000) in
  Terminal-like apps when a Japanese input source is active. Tiger has no
  "app activated" notification (`NSWorkspaceDidActivateApplicationNotification`
  is 10.6+), hence the poll. Side effect: Space is dead for up to ~0.3 s right
  after switching to the Finder.
- **Kept light for a ~1.2 GHz G4:** images are thumbnail-decoded at preview size
  (full resolution is never decoded), PDFs draw only page 1, text reads only the
  first 64 KB, nothing is prefetched, and the preview window is reused (contents
  swapped in place) rather than recreated on every step.

More detail, including the Tiger SDK / GCC 4.0 gotchas, is in
[`docs/開発ノート.md`](docs/開発ノート.md) (Japanese).

## Building

The PowerPC binary is built **on the Tiger machine itself** (no cross-compile),
because `xcodebuild` is broken on this install (`DevToolsSupport.framework`
missing). `build.sh` compiles `src/main.m` with
`gcc -isysroot /Developer/SDKs/MacOSX10.4u.sdk …` and assembles the `.app` by
hand:

```
sh build.sh
```

The icon (`Resources/TigerQuickLook.icns`) is a classic-type `.icns` built with
libicns `png2icns` — the PNG-based `.icns` that modern `iconutil` produces is not
readable by Tiger's Finder (the icon shows up blank).

## Limitations

- Pressing Space while inline-renaming a file in the Finder previews instead of
  typing a space — there is no way to see the Finder's edit state from another
  process. Esc undoes it.
- Arrow-key sort order is plain case-insensitive by name, which differs slightly
  from the Finder's numeric-aware sort.
- After swapping in a new build, run `killall TigerQuickLook` first — a stale
  agent keeps handling Space with the old behaviour.

## License

MIT — see [LICENSE](LICENSE).
