#!/usr/bin/env bash
#
# release.sh —— ImmortalWrt IPQ807X 定制固件「发布」脚本
#
# 职责：
#   1) 依据固件清单与构建阶段产物生成发布说明（含各插件版本号与上游更新日期）。
#   2) 发布 / 更新：
#        - <PREFIX>-latest                       滚动最新（下载链接固定）
#        - <PREFIX>-YYYYMMDD-HHMM                本次编译的「时间戳 tag」新 Release
#   3) 清理旧 Release：只保留 latest + 最近 KEEP_DAYS 天内的时间戳 Release。
#
# 用法：
#   release.sh <artifact_dir> [tag_prefix] [keep_days]
# 环境变量：
#   GH_TOKEN            必填（contents:write），gh CLI 使用
#   GITHUB_REPOSITORY   必填（owner/repo）；本地调试可用 REPO 覆盖
#   VERSION_KERNEL      可选，写入发布说明
#   SOURCE_HASH         可选，源码树 commit，写入发布说明
#   SOURCE_BRANCH       可选，默认 openwrt-24.10
#   TARGET_ID           可选，默认 qualcommax_ipq807x
#
set -Eeuo pipefail

ART_DIR="${1:?用法: release.sh <artifact_dir> [tag_prefix] [keep_days]}"
PREFIX="${2:-IPQ807X-ImmortalWrt}"
KEEP_DAYS="${3:-30}"
REPO="${REPO:-${GITHUB_REPOSITORY:-}}"
SOURCE_BRANCH="${SOURCE_BRANCH:-openwrt-24.10}"
VERSION_KERNEL="${VERSION_KERNEL:-unknown}"
SOURCE_HASH="${SOURCE_HASH:-unknown}"
TARGET_ID="${TARGET_ID:-qualcommax_ipq807x}"

log() { printf '[release] %s\n' "$*"; }
die() { printf '[release][error] %s\n' "$*" >&2; exit 1; }

[ -d "$ART_DIR" ] || die "artifact 目录不存在: $ART_DIR"
[ -n "$REPO" ] || die "需要 GITHUB_REPOSITORY（或 REPO）"
command -v gh >/dev/null 2>&1 || die "未找到 gh CLI"

# 时间戳 tag：YYYYMMDD-HHMM（TZ 由 workflow 设为 Asia/Shanghai）
STAMP="$(date '+%Y%m%d-%H%M')"
LATEST_TAG="${PREFIX}-latest"
STAMP_TAG="${PREFIX}-${STAMP}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

############################ 1) 组装发布说明 ############################

ADDED_TABLE="$(cat "$ART_DIR"/*.plugins.md 2>/dev/null || echo '（未采集到插件信息）')"
MAN="$(ls "$ART_DIR"/*.manifest 2>/dev/null | head -n1 || true)"
NOW="$(date '+%Y-%m-%d %H:%M %Z')"

def_list=""; def_table=""
if [ -n "$MAN" ]; then
  while read -r name ver; do
    [ -n "$name" ] || continue
    case "$name" in
      luci-app-*|luci-theme-*) ;;
      *) continue ;;
    esac
    def_list="${def_list:+${def_list}、}${name}"
    def_table="${def_table}| ${name} | ${ver} | （随上游 feeds） | openwrt feeds |\n"
  done < <(awk 'NF>=3{print $1, $3}' "$MAN" 2>/dev/null || true)
else
  log "警告：未找到 *.manifest，默认内置清单将为空"
fi

FIRMWARE_LIST="$(cd "$ART_DIR" && ls -1 2>/dev/null | grep -vE '\.(plugins\.md|third-party-sources\.txt)$' | head -n 40 || true)"

