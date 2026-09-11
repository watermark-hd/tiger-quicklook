# Macintosh Garden 投稿フォーム用（下書き）— v0.4 時点

投稿フォームの項目に合わせて分けてあります。英語。わざと少し崩した非ネイティブ英語に
してあります（MacRumorsの投稿文と同じトーン。完璧すぎる英文だと「AIが書いたのか」と
言われるため）。まだ未提出。

---

## Title

Tiger QuickLook

## Category

Utilities

## Requirements

Mac OS X 10.4 (Tiger), PowerPC. Tested on iBook G4 (Tiger 10.4.11).

## Short description (1–2 sentences)

A small free tool that brings the Leopard-style Quick Look feeling to Tiger. Select a
file in the Finder, press Space, and a preview window shows up - images, PDF, text,
even old and new Office files.

## Full description

Quick Look came from Leopard (10.5), so Tiger never had it. The near things on 10.4
are MacGizmo (paid, and uses a modifier-click, not the plain spacebar) and
context-menu tools like FinderPop. This one tries to give the real Leopard gesture:
choose a file in Finder, press Space, and see a preview - for free, native, and
light enough to keep running on an old G4/G3.

It runs as a small background agent (no Dock icon, just a "QL" item in the menu
bar). Finder in front + one file selected + Space -> a resizable preview window.
Press Space again, or Esc, to close. Arrow keys move to the next/previous file
while a preview is open, same feeling as Leopard's Quick Look.

Supported so far: JPG / PNG / PDF / TIFF / GIF / BMP, plain text (.txt, .md, .csv,
.json, and many source file types), old Office files (.doc/.rtf/.html, through
Tiger's own `textutil`), and new Office files (.docx/.pptx/.xlsx/.odt/.ods/.odp, by
pulling the text out of the zip). Goal is "what is this file", not perfect layout.

One setup step: catching the plain Space key needs "Enable access for assistive
devices" turned ON in System Preferences > Universal Access (one time only, the app
tells you if it's off). There is also a one-shot mode with no setup at all:
`open -a TigerQuickLook.app /path/to/file`.

Free, MIT license, source on GitHub: https://github.com/watermark-hd/tiger-quicklook

Download page (with the readme): https://oldmac.policy-log.jp/apps/tiger-quicklook

Still v0.4 and I keep adding to it. Feedback and "works / doesn't work on my
machine" reports are welcome.

## Screenshot(s)

（実機でのスクリーンショットが必要。MacRumorsスレッドに貼った恐竜の子の写真の
プレビュー画面がそのまま使えます。他に PDF や テキストのプレビュー画面もあると
なお良いです）
