# OSX Tiger QuickLook

**English: [README.md](README.md)** ／ 日本語（このファイル）

2026-08-29、AquaFinder開発中の雑談から派生。「NASやUSB経由でのファイル閲覧に、
テキストが読める程度の大きさのプレビューが欲しい」という話から、Tiger実機向けの
軽量なQuick Look代替を作る方向で合意した。

**2026-09-09: 常駐エージェント方式を追加。** Finderを最前面にしてファイルを選び、
修飾なしの **Space キー** を押すとプレビューが出る(Leopardのスペースバー式
Quick Lookの再現)。もう一度 Space で閉じる。**この機能を使うには
「補助装置にアクセスできるようにする」を有効にする必要がある** →
下の「使い方（必ずお読みください）」を参照。

**v0.2: 対応形式を拡張(TIFF/MD/DOC/DOCX/XLSX/… と拡張子なしテキスト)、
プレビュー中の矢印キーで隣のファイルへ移動。** 詳細は「対応形式」と
「使い方 4.」を参照。

**v0.3: 矢印キー移動でウィンドウを作り直さず中身だけ差し替えるようにした
(ちらつき低減、位置を保持)。**

## 使い方（必ずお読みください）

配布物(zip / dmg)にもこの内容を `必ずお読みください.txt` として同梱する。

### 1. ビルド

実機(iBook)上で:

```
sh build.sh
```

`TigerQuickLook.app` ができる。

### 2. Space キーでプレビューできるようにする（重要）

Space キー方式は、修飾キーなしの Space を条件付きで横取りするために
**イベントタップ**を使う。Tiger ではこれに以下の許可が必須:

**システム環境設定 →「ユニバーサルアクセス」→ 一番下の
「補助装置にアクセスできるようにする」にチェックを入れる。**

チェックを入れずに起動すると、その旨のダイアログが出て終了する。

### 3. 常駐させる

```
open TigerQuickLook.app
```

**必ず `open`(または Finder でダブルクリック / ログイン項目)から起動すること。**
実行ファイルをパスで直接叩く(`.../MacOS/TigerQuickLook`)と、LaunchServices を
通らず GUI セッションに登録されないため、メニューバー項目・Finder への
問い合わせ・プレビュー表示がすべて無反応になる(イベントタップだけは動くので
気づきにくい)。

引数なしで起動 = エージェントモード。常用するなら **システム環境設定 →
「アカウント」→「ログイン項目」に `TigerQuickLook.app` を追加**する。

常駐すると **メニューバー右側に「QL」** が出る。終了はここから
(またはターミナルで `killall TigerQuickLook`)。

### 4. プレビューする

Finder を最前面にしてファイルを1つ選び、**Space**。もう一度 **Space**
(またはウィンドウで **Esc**)で閉じる。対応形式は下の「対応形式」を参照。
対象外を選んで Space を押しても何も起きない。

プレビュー表示中に **← / → / ↑ / ↓** を押すと、同じフォルダ内の
「プレビューできるファイル」を名前順で前後に移動する(Leopard の Quick Look
と同じ操作感)。Space を押し直さずに隣の画像を続けて見比べられる。
端まで行くと止まる。

### 制限

- **ファイル名をインラインでリネーム中に Space を押すと、スペースが入力されず
  プレビューが出てしまう。** Finder のテキスト編集中かどうかを外部プロセスから
  判定できないため。Esc で戻せる。
- Finder 以外が最前面のときは Space は通常どおり動く(横取りしない)。
- Finder に切り替えた直後の約0.3秒間は Space が効かないことがある(前面アプリの
  監視がポーリングのため。下の「進捗」参照)。ファイルを選ぶ動作で十分間が空く。

### 単発で開くだけなら

常駐させず、ファイルを指定して起動するだけでもよい:

```
open -a TigerQuickLook.app /path/to/file.pdf
```

この場合はウィンドウを閉じるとアプリごと終了する。

## 配布物

