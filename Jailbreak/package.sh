#!/bin/bash
# 把 App 打成越狱环境用的安装包：编译 → 用 ldid 签上特殊权限 → 打成 .ipa
# 用法：在项目根目录运行  ./Jailbreak/package.sh
set -euo pipefail

cd "$(dirname "$0")/.."
[ -f Jailbreak/local.env ] && source Jailbreak/local.env
TEAM_ID="${TEAM_ID:?请先在 Jailbreak/local.env 里设置 TEAM_ID（参考 local.env.example）}"
OUT="Jailbreak/build"
rm -rf "$OUT"
mkdir -p "$OUT"

echo "==> 编译（Release，不签名；用 prefix-map 把本机路径从产物里抹掉）"
xcodebuild -project SSH.xcodeproj -scheme SSH -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath "$OUT/dd" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  OTHER_CFLAGS="-ffile-prefix-map=$PWD=/src" \
  build | tail -3

APP="$OUT/dd/Build/Products/Release-iphoneos/SSH.app"
[ -d "$APP" ] || { echo "没找到编译出来的 SSH.app"; exit 1; }

# 每次打包放一个唯一编号，部署后到手机上读出来对比，确认装进去的真是这一版
echo "$(git rev-parse --short HEAD 2>/dev/null || echo nogit)-$(date +%s)" > "$APP/BuildStamp.txt"

# 剥掉调试符号：里面带着编译这台电脑上的文件路径（含用户名），发出去会泄漏
echo "==> 剥掉调试符号"
find "$APP" -type f \( -name "*.dylib" -o -path "*.framework/*" -o -path "$APP/SSH" \) -perm -u+x -print0 | while IFS= read -r -d '' item; do
  strip -S -x "$item" 2>/dev/null || true
done

echo "==> 用 ldid 签上特殊权限"
# 先签里面的动态库和框架，最后签主程序
find "$APP" \( -name "*.dylib" -o -name "*.framework" \) -print0 | while IFS= read -r -d '' item; do
  ldid -S "$item" 2>/dev/null || true
done
# 权限文件里的 TEAM_ID 换成你自己的
sed "s/TEAM_ID/$TEAM_ID/g" Jailbreak/SSH.entitlements > "$OUT/SSH.entitlements"
ldid -S"$OUT/SSH.entitlements" "$APP/SSH"

echo "==> 打成 ipa"
mkdir -p "$OUT/Payload"
cp -R "$APP" "$OUT/Payload/"
(cd "$OUT" && zip -qry SSH.ipa Payload)

echo
echo "完成：$OUT/SSH.ipa"
echo "把它传到手机上安装（见 Jailbreak/README.md）"