BODY="$WORK/body.md"
{
  echo "> 🔗 **滚动 latest**：\`${LATEST_TAG}\` 下载链接固定，固件随每次编译更新为最新。"
  echo "> 本 Release 为 **时间戳快照**：\`${STAMP_TAG}\`。"
  echo ""
  echo "**ImmortalWrt IPQ807X 定制固件（自动编译发布）**"
  echo ""
  echo "### 📒 固件信息"
  echo "- 基于 [Heleguo/immortalwrt](https://github.com/Heleguo/immortalwrt) \`${SOURCE_BRANCH}\` 自动同步编译"
  echo "- 目标平台：**${TARGET_ID}**（内核 6.6，Qualcomm ath11k 无线）"
  echo "- 默认主题：**argon**（已移除 Aurora 主题及其配置插件）"
  echo "- 内核特性：已启用 **kmod-tun**（ZeroTier / EasyTier 依赖）"
  echo "- **默认内置**：${def_list:-（无）}"
  echo "- **本仓库新增内置**：kmod-tun、argon 主题、EasyTier、ZeroTier、ddns-go、iStore、wechatpush"
  echo "### 🧊 版本信息"
  echo "- 内核版本：**${VERSION_KERNEL}**"
  echo "- 源码 commit：\`${SOURCE_HASH}\`"
  echo "- 编译时间：${NOW}"
  echo ""
  echo "### 🧩 内置插件（编译时拉取的上游最新版本）"
  echo ""
  echo "<!--PLUGINS:BEGIN-->"
  printf '%s\n' "$ADDED_TABLE"
  echo "<!--PLUGINS:END-->"
  echo ""
  echo "**📦 默认内置（随镜像自带）**"
  echo ""
  echo "| 插件 | 版本 | 上游最近更新 | 仓库 |"
  echo "|---|---|---|---|"
  printf '%b' "$def_table"
  echo ""
  echo "### 📁 产物文件"
  echo '```'
  printf '%s\n' "$FIRMWARE_LIST"
  echo '```'
} > "$BODY"
log "发布说明已生成: $BODY"

############################ 2) 发布 / 更新 Release ############################

publish() {
  local tag="$1" title="$2" is_latest="$3" extra_flag=""
  [ "$is_latest" = "1" ] || extra_flag="--latest=false"
  if gh release view "$tag" --repo "$REPO" >/dev/null 2>&1; then
    gh release edit "$tag" --repo "$REPO" --title "$title" --notes-file "$BODY"
    gh release upload "$tag" "$ART_DIR"/* --repo "$REPO" --clobber
    log "已更新 Release: $tag"
  else
    # shellcheck disable=SC2086
    gh release create "$tag" "$ART_DIR"/* --repo "$REPO" --title "$title" --notes-file "$BODY" $extra_flag
    log "已创建 Release: $tag"
  fi
  if [ "$is_latest" = "1" ]; then
    gh release edit "$tag" --repo "$REPO" --latest >/dev/null 2>&1 || true
  fi
}

# 若同一分钟重复触发（手动重跑），追加秒数避免 tag 冲突
if gh release view "$STAMP_TAG" --repo "$REPO" >/dev/null 2>&1; then
  STAMP_TAG="${PREFIX}-$(date '+%Y%m%d-%H%M%S')"
  log "时间戳 tag 已存在，改用 $STAMP_TAG"
fi

publish "$STAMP_TAG" "${PREFIX} ${STAMP}（时间戳快照）" 0
publish "$LATEST_TAG" "${PREFIX} latest（滚动最新）" 1

############################ 3) 清理旧 Release ############################

[ "$KEEP_DAYS" -ge 1 ] 2>/dev/null || KEEP_DAYS=30
cutoff_epoch="$(( $(date +%s) - KEEP_DAYS * 86400 ))"
log "保留策略：latest + 最近 ${KEEP_DAYS} 天的时间戳 Release（截止 $(date -d "@${cutoff_epoch}" '+%Y-%m-%d')）"

tags="$(gh release list --repo "$REPO" --limit 300 --json tagName --jq '.[].tagName' 2>/dev/null || true)"
printf '%s\n' "$tags" | while read -r t; do
  [ -n "$t" ] || continue
  # 只处理本前缀的「时间戳」tag：<PREFIX>-YYYYMMDD-HHMM[SS]
  case "$t" in
    "${PREFIX}"-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9]*) ;;
    *) continue ;;   # latest / 非本前缀 / 其它 tag 一律不动
  esac
  stamp="${t#${PREFIX}-}"
  d="${stamp%%-*}"
  hhmm="${stamp#*-}"; hhmm="${hhmm:0:4}"
  rel_epoch="$(date -d "${d:0:4}-${d:4:2}-${d:6:2} ${hhmm:0:2}:${hhmm:2:2}" +%s 2>/dev/null || echo "")"
  [ -n "$rel_epoch" ] || continue
  if [ "$rel_epoch" -lt "$cutoff_epoch" ]; then
    log "删除过期 Release: $t"
    gh release delete "$t" --repo "$REPO" --yes --cleanup-tag || true
  fi
done

log "完成"
