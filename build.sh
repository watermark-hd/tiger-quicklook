#!/bin/sh
# TigerQuickLook.app をビルドするスクリプト。
#
# xcodebuild自体がこの実機では壊れている(DevToolsSupport.frameworkが
# 見つからない)ため、Xcodeプロジェクト形式には頼らず、gccで直接
# コンパイル・リンクし、.appバンドルを手で組み立てる。
# AquaFinderのmake-app-bundle.shと同じ考え方。
#
# 必ずiBook実機の上で実行すること(クロスコンパイルはしない —
# ppc_claude_cliと同じ「実機で本当にビルドする」方針)。

set -e

cd "$(dirname "$0")"

APP_NAME=TigerQuickLook
SDK=/Developer/SDKs/MacOSX10.4u.sdk
APP_DIR="$APP_NAME.app"

echo "==> Compiling"
gcc -isysroot "$SDK" -Wall -O2 \
    -o "$APP_NAME" \
    src/main.m \
    -framework Cocoa \
    -framework ApplicationServices

echo "==> Assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
# アイコンは「クラシック」形式の .icns (is32/il32/ih32/it32 + マスク、最大128px)。
# 現行 macOS の iconutl が作る PNG ベースの .icns (ic07/ic08/...) は Tiger の
# Finder が解釈できず、アイコンが真っ白になる。作り直すときは libicns の
# png2icns を使う:  png2icns TigerQuickLook.icns 16.png 32.png 48.png 128.png
#   (元PNGは Resources/icon-src/ にある)
cp Resources/TigerQuickLook.icns "$APP_DIR/Contents/Resources/TigerQuickLook.icns"
printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"

echo "==> Done: $APP_DIR"
echo
echo "    単発プレビュー:"
echo "      open -a $APP_DIR /path/to/test.jpg"
echo
echo "    常駐エージェント(Finderで選択して Space):"
echo "      open $APP_DIR"
echo "      ※ 必ず open / ダブルクリック / ログイン項目から起動する。"
echo "         実行ファイルを直接叩くと GUI セッションに登録されず無反応。"
echo "      ※ 事前に システム環境設定 →「ユニバーサルアクセス」→"
echo "         「補助装置にアクセスできるようにする」にチェックが必要"
echo "      ※ 終了は メニューバー「QL」 または killall $APP_NAME"
