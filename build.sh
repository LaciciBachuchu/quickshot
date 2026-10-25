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
# 有本机签名证书（./setup-signing.sh 生成）就用它签名，签名身份固定，屏幕录制权限不会每次编译都失效；
# 没有就退回临时签名
SIGN_ID=$(security find-identity -p codesigning 2>/dev/null | awk -F'"' '/QuickShot Local Signing/{print $2; exit}')
codesign --force -s "${SIGN_ID:--}" "$APP"
open "$APP"
echo "已安装并启动：$APP"
