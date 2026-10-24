#!/bin/zsh
# 编译并安装到 ~/Applications/QuickShot.app，然后重新启动
set -e
cd "$(dirname "$0")"
APP="$HOME/Applications/QuickShot.app"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
swiftc -O -o "$APP/Contents/MacOS/quickshot.new" *.swift
pkill -f "\.app/Contents/MacOS/quickshot" 2>/dev/null || true   # 也会关掉改名前的旧版
mv "$APP/Contents/MacOS/quickshot.new" "$APP/Contents/MacOS/quickshot"
codesign --force -s - "$APP"
open "$APP"
echo "已安装并启动：$APP"