`配布用/` に、実機でビルドした `TigerQuickLook.app` と `必ずお読みください.txt`
・`LICENSE.txt` をまとめた `TigerQuickLook-0.3.zip` / `.dmg` を置いている
(zip/dmg/app は gitignore 対象。MacRumors 投稿文の下書き `macrumors_thread_draft.md`
も同じフォルダ)。GitHub Releases (`v0.3`) にも同じ zip/dmg を添付済み。
中身の PowerPC バイナリは iBook 実機ビルドなので、配布物を作り直すときは
`build.sh` を実機で回して `TigerQuickLook.app` を取得し直すこと。

アイコンは `Resources/TigerQuickLook.icns`(元データ `Resources/icon-source-1024.png`)。
`build.sh` が `Contents/Resources/` にコピーする。

開発の経緯・ハマった点・工夫した点は [`docs/開発ノート.md`](docs/開発ノート.md)
にまとめてある(自社Web公開用の下書きも兼ねる)。

配布ページ: https://oldmac.policy-log.jp/ (ダウンロードは GitHub Releases から)

## ライセンス

MIT License — [`LICENSE`](LICENSE) を参照。


## これは何か

Mac OS X 10.4 Tiger機の上でネイティブに動く、軽量なQuick Look代替アプリ。
Quick Look自体はLeopard(10.5)からの機能なので、Tigerには存在しない。

## 対応形式

「ちゃんと表示する」より **「タイトルだけでは思い出せないファイルの中身確認」**
が目的。整形せず中身の文字列が出れば十分、という割り切り。

| 種別 | 形式 | 方法 |
|---|---|---|
| 画像 | JPG / PNG / PDF / TIFF / GIF / BMP | ImageIO・Quartz を直接。PDF は1ページ目のみ |
| テキスト | TXT / MD / CSV / JSON / XML / 各種ソース等、拡張子を広く | 先頭64KBをそのまま等幅表示 |
| 拡張子なし | — | 中身がテキストっぽければテキスト表示 |
| 旧 Office | **DOC** (Word 2004等) / RTF / HTML | Tiger 標準の `textutil -convert txt` |
| 新 Office | **DOCX / PPTX / XLSX** / ODT / ODS / ODP | ZIP から本文XMLを `unzip -p` → タグ除去 |

対応しないもの: RAW、レイアウトの再現、複数ページ・複数シートの網羅。
追加ライブラリは使わない(外部依存は Tiger 同梱の `textutil` / `unzip` のみ)。

## なぜやる価値があるか

Windowsのプレビューウィンドウは小さすぎて文字が読めない。Quick Lookはある程度の
大きさで出るので、文字が読めて、アプリを開かなくてもタイトルや要点が分かる。
これをTiger機でも実現したい。

**最優先の制約: 重くならないこと。** 実機はiBook G4、~1.2GHz・1.25GB RAMという
非力なマシン。QuickLookもどきのせいで実機全体が重くなるなら本末転倒なので、
やらない・削る判断を優先する。

## なぜAquaFinder側ではなくTigerネイティブなのか

一時、AquaFinder(現行Macで動く、Snow Leopard風Finder再現アプリ)の目玉機能として
組み込む案も検討したが、AquaFinderは既にApple純正の`QLPreviewPanel`/
`QLThumbnailGenerator`を使った本物のQuick Look(⌘Y)を持っており、対応フォーマット
はJPG/PDF/PNG/TXTどころか全形式をカバー済み。つまりAquaFinder側に大きく追加できる
余地は実質ない。

対してTiger実機側にはQuick Look相当の機能が何もない。本当に足りていないのは
こちら側なので、Tigerネイティブの実装を優先する。

## 技術環境

`ppc_claude_cli`プロジェクトと同じ実機・同じワークフローを流用する。

- **実機**: iBook G4 (PowerBook6,5)、~1.2GHz CPU、1.25GB RAM
- **OS**: Mac OS X 10.4.11 (Tiger)、Darwin 8.11.0
- **開発ツール**: gcc 4.0.0 / make 3.80 / Perl 5.8.6(OS標準)
- **SSH接続**: `ssh ibook` で接続可能(2026-08-29時点で確認済み)
- **ビルド方針**: ソースは現行Macで取得し`scp`で転送、**実際のビルドはiBook実機上で
  行う**(`ppc_claude_cli`のOpenSSL/curlビルドと同じ考え方 — クロスコンパイルでは
  なく実機のPPCで本当にビルドする)

## 進め方

