# OSX Tiger QuickLook

2026-08-29、AquaFinder開発中の雑談から派生。「NASやUSB経由でのファイル閲覧に、
テキストが読める程度の大きさのプレビューが欲しい」という話から、Tiger実機向けの
軽量なQuick Look代替を作る方向で合意した。

**2026-09-07時点: JPG/PNG/PDF/TXTの4形式とも実機で動作確認済み。** ウィンドウは
ドラッグでリサイズ可能。詳細は下の「進捗」を参照。

## これは何か

Mac OS X 10.4 Tiger機の上でネイティブに動く、軽量なQuick Look代替アプリ。
Quick Look自体はLeopard(10.5)からの機能なので、Tigerには存在しない。

対応フォーマットは意図的に絞る。**深追いしない。**

- JPG
- PDF
- PNG
- TXT

これ以上は広げない。

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
- ウィンドウを閉じるとアプリごと終了する使い捨て設計。先読み(prefetch)は
  一切しない。

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
- **SSH越しに直接execしたGUIアプリはWindowServerに繋がらない。**
  (`CFMessagePortCreateLocal failed`のエラーでコンソールに何も出ない)。
  `open -a`を使うと、loginwindow/Finder経由でコンソールセッションに
  正しく起動できる。

## 今後

- 大きな/長いPDFやTXTでの体感速度を確認する(まだ小さいテストファイルでしか
  試していない)
- Finderで「このアプリで開く」に指定して使う導線を試す
  (`CFBundleDocumentTypes`は`Resources/Info.plist`に用意済み、未検証)
- `screencapture`をこちらから直接使えない問題を、必要になったら深追いする
  (今のところ実害はない — 実機の画面を見てもらえば十分)

## 関連プロジェクト

- `~/developer/ppc_claude_cli` — 同じiBook G4上で動く、Perl製の軽量Claude/Gemini
  エージェント。TLS 1.2対応のためOpenSSL/curlを実機ビルドした実績あり。
  `ssh ibook`もこのプロジェクトの副産物。
- `~/developer/AquaFinder` — 現行Mac向けのSnow Leopard風Finder再現アプリ。
  既に本物のQuick Look機能を持っている(このプロジェクトのきっかけになった会話の舞台)。
- `~/developer/minato` — 構想段階。Tiger機をブラウザ完結型のNASにする別プロジェクト。
- `~/developer/AquaLink` — Tiger機をNAS化する既存プロジェクト(`LocalWebDAVServer`)。
