#!/bin/bash
# 一条命令把最新版推到越狱手机上：打包 → 传到手机 → 用 TrollStoreLite 安装 → 启动
# 用法：./Jailbreak/deploy.sh            （重新打包并安装）
#       ./Jailbreak/deploy.sh --no-build （直接装已经打好的 ipa）
# 前提：手机开着 SSH，并且这台电脑的公钥已经加到手机 root 的 authorized_keys 里
# 手机地址写在 Jailbreak/local.env 里（见 local.env.example），或者用环境变量 PHONE_HOST
set -euo pipefail

cd "$(dirname "$0")/.."
[ -f Jailbreak/local.env ] && source Jailbreak/local.env
HOST="${PHONE_HOST:?请先在 Jailbreak/local.env 里设置 PHONE_HOST（参考 local.env.example）}"
BUNDLE_ID="thexyrith.SSH"
IPA="Jailbreak/build/SSH.ipa"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=8)

if [ "${1:-}" != "--no-build" ]; then
  ./Jailbreak/package.sh
fi
[ -f "$IPA" ] || { echo "没有 $IPA，先不带参数运行一次"; exit 1; }

echo "==> 连接手机"
ssh "${SSH_OPTS[@]}" "$HOST" true || { echo "连不上 $HOST（手机亮屏、同一个 Wi-Fi、SSH 开着？）"; exit 1; }

# roothide 下同一个路径有两个视角：scp 和 ssh 里的命令走"映射后"的路径，
# 安装工具读的是真实路径。所以文件要写到 /rootfs/ 下面（真实位置），
# 安装工具则读不带 /rootfs 的写法，两边才是同一个文件。
REMOTE_REAL="/rootfs/var/mobile/Documents/SSH.ipa"
REMOTE_ARG="/var/mobile/Documents/SSH.ipa"

echo "==> 传输 ipa"
scp -q "${SSH_OPTS[@]}" "$IPA" "$HOST:$REMOTE_REAL"
SENT=$(stat -f %z "$IPA")
GOT=$(ssh "${SSH_OPTS[@]}" "$HOST" "stat -c %s $REMOTE_REAL 2>/dev/null || ls -l $REMOTE_REAL | awk '{print \$5}'")
[ "$SENT" = "$GOT" ] || { echo "传过去的文件大小不对（本地 $SENT，手机 $GOT）"; exit 1; }

echo "==> 安装（TrollStoreLite）"
ssh "${SSH_OPTS[@]}" "$HOST" "
  J=\$(ls -d /var/containers/Bundle/Application/.jbroot-* | head -1)
  H=\"\$J/Applications/TrollStoreLite.app/trollstorehelper\"
  [ -x \"\$H\" ] || { echo '手机上没找到 trollstorehelper'; exit 2; }
  \"\$H\" install $REMOTE_ARG 2>&1 | grep -E 'returning'
  code=\${pipestatus[1]}
  rm -f $REMOTE_REAL $REMOTE_ARG
  [ \"\$code\" = '0' ] || { echo \"安装失败，错误码 \$code\"; exit \$code; }
"

echo "==> 核对手机上装的是不是这一版"
WANT=$(unzip -p "$IPA" Payload/SSH.app/BuildStamp.txt | tr -d '\n')
APP_DIR=$(ssh "${SSH_OPTS[@]}" "$HOST" "find /var/containers/Bundle/Application -maxdepth 2 -name SSH.app | head -1")
HAVE=$(ssh "${SSH_OPTS[@]}" "$HOST" "cat $APP_DIR/BuildStamp.txt 2>/dev/null" | tr -d '\n')
if [ "$WANT" != "$HAVE" ]; then
  echo "手机上装的不是这一版（要 $WANT，实际 ${HAVE:-没有}）"
  exit 1
fi
echo "确认：手机上是 $HAVE"

echo "==> 启动"
DEVICE="$(xcrun devicectl list devices 2>/dev/null | awk '/connected/ {print $3; exit}')"
if [ -n "${DEVICE:-}" ]; then
  xcrun devicectl device process launch --device "$DEVICE" --terminate-existing "$BUNDLE_ID" 2>&1 | tail -1
else
  echo "（没有通过数据线连着的设备，请在手机上手动打开）"
fi
echo "完成"
