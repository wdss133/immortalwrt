#!/usr/bin/env bash
#
# release.sh —— 小米 CR6608 固件「发布」脚本（与 workflow 解耦，便于 fork / 换分支复用）
#
# 职责：
#   1) 依据固件清单与构建阶段产物生成发布说明（含插件版本号与上游更新日期）；
#   2) 每次编译创建一个「时间戳 tag」Release：<PREFIX>-YYYYMMDD-HHMM（北京时间）；
#   3) 同时维护滚动 Release <PREFIX>-latest，下载链接固定，永远指向最新固件；
#   4) 清理旧 Release，保留规则（取并集，全部保住）：
#        - 滚动 <PREFIX>-latest
#        - 最近 KEEP_RECENT 个时间戳 Release（默认 36）
#        - 每个月的最后一次编译（月度归档）
#        - 当天的全部编译
#      只删除时间戳格式的本前缀 Release，绝不动其它 tag。
#
# 用法：
#   release.sh <artifact_dir> [tag_prefix] [keep_recent]
# 环境变量：
#   GH_TOKEN            必填（contents:write），gh CLI 使用
#   GITHUB_REPOSITORY   必填（owner/repo）；本地调试可用 REPO 覆盖
#   TAG_TZ              可选，tag 使用哪个时区的时间戳，默认 Asia/Shanghai
#   VERSION_KERNEL      可选，写入发布说明
#   SOURCE_REPO/SOURCE_BRANCH/SOURCE_COMMIT 可选，写入发布说明
#
set -Eeuo pipefail

ART_DIR="${1:?用法: release.sh <artifact_dir> [tag_prefix] [keep_recent]}"
PREFIX="${2:-CR6608}"
KEEP_RECENT="${3:-${KEEP_RECENT:-36}}"
REPO="${REPO:-${GITHUB_REPOSITORY:-}}"
TAG_TZ="${TAG_TZ:-Asia/Shanghai}"
VERSION_KERNEL="${VERSION_KERNEL:-unknown}"
SOURCE_REPO="${SOURCE_REPO:-https://github.com/wdss133/immortalwrt.git}"
SOURCE_BRANCH="${SOURCE_BRANCH:-openwrt-24.10}"
DEVICE_NAME="${DEVICE_NAME:-${DEVICE:-xiaomi_mi-router-cr6608}}"
MTK_WIFI="${MTK_WIFI:-on}"

log() { printf '[release] %s\n' "$*"; }
die() { printf '[release][error] %s\n' "$*" >&2; exit 1; }

[ -d "$ART_DIR" ] || die "artifact 目录不存在: $ART_DIR"
[ -n "$REPO" ] || die "需要 GITHUB_REPOSITORY（或 REPO）"
command -v gh >/dev/null 2>&1 || die "未找到 gh CLI"

STAMP="$(TZ="$TAG_TZ" date '+%Y%m%d-%H%M')"
TODAY="$(TZ="$TAG_TZ" date '+%Y%m%d')"
NOW="$(TZ="$TAG_TZ" date '+%Y-%m-%d %H:%M')"
TS_TAG="${PREFIX}-${STAMP}"
LATEST_TAG="${PREFIX}-latest"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

############################ 1) 组装发布说明 ############################

PLUGINS_MD="$(ls "$ART_DIR"/*.plugins.md 2>/dev/null | head -n1 || true)"
SRC_TXT="$(ls "$ART_DIR"/third-party-sources.txt 2>/dev/null | head -n1 || true)"
COMMIT_TXT="$(ls "$ART_DIR"/source-commit.txt 2>/dev/null | head -n1 || true)"

SOURCE_COMMIT="（未知）"
[ -n "${SOURCE_COMMIT:-}" ] && SOURCE_COMMIT="$SOURCE_COMMIT"
[ -n "$COMMIT_TXT" ] && SOURCE_COMMIT="$(head -n1 "$COMMIT_TXT" | tr -d '\r')"

case "$MTK_WIFI" in
  on)       WIFI_DESC="MTK 闭源 mt_wifi 驱动 + luci-app-mtk（MT7621 原厂方案）" ;;
  fallback) WIFI_DESC="开源 mt76/wpad（MTK 闭源驱动未进入最终配置，已自动回退）" ;;
  off)      WIFI_DESC="开源 mt76/wpad（按配置选择）" ;;
  *)        WIFI_DESC="${MTK_WIFI}" ;;
esac

