#!/usr/bin/env bash
#
# fallback-openwrt-wifi.sh —— MTK 闭源无线未能进入最终配置时，回退到开源 mt76/wpad
#
# 由 workflow 的「Generate Final Config」步骤在检测到 CONFIG_PACKAGE_kmod-mt7915 未选中时调用。
# 作用：把被 customize.sh 关掉的开源无线栈恢复回来，保证一定能产出可刷的固件。
#
# 运行位置：OpenWrt 源码树根目录
#
set -Eeuo pipefail

MAIN_CONFIG="${MAIN_CONFIG:-$PWD/.config}"
DEVICE="${DEVICE:-xiaomi_mi-router-cr6608}"
MTK_STATE_FILE="${MTK_STATE_FILE:-$PWD/ci-out/mtk-fallback.txt}"

log()  { printf '[fallback] %s\n' "$*"; }
warn() { printf '::warning::%s\n' "$*"; }

config_set() {
  local file="$1" symbol="$2" value="$3"
  [ -f "$file" ] || return 0
  if grep -Eq "^${symbol}=|^#[[:space:]]+${symbol}[[:space:]]+is[[:space:]]+not[[:space:]]+set" "$file"; then
    sed -i -E "s|^(${symbol})=.*|\1=${value}|; s|^#[[:space:]]+(${symbol})[[:space:]]+is[[:space:]]+not[[:space:]]+set|\1=${value}|" "$file"
  else
    printf '%s=%s\n' "$symbol" "$value" >> "$file"
  fi
}

log "回退到开源无线栈（mt76 / wpad）"

# 1) 关掉 MTK 闭源相关
for sym in kmod-mt7915 wifi-profile luci-app-mtk datconf-lua datconf kvcedit libkvcutil; do
  config_set "$MAIN_CONFIG" "CONFIG_PACKAGE_$sym" n
done

# 2) 恢复开源无线栈
config_set "$MAIN_CONFIG" CONFIG_PACKAGE_wpad-basic-mbedtls y
config_set "$MAIN_CONFIG" CONFIG_PACKAGE_kmod-mac80211 y
config_set "$MAIN_CONFIG" CONFIG_PACKAGE_kmod-mt7915e y
config_set "$MAIN_CONFIG" CONFIG_PACKAGE_wifi-scripts y

# 3) wifi-scripts 目录在 MTK 分支里被删过，从 git 恢复回来
if [ ! -d package/network/config/wifi-scripts ]; then
  if git rev-parse --git-dir >/dev/null 2>&1; then
    git checkout -f -- package/network/config/wifi-scripts 2>/dev/null \
      || warn "无法从 git 恢复 package/network/config/wifi-scripts"
  fi
  if [ -d package/network/config/wifi-scripts ]; then
    log "已恢复 package/network/config/wifi-scripts"
  else
    warn "package/network/config/wifi-scripts 仍缺失，请确认上游是否改名"
  fi
fi

# 4) 记录回退事实，供后续步骤与发布说明使用
mkdir -p "$(dirname "$MTK_STATE_FILE")"
printf 'fallback\n' > "$MTK_STATE_FILE"

log "回退完成，重新执行 make defconfig"
rm -rf tmp/.packageinfo tmp/.targetinfo tmp/.packageauxvars
make defconfig

if grep -q '^CONFIG_PACKAGE_wpad-basic-mbedtls=y' "$MAIN_CONFIG"; then
  log "开源无线栈已就位（wpad-basic-mbedtls=y）"
else
  warn "wpad-basic-mbedtls 仍未选中，请检查上游 DEFAULT_PACKAGES 变化"
fi