- このプロジェクトは独立したスレッド(このディレクトリ `~/developer/OSX_QuickLook`)
  で進める。AquaFinderの会話とは分離する。
- ソースはこのMacで編集し、`scp`でiBookに転送、`ssh ibook`上で`build.sh`を実行して
  実機ビルドする。GUIの見た目は基本的に実機の画面を見てもらって確認している
  (`screencapture`をSSH経由で動かそうとしたが、WindowServerとの接続が
  ssh越しのプロセスからは張れず、`-x`付きでも無音でファイルが生成されない — 原因
  未特定のまま棚上げ中。`open -a`でアプリ自体をコンソールセッションに起動させる
  ことはできる — これはLaunch Servicesがloginwindow/Finder経由でリレーしてくれる
  ため — が、画面を「見る」手段はまだない)。

## 実装状況(2026-09-07時点)

`src/main.m` 1ファイルで完結。`build.sh`でgcc直接ビルド(xcodebuildはこの実機では
`DevToolsSupport.framework`が見つからず壊れているため使わない)。

- **JPG/PNG**: `CGImageSourceCreateThumbnailAtIndex`でプレビューサイズに縮小
  デコードしてから`CGContextDrawImage`で描画。フル解像度は一切デコードしない。
- **PDF**: `CGPDFDocumentCreateWithURL`→`CGPDFDocumentGetPage`→
  `CGPDFPageGetDrawingTransform`+`CGContextDrawPDFPage`で1ページ目だけをその場描画。
  PDFKitは使っていない(Tigerに存在しないため)。
- **TXT**: `NSFileHandle`で先頭64KBだけ読み、`NSTextView`(編集不可)に表示。
- ウィンドウは`NSResizableWindowMask`でドラッグ拡大縮小可能。初期サイズは
  内容に合わせて自動計算(画像/PDFは最大760×600に収める、TXTは実際の行数・
  文字数に応じて最小300×120〜最大380×600)。
- 先読み(prefetch)は一切しない。
- **単発モード**: ファイルパスを引数に起動。ウィンドウを閉じるとアプリごと
  終了する使い捨て。
- **エージェントモード**: 引数なし(または`--agent`)で起動。`LSUIElement`で
  Dockアイコンを持たず常駐、メニューバーに「QL」ステータス項目(終了用)。
  `CGEventTap`(`kCGSessionEventTap`, head-insert)で修飾なしSpaceのキーダウンを
  監視し、「Finderが最前面 かつ プレビュー非表示」のときだけ横取りして、
  `NSAppleScript`でFinderの選択項目を取得しプレビュー。表示中のSpace/Escで閉じる。
  Finderへのフォーカス返却は`-[NSWorkspace launchApplication:@"Finder"]`。
  タップが`kCGEventTapDisabledByTimeout`で無効化されたら貼り直す。
- **タップは常時有効にはしない。** アクティブなイベントタップをキーイベントが
  通過すると、WindowServerがそのイベントを現在の入力ソースで確定してしまい、
  日本語入力が有効なとき`Terminal`等(`[event characters]`を直接読むアプリ)で
  Spaceが全角スペース(U+3000)になる副作用がある(実機で確認)。対策として、
  0.3秒ごとのポーリング(`NSTimer`)で「Finderが最前面 or プレビュー表示中」の
  ときだけ`CGEventTapEnable`する。10.4には最前面アプリ変化を知らせる
  NSWorkspace通知(`NSWorkspaceDidActivateApplicationNotification`は10.6以降)が
  無いためポーリングにしている。副作用として、Finderへ切り替えた直後の
  最大0.3秒はSpaceが効かない。
- ユーザーに見える日本語文字列は`[NSString stringWithUTF8String:]`経由で作る。
  GCC 4.0は`@"..."`リテラル内の非ASCIIを実行時エンコーディングで解釈し、
  メニュー等が文字化けするため。

### PDFの重さについて(2026-09-09 実測)