BODY="$WORK/body.md"
{
  echo "## 小米 CR6608 固件（自动编译）"
  echo ""
  echo "> 🔗 **滚动 latest**：[\`${LATEST_TAG}\`](https://github.com/${REPO}/releases/tag/${LATEST_TAG}) 下载链接固定，永远指向最新固件。"
  echo "> 本页为时间戳版本 **\`${TS_TAG}\`**（北京时间 ${NOW}）。"
  echo ""
  echo "### 📒 固件信息"
  echo "- 源码：\`${SOURCE_REPO}\`（分支 \`${SOURCE_BRANCH}\`）"
  echo "- 源码提交：\`${SOURCE_COMMIT}\`"
  echo "- 目标机型：\`${DEVICE_NAME}\`（MT7621 · ramips/mt7621 · 内核 **${VERSION_KERNEL}**）"
  echo "- 无线方案：**${WIFI_DESC}**"
  echo "- 硬件加速：内核自带 MTK PPE（\`CONFIG_NET_MEDIATEK_SOC\`）+ nft 流卸载"
  echo "- 默认主题：**argon**（已确保无 Aurora 主题）"
  echo "- 默认地址：**192.168.1.1**"
  echo "- 编译时间：${NOW}"
  echo ""
  echo "### 🧩 内置插件（编译时从上游拉取的版本）"
  echo ""
  echo "<!--PLUGINS:BEGIN-->"
  if [ -n "$PLUGINS_MD" ]; then
    cat "$PLUGINS_MD"
  else
    echo "（未采集到插件信息）"
  fi
  echo "<!--PLUGINS:END-->"
  echo ""
  echo "### 📌 第三方源快照"
  echo ""
  if [ -n "$SRC_TXT" ]; then
    echo '| 仓库 | 分支 | 提交 | 上游最后提交日期 |'
    echo '|---|---|---|---|'
    tail -n +2 "$SRC_TXT" | awk -F'\t' 'NF>=3{printf "| %s | %s | `%s` | %s |\n", $1, $2, substr($3,1,10), ($4==""?"-":$4)}'
  else
    echo "（无第三方源记录）"
  fi
  echo ""
  NOT_BUILT="$(ls "$ART_DIR"/*.not-built.txt 2>/dev/null | head -n1 || true)"
  if [ -n "$NOT_BUILT" ]; then
    echo "### ⚠️ 本次未编入的包"
    echo ""
    echo "以下包因上游变更（如要求的 Go 版本高于本分支自带版本、依赖缺失）无法编译，"
    echo "已自动剔除以保证固件可产出；其余功能不受影响。"
    echo ""
    echo '```'
    sort -u "$NOT_BUILT"
    echo '```'
    echo ""
  fi
  echo "### 🗂 Release 保留策略"
  echo "- 每次编译生成一个时间戳 tag：\`${PREFIX}-YYYYMMDD-HHMM\`（北京时间）"
  echo "- 同时更新滚动 \`${LATEST_TAG}\`"
  echo "- 自动清理：保留 \`latest\` + 最近 **${KEEP_RECENT}** 个时间戳版本 + 每月最后一次编译 + 当天全部"
  echo ""
  echo "### 🚀 刷机"
  echo "- 已刷过 OpenWrt / ImmortalWrt：\`sysupgrade -n <...squashfs-sysupgrade.bin>\`，或 LuCI「系统 → 备份/刷写固件」，首刷建议不保留配置"
  echo "- 原厂固件：先用 \`...initramfs-kernel.bin\` 经 Breed / U-Boot 中转，再 \`sysupgrade\` 到 squashfs 版本"
} > "$BODY"
log "发布说明已生成: $BODY"

############################ 2) 发布 / 更新 Release ############################

publish() {
  local tag="$1" title="$2"
  if gh release view "$tag" --repo "$REPO" >/dev/null 2>&1; then
    gh release edit "$tag" --repo "$REPO" --title "$title" --notes-file "$BODY"
    gh release upload "$tag" "$ART_DIR"/* --repo "$REPO" --clobber
    log "已更新 Release: $tag"
  else
    gh release create "$tag" "$ART_DIR"/* --repo "$REPO" --title "$title" --notes-file "$BODY"
    log "已创建 Release: $tag"
  fi
}

# 同一分钟重复触发（手动重跑）时追加秒数，避免 tag 冲突
if gh release view "$TS_TAG" --repo "$REPO" >/dev/null 2>&1; then
  TS_TAG="${PREFIX}-$(TZ="$TAG_TZ" date '+%Y%m%d-%H%M%S')"
  log "时间戳 tag 已存在，改用 $TS_TAG"
fi

publish "$TS_TAG" "${PREFIX} ${STAMP}"
publish "$LATEST_TAG" "${PREFIX} latest（最新固件）"

############################ 3) 清理旧 Release ############################

mapfile -t TS_TAGS < <(
  gh release list --repo "$REPO" --limit 500 --json tagName --jq '.[].tagName' \
  | grep -E "^${PREFIX}-[0-9]{8}-[0-9]{4}$" | sort -r || true
)

declare -A KEEP=()
KEEP["$LATEST_TAG"]=1

i=0
for t in "${TS_TAGS[@]:-}"; do
  [ -n "$t" ] || continue
  [ "$i" -lt "$KEEP_RECENT" ] && KEEP["$t"]=1
  i=$((i + 1))
done

# 每个月的最后一次编译（TS_TAGS 已按时间倒序，每个 YYYYMM 的首次出现即该月最后一次）
declare -A MONTH_SEEN=()
for t in "${TS_TAGS[@]:-}"; do
  [ -n "$t" ] || continue
  d="${t#${PREFIX}-}"; m="${d:0:6}"
  if [ -z "${MONTH_SEEN[$m]:-}" ]; then
    KEEP["$t"]=1
    MONTH_SEEN[$m]=1
  fi
done

for t in "${TS_TAGS[@]:-}"; do
  [ -n "$t" ] || continue
  d="${t#${PREFIX}-}"
  case "$d" in "${TODAY}-"*) KEEP["$t"]=1 ;; esac
done

log "时间戳版本共 ${#TS_TAGS[@]} 个，月度归档 ${#MONTH_SEEN[@]} 个月，保留 ${#KEEP[@]} 个 Release"

for t in "${TS_TAGS[@]:-}"; do
  [ -n "$t" ] || continue
  [ -n "${KEEP[$t]:-}" ] && continue
  log "删除旧 Release: $t"
  gh release delete "$t" --repo "$REPO" --yes --cleanup-tag || true
done

legacy="$(gh release list --repo "$REPO" --limit 500 --json tagName --jq '.[].tagName' \
  | grep -E "^${PREFIX}(-|$)" | grep -vE "^${PREFIX}-[0-9]{8}-[0-9]{4}$" | grep -vx "$LATEST_TAG" || true)"
if [ -n "$legacy" ]; then
  log "以下非时间戳格式的旧 Release 已保留（如需删除请手动处理）：$(printf '%s' "$legacy" | tr '\n' ' ')"
fi

log "完成：本次时间戳 tag = ${TS_TAG}"
