# MacRumors「PowerPC Macs」板 — 新規スレッド投稿文（下書き）

件名・本文ともに英語。コピペしてそのまま使えます。スクリーンショットだけは
実機で撮って添付してください（こちらでは撮れないため）。

---

## Thread title

Tiger QuickLook — spacebar file preview from the Finder on Mac OS X 10.4 (PowerPC)

## Body

Hi all,

Quick Look is a Leopard (10.5) feature, so Tiger never had it. The closest things on 10.4 are MacGizmo (paid, and it uses a modifier-click, not the bare spacebar) and contextual-menu helpers like FinderPop. I wanted the actual Leopard gesture — select a file in the Finder, tap **Space**, get a preview — free, native, and light enough to leave running on a 1.2&nbsp;GHz G4. So I built a small one.

**What it does**

- Runs as a background agent (no Dock icon, a "QL" item at the right of the menu bar to quit it).
- Finder frontmost + one file selected + **Space** → a resizable preview window. **Space** again, or **Esc**, closes it. When something other than the Finder is frontmost, Space behaves normally.
- Supported formats are deliberately just four: **JPG / PNG / PDF / TXT**. Anything else does nothing.
- There's also a one-shot mode with no setup needed: `open -a TigerQuickLook.app /path/to/file`.

**One setup step (agent mode only)**

Intercepting an unmodified Space needs a `CGEventTap`, and on Tiger that requires **System Preferences → Universal Access → "Enable access for assistive devices"** to be ticked. It's a one-time checkbox. The app tells you and quits if it's off. One-shot mode doesn't need it.

**Keeping it light**

Images are shrink-decoded from the start (`CGImageSourceCreateThumbnailAtIndex`), never at full res. PDFs draw only page 1 (`CGPDFDocumentCreateWithURL` parses pages lazily, so a 250-page PDF opens as fast as a 1-page one — only page 1's complexity matters). TXT reads just the first 64&nbsp;KB. No prefetching, no cache, the window is disposable.

**Known limitations (v0.1)**

- If you press Space while renaming a file inline in the Finder, you get a preview instead of a space — there's no way for an outside process to tell the Finder is in edit mode. Esc to recover.
- For ~0.3&nbsp;s right after switching to the Finder, Space may not fire yet (the frontmost-app check is a poll; 10.4 has no activation notification). Selecting a file gives it enough time.

**Tested on** iBook G4 / Mac OS X 10.4.11. I haven't tried it on a G3 or G5, or on Leopard (which has real Quick Look anyway) — "works / doesn't work on my box" reports are very welcome.

This is a personal, non-commercial project. Free, MIT licensed, source on GitHub: https://github.com/watermark-hd/tiger-quicklook

The DMG is attached below (app + a readme). It's also on my site: https://oldmac.policy-log.jp/apps/tiger-quicklook

It's v0.1 and I'm still adding to it. I know MacGizmo already exists and covers more formats — this one is just free, open source, uses the plain spacebar, and is built to stay light on slow hardware. English isn't my first language, so apologies for any rough wording. Feedback and bug reports welcome.

---

*(下書きメモ)*
- *添付: `TigerQuickLook.dmg`。フォーラム投稿画面にドラッグ&ドロップで添付。*
- *スクリーンショット必須: 実機で「Finder で画像を選んで Space → プレビュー」の画面と、できれば PDF / TXT のプレビューも。メニューバーの「QL」も写っていると良い。*
- *MacGizmo への言及を最後に入れてある（「車輪の再発明」対策）。消したくなければそのままで。*
- *Leopard 未検証・G3/G5 未検証を正直に明記（過度な期待を持たせない）。*