`heavy_scan_1page.pdf`(1ページに2550×3300のスキャン画像を埋め込んだPDF、
5.4MB)を実機で確認: 開くのにひと呼吸、ドラッグリサイズの追従は「もたつく」
が許容範囲。CPUは瞬間的に100%、通常60%程度。**多ページPDF(252ページ)は
ファイルサイズによらず一瞬** — `CGPDFDocumentCreateWithURL`はページを遅延
パースするため、効くのは「1ページ目の中身の複雑さ」だけ。
オフスクリーンのビットマップキャッシュ案は検討したが、この体感なら
投機的に足す理由がないと判断し**見送り**(現状の`drawRect:`で毎回
`CGContextDrawPDFPage`する素朴な実装のまま)。

### ハマった点(次に読む人向け)

- **`CGFloat`型がTiger SDKに存在しない。** 64ビット移行(Leopard以降)で
  導入された型で、Tigerでは単に`float`を使う。
- **`CGPDFPageRef`は親の`CGPDFDocumentRef`を生かし続けてくれない。**
  ページだけ`CGPDFPageRetain`してdocumentを`CGPDFDocumentRelease`すると、
  後から`CGPDFPageGetBoxRect`等でページにアクセスした際に解放済みメモリを
  指してEXC_BAD_ACCESSでクラッシュする(実機で確認済み)。documentごと
  保持し、必要なたびに`CGPDFDocumentGetPage`でページを取り直すこと。
- **`xcodebuild`はこの実機では動かない**(`DevToolsSupport.framework`が
  見つからない)。`gcc -isysroot /Developer/SDKs/MacOSX10.4u.sdk ...`で
  直接コンパイル・リンクする。`-isysroot`を付けないと、ライブシステムの
  `/System/Library/Frameworks`側のヘッダが一部欠けていて
  (`ImageIO/ImageIO.h`等が見つからない)コンパイルできない。
- **`open --args`は使えない**(この`open`のバージョンが古く、そのオプションを
  認識しない)。`open -a App.app file`の形なら、Finderの
  `-[NSApplication application:openFile:]`経由で正しくファイルを渡せる。
- **実行ファイルをパスで直接execするとGUIセッションに登録されない。**
  SSH越しはもちろん、実機のTerminalから`.../MacOS/TigerQuickLook`と叩いても、
  LaunchServicesを通らないため`LSUIElement`が適用されず、NSStatusItem・
  Finderへの`NSAppleScript`・プレビューウィンドウがすべて無反応になる
  (`CGEventTap`だけは低レベルなので動いてしまい、切り分けを誤りやすい)。
  必ず`open App.app`(またはダブルクリック/ログイン項目)から起動する。
- **AppKitは直接exec時の引数を`application:openFile:`へ流し込むことがある。**
  `--agent`が「開くファイル」として渡ってきて単発モードに落ちた。対策として
  `application:openFile:`で`-`始まり・非実在パスを弾き、`--agent`明示時は
  グローバルフラグでエージェントモードを強制、`applicationDidFinishLaunching:`
  でも「実在するファイルが渡された時だけ単発モード」に絞っている。

## 今後

- **2026-09-09: エージェントモードを実機で検証済み。** iBook G4 / 10.4.11 で
  6項目とも確認: Finder+Space→プレビュー、Space/Escで閉じてフォーカス復帰、
  Terminal/TextEditでSpaceは正常(全角化しない)、Finder復帰後も再度使える、
  「QL」メニューから終了。実用上の速度も問題なし。
- リネーム編集中のSpace誤爆(既知の制限)がどの程度うっとうしいか、使いながら様子見
- 配布用に `必ずお読みください.txt` を同梱した zip / dmg を作る
- ログイン項目に入れての常用テスト
- `screencapture`をこちらから直接使えない問題は、必要になったら深追いする

## 関連プロジェクト

- `~/developer/ppc_claude_cli` — 同じiBook G4上で動く、Perl製の軽量Claude/Gemini
  エージェント。TLS 1.2対応のためOpenSSL/curlを実機ビルドした実績あり。
  `ssh ibook`もこのプロジェクトの副産物。
- `~/developer/AquaFinder` — 現行Mac向けのSnow Leopard風Finder再現アプリ。
  既に本物のQuick Look機能を持っている(このプロジェクトのきっかけになった会話の舞台)。
- `~/developer/minato` — 構想段階。Tiger機をブラウザ完結型のNASにする別プロジェクト。
- `~/developer/AquaLink` — Tiger機をNAS化する既存プロジェクト(`LocalWebDAVServer`)。
