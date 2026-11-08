#!/bin/zsh
# 构建并打包 收纳篮.app（输出到 build/MenuBasket.app）
set -euo pipefail
cd "$(dirname "$0")"

# ./build.sh --debug-ipc：额外编译调试命令接口（仅供开发测试，见 dev-cmd.sh）。正式构建不要加。
FLAGS=()
if [[ "${1:-}" == "--debug-ipc" ]]; then
  FLAGS=(-D DEBUG_IPC)
  echo "⚠️  开发构建：包含调试命令接口"
fi

# Command Line Tools 自带的默认 SDK 可能比编译器新，挑一个与当前 swiftc 匹配的 26.x SDK。
SDK=$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.*.sdk 2>/dev/null | sort -V | tail -1)
[[ -n "$SDK" ]] || { echo "找不到 macOS 26 SDK"; exit 1; }

mkdir -p build
swiftc -O "${FLAGS[@]}" -sdk "$SDK" -target arm64-apple-macos14.0 -swift-version 5 \
  -framework AppKit -framework ApplicationServices -framework ServiceManagement \
  Sources/MenuBasket/*.swift -o build/MenuBasket-bin

APP=build/MenuBasket.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/MenuBasket-bin "$APP/Contents/MacOS/MenuBasket"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# 用固定的自签名证书签名，这样重新构建后系统授予的权限不会失效。
KEYCHAIN="$PWD/.signing/menubasket.keychain-db"
IDENTITY="MenuBasket Local Signing"
if [[ -f "$KEYCHAIN" ]]; then
  security unlock-keychain -p menubasket "$KEYCHAIN"
  # codesign 只在钥匙串搜索列表中找身份：临时加入，签完立即恢复原列表。
  ORIGINAL=("${(@f)$(security list-keychains -d user | sed -e 's/^ *"//' -e 's/"$//')}")
  trap 'security list-keychains -d user -s "${ORIGINAL[@]}"' EXIT
  security list-keychains -d user -s "${ORIGINAL[@]}" "$KEYCHAIN"
  HASH=$(security find-identity -p codesigning "$KEYCHAIN" | awk -v n="\"$IDENTITY\"" '$0 ~ n {print $2; exit}')
  codesign --force --sign "$HASH" --keychain "$KEYCHAIN" "$APP"
else
  echo "未找到 .signing/，使用临时签名（每次重新构建都需要重新授权）"
  codesign --force --sign - "$APP"
fi
codesign -dvv "$APP" 2>&1 | grep -E "Identifier|Authority|Signature" || true
echo "构建完成：$APP"
