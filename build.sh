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
mkdir -p "$APP_DIR/Contents/MacOS"

cp "$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"

echo "==> Done: $APP_DIR"
echo "    動作確認: open $APP_DIR --args /path/to/test.jpg"
echo "    または:   $APP_DIR/Contents/MacOS/$APP_NAME /path/to/test.jpg"
