#!/usr/bin/env bash
#
# immortalwrt-customize.sh —— IPQ807X 定制补丁脚本（幂等 / 耐上游变化 / 万能）
#
# 运行位置：OpenWrt 源码树根目录（CI 中是 /mnt/openwrt）
# 调用方式：$GITHUB_WORKSPACE/scripts/custom/immortalwrt-customize.sh [custom目录]
#
# ────────────────────────────────────────────────────────────────────────────
# 设计原则（「上游怎么变都能一直用」）：
#   1. 绝不修改 upstream 仓库里的既有文件；所有改动只发生在源码树与 CI 工作区副本上。
#   2. 所有写操作幂等，可重复执行；所有删除操作先判断存在性，缺失不报错。
#   3. 外部插件仓库一律「探测分支 + 失败重试」，上游把 master 改成 main、或改名也不会中断。
#   4. 增删插件只改 custom/packages.seed 与 custom/devices.*，不用改本脚本。
#   5. 关键项（argon 主题、kmod-tun）缺失才报错；其余缺失只告警，避免上游小改动直接打断流水线。
#   6. 不假设目标平台：机型白名单从源码树动态解析，目标换成别的 board/subtarget 也能跑。
# ────────────────────────────────────────────────────────────────────────────
#
set -Eeuo pipefail

CUSTOM_DIR="${1:-${CUSTOM_DIR:-${GITHUB_WORKSPACE:-$PWD}/custom}}"
WORKSPACE="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
GENERAL_CONFIG="${GENERAL_CONFIG:-$WORKSPACE/custom/General.config}"
DEVICE_CONFIG="${DEVICE_CONFIG:-$WORKSPACE/custom/IPQ807X.config}"
THIRD_PARTY_SOURCES_FILE="${THIRD_PARTY_SOURCES_FILE:-$PWD/third-party-sources.txt}"

# CI 里传进来的可能是相对路径，脚本却运行在源码树里，这里统一解析成真实存在的文件，
# 避免「文件不存在」被误判成「配置为空」。
resolve_existing() {
  local candidate="$1"
  if [ -f "$candidate" ]; then
    printf '%s\n' "$candidate"
  elif [ -f "$WORKSPACE/$candidate" ]; then
    printf '%s\n' "$WORKSPACE/$candidate"
  else
    printf '%s\n' "$candidate"
  fi
}
DEVICE_CONFIG="$(resolve_existing "$DEVICE_CONFIG")"
GENERAL_CONFIG="$(resolve_existing "$GENERAL_CONFIG")"

DEFAULT_THEME="${DEFAULT_THEME:-argon}"
EASYTIER_VARIANT="${EASYTIER_VARIANT:-noweb}"   # noweb = 预编译二进制（快）；full = 源码编译（慢）
ENABLE_MTK_WIFI="${ENABLE_MTK_WIFI:-auto}"      # auto = 仅当目标平台是 MediaTek 时才启用 MTK 闭源无线
ARTIFACT_PREFIX="${ARTIFACT_PREFIX:-IPQ807X-ImmortalWrt}"
TARGET_ID="${TARGET_ID:-qualcommax_ipq807x}"
SOURCE_TMP="${SOURCE_TMP:-$PWD/.custom-src}"

log()  { printf '[custom] %s\n' "$*"; }
warn() { printf '::warning::%s\n' "$*"; }
die()  { printf '::error::%s\n' "$*" >&2; exit 1; }

mkdir -p "$SOURCE_TMP"
[ -s "$THIRD_PARTY_SOURCES_FILE" ] || printf 'Repository\tBranch\tCommit\n' > "$THIRD_PARTY_SOURCES_FILE"

############################ 通用工具 ############################

# 探测外部仓库实际存在的分支（按候选顺序），上游改分支名也不会失败
detect_branch() {
  local repo_url="$1"
  shift
  local candidate
  for candidate in "$@"; do
    if git ls-remote --exit-code --heads "$repo_url" "$candidate" >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  # 候选全部失败时退回远端 HEAD 指向的分支
  candidate="$(git ls-remote --symref "$repo_url" HEAD 2>/dev/null \
    | awk '/^ref:/{sub("refs/heads/","",$2); print $2; exit}')"
  [ -n "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
  return 1
}

record_revision() {
  local repo_url="$1" branch="$2" dir="$3" commit revision
  commit="$(git -C "$dir" rev-parse HEAD)"
  printf -v revision '%s\t%s\t%s' "$repo_url" "$branch" "$commit"
  grep -Fqx -- "$revision" "$THIRD_PARTY_SOURCES_FILE" 2>/dev/null \
    || printf '%s\n' "$revision" >> "$THIRD_PARTY_SOURCES_FILE"
}

# fetch_repo <url> <临时目录> <候选分支...>
fetch_repo() {
  local url="$1" dest="$2"
  shift 2
  local branch attempt
  branch="$(detect_branch "$url" "$@")" || { warn "分支探测失败（$*）: $url"; return 1; }
  rm -rf "$dest"
  for ((attempt = 1; attempt <= 3; attempt++)); do
    if git clone --depth=1 --no-tags --single-branch --branch "$branch" "$url" "$dest" >/dev/null 2>&1; then
      record_revision "$url" "$branch" "$dest"
      log "已获取 $url [$branch]"
      return 0
    fi
    warn "克隆失败，重试 ${attempt}/3: $url"
    sleep $((attempt * 5))
  done
  warn "克隆最终失败: $url"
  return 1
}

# config_set <config文件> <符号> <y|n|m>
config_set() {
  local file="$1" symbol="$2" value="$3"
  [ -f "$file" ] || { warn "配置文件不存在，跳过: $file"; return 0; }
  if grep -Eq "^${symbol}=|^#[[:space:]]+${symbol}[[:space:]]+is[[:space:]]+not[[:space:]]+set" "$file"; then
    sed -i -E "s|^(${symbol})=.*|\1=${value}|; s|^#[[:space:]]+(${symbol})[[:space:]]+is[[:space:]]+not[[:space:]]+set|\1=${value}|" "$file"
  else
    printf '%s=%s\n' "$symbol" "$value" >> "$file"
  fi
}

# 目录存在就删，不存在也不报错
safe_rm() {
  local target
  for target in "$@"; do
    rm -rf "$target" 2>/dev/null || true
  done
}

# 彻底移除某个 feed 里的包：既删 feeds/<feed>/... 实体目录，也删 package/feeds/<feed>/<pkg> 软链
purge_feed_pkg() {
  local name="$1" p
  while IFS= read -r p; do
    [ -n "$p" ] && safe_rm "$p"
  done < <(find package/feeds -mindepth 2 -maxdepth 2 -name "$name" -print 2>/dev/null || true)
  while IFS= read -r p; do
    [ -n "$p" ] && safe_rm "$p"
  done < <(find feeds -maxdepth 5 -type d -name "$name" -print 2>/dev/null || true)
}

# 整个源码树里按目录名递归清理（防止 feeds 结构变化后漏网）
nuke_dirs_named() {
  local name="$1" p
  while IFS= read -r p; do
    [ -n "$p" ] && safe_rm "$p"
  done < <(find package feeds -maxdepth 5 -type d -name "$name" -print 2>/dev/null || true)
}

############################ 1. 定制清单写入配置副本 ############################
# 注意：改的是 CI 工作区里 General.config 的副本，不会提交回仓库，
# 因此上游随时改 General.config / .config 都不会产生 git 冲突。

log "应用定制清单: ${CUSTOM_DIR}/packages.seed"
if [ -f "${CUSTOM_DIR}/packages.seed" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%$'\r'}"
    case "$line" in
      '') continue ;;
    esac
    # 注释行：只有 "# CONFIG_xxx is not set" 是有效指令，其余说明文字静默跳过
    if [[ "$line" =~ ^[[:space:]]*# ]]; then
      if [[ "$line" =~ ^#[[:space:]]+(CONFIG_[A-Za-z0-9_.-]+)[[:space:]]+is[[:space:]]+not[[:space:]]+set ]]; then
        config_set "$GENERAL_CONFIG" "${BASH_REMATCH[1]}" n
      fi
      continue
    fi
    if [[ "$line" =~ ^(CONFIG_[A-Za-z0-9_.-]+)=(y|n|m)$ ]]; then
      config_set "$GENERAL_CONFIG" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    elif [[ "$line" =~ ^(CONFIG_[A-Za-z0-9_.-]+)=(.*)$ ]]; then
      config_set "$GENERAL_CONFIG" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    else
      warn "无法解析的定制行，已忽略: $line"
    fi
  done < "${CUSTOM_DIR}/packages.seed"
else
  warn "未找到 ${CUSTOM_DIR}/packages.seed，沿用脚本内置默认值"
  config_set "$GENERAL_CONFIG" CONFIG_PACKAGE_luci-theme-argon y
  config_set "$GENERAL_CONFIG" CONFIG_PACKAGE_luci-app-argon-config y
  config_set "$GENERAL_CONFIG" CONFIG_PACKAGE_luci-theme-aurora n
  config_set "$GENERAL_CONFIG" CONFIG_PACKAGE_luci-app-aurora-config n
  config_set "$GENERAL_CONFIG" CONFIG_PACKAGE_kmod-tun y
fi

# 这些是硬需求，不管 seed 怎么写都强制生效
config_set "$GENERAL_CONFIG" CONFIG_PACKAGE_kmod-tun y
config_set "$GENERAL_CONFIG" CONFIG_PACKAGE_luci-theme-argon y
config_set "$GENERAL_CONFIG" CONFIG_PACKAGE_luci-app-argon-config y
config_set "$GENERAL_CONFIG" CONFIG_PACKAGE_luci-theme-aurora n
config_set "$GENERAL_CONFIG" CONFIG_PACKAGE_luci-app-aurora-config n

############################ 2. 彻底移除 Aurora 主题 ############################
# Aurora 是第三方主题（eamonxg/luci-theme-aurora），可能来自：
#   - 上游 feeds 被加入过
#   - package/ 下手工放置
#   - 曾经启用过的 feeds 缓存
# 这里做「存在即清除」的幂等处理：不存在时是 no-op，不会报错。

log "移除 Aurora 主题及其配置插件"
for pkg in luci-theme-aurora luci-app-aurora-config; do
  purge_feed_pkg "$pkg"
  nuke_dirs_named "$pkg"
  safe_rm "package/$pkg"
done
# 兜底：任何名字里带 aurora 的包目录一并清理（大小写不敏感）
nuke_dirs_named "luci-theme-aurora"
while IFS= read -r leftover; do
  case "$leftover" in
    */.git/*|*/.git) continue ;;
  esac
  log "  清理残留: $leftover"
  safe_rm "$leftover"
done < <(find package feeds -maxdepth 5 -type d -iname '*aurora*' -print 2>/dev/null || true)
# 配置层面也不允许出现
sed -i -E '/^CONFIG_PACKAGE_[A-Za-z0-9_.-]*aurora[A-Za-z0-9_.-]*=y$/d' "$GENERAL_CONFIG" 2>/dev/null || true
while IFS= read -r sym; do
  config_set "$GENERAL_CONFIG" "$sym" n
done < <(grep -oE '^CONFIG_PACKAGE_[A-Za-z0-9_.-]*aurora[A-Za-z0-9_.-]*' "$DEVICE_CONFIG" 2>/dev/null || true)

############################ 3. 拉取第三方软件包 ############################
# 全部落位到 package/ 顶层真实目录（已在本仓库验证可行的落位方式），
# 不依赖 feeds 的分支名，上游换分支/改名都不影响。

log "拉取第三方软件包"
ez_dir="$SOURCE_TMP/easytier"
zt_dir="$SOURCE_TMP/zerotier"
ddns_dir="$SOURCE_TMP/ddns-go"
istore_dir="$SOURCE_TMP/istore"
wxp_dir="$SOURCE_TMP/wechatpush"
argon_dir="$SOURCE_TMP/argon"

# --- EasyTier（含 luci-app-easytier）---
if fetch_repo https://github.com/EasyTier/luci-app-easytier.git "$ez_dir" main master; then
  safe_rm package/easytier
  mkdir -p package/easytier
  cp -a "$ez_dir/." package/easytier/
  safe_rm package/easytier/.git package/easytier/.github
  # 只保留实际需要的变体，避免同名包被同时选中
  if [ "$EASYTIER_VARIANT" = "noweb" ]; then
    safe_rm package/easytier/easytier
    config_set "$GENERAL_CONFIG" CONFIG_PACKAGE_easytier-noweb y
    config_set "$GENERAL_CONFIG" CONFIG_PACKAGE_easytier n
  else
    safe_rm package/easytier/easytier-noweb
    config_set "$GENERAL_CONFIG" CONFIG_PACKAGE_easytier y
    config_set "$GENERAL_CONFIG" CONFIG_PACKAGE_easytier-noweb n
  fi
  config_set "$GENERAL_CONFIG" CONFIG_PACKAGE_luci-app-easytier y
  log "  EasyTier($EASYTIER_VARIANT) 已加入"
else
  warn "EasyTier 获取失败，本次编译将不含 EasyTier"
fi

# --- ZeroTier（用 mwarning 维护的新版包替换 feeds 旧版）---
if fetch_repo https://github.com/mwarning/zerotier-openwrt.git "$zt_dir" master main; then
  purge_feed_pkg zerotier
  safe_rm package/zerotier
  if [ -d "$zt_dir/zerotier" ]; then
    mv "$zt_dir/zerotier" package/zerotier
    config_set "$GENERAL_CONFIG" CONFIG_PACKAGE_zerotier y
    config_set "$GENERAL_CONFIG" CONFIG_PACKAGE_luci-app-zerotier y
    log "  ZeroTier 已替换为上游新版"
  else
    warn "zerotier 包目录结构变化，未找到 zerotier/ 子目录，回退 feeds 版本"
    config_set "$GENERAL_CONFIG" CONFIG_PACKAGE_zerotier y
    config_set "$GENERAL_CONFIG" CONFIG_PACKAGE_luci-app-zerotier y
  fi
else
  warn "ZeroTier 获取失败，回退到 feeds 自带版本"
  config_set "$GENERAL_CONFIG" CONFIG_PACKAGE_zerotier y
  config_set "$GENERAL_CONFIG" CONFIG_PACKAGE_luci-app-zerotier y
fi

# --- ddns-go ---
if fetch_repo https://github.com/sirpdboy/luci-app-ddns-go.git "$ddns_dir" main master; then
  purge_feed_pkg ddns-go
  purge_feed_pkg luci-app-ddns-go
  safe_rm package/ddns-go package/luci-app-ddns-go
  [ -d "$ddns_dir/ddns-go" ] && mv "$ddns_dir/ddns-go" package/ddns-go
  [ -d "$ddns_dir/luci-app-ddns-go" ] && mv "$ddns_dir/luci-app-ddns-go" package/luci-app-ddns-go
  config_set "$GENERAL_CONFIG" CONFIG_PACKAGE_ddns-go y
  config_set "$GENERAL_CONFIG" CONFIG_PACKAGE_luci-app-ddns-go y
  log "  ddns-go 已加入"
else
  warn "ddns-go 获取失败，本次编译将不含 ddns-go"
fi

# --- iStore：4 个子包直接放到 package/ 顶层 ---
# OpenWrt 的包扫描为：find -L package -name Makefile | grep 'call (Build/DefaultTargets|BuildPackage|KernelPackage)'
# 只要 Makefile 自身含该串（luci 包末尾的 `# call BuildPackage` 注释即可命中）就会被注册。
if fetch_repo https://github.com/linkease/istore.git "$istore_dir" main master; then
  istore_ok=1
  for pkg in luci-app-store luci-lib-taskd luci-lib-xterm taskd; do
    if [ -d "$istore_dir/luci/$pkg" ]; then
      purge_feed_pkg "$pkg"
      safe_rm "package/$pkg"
      cp -a "$istore_dir/luci/$pkg" "package/$pkg"
      # 去掉本构建里无法满足的依赖：libuci-lua(24.10+ 已移除) / tar / mount-utils。
      # 这些会生成 `select PACKAGE_xxx`，目标未定义时会让该包在 defconfig 阶段被静默丢弃。
      find "package/$pkg" -name Makefile -exec sed -i -E 's/[[:space:]]*\+(libuci-lua|tar|mount-utils)//g' {} + 2>/dev/null || true
      log "  已放入 package/$pkg"
    else
      warn "istore 缺少子包 luci/$pkg"; istore_ok=0
    fi
  done
  if [ "$istore_ok" -eq 1 ]; then
    for sym in luci-app-store luci-lib-taskd luci-lib-xterm taskd luci-compat luci-lua-runtime; do
      config_set "$GENERAL_CONFIG" "CONFIG_PACKAGE_$sym" y
    done
    log "  iStore 已按 package/ 顶层落位加入"
  fi
else
  warn "iStore 获取失败，本次编译将不含 iStore"
fi

# --- luci-app-wechatpush（微信 / Telegram / 邮件 推送通知）---
if fetch_repo https://github.com/tty228/luci-app-wechatpush.git "$wxp_dir" master main; then
  purge_feed_pkg luci-app-wechatpush
  safe_rm package/luci-app-wechatpush
  mkdir -p package/luci-app-wechatpush
  cp -a "$wxp_dir/." package/luci-app-wechatpush/
  safe_rm package/luci-app-wechatpush/.git package/luci-app-wechatpush/.github
  config_set "$GENERAL_CONFIG" CONFIG_PACKAGE_luci-app-wechatpush y
  # 依赖（均为 + 软依赖，缺哪个会自动忽略）
  for dep in iputils-arping curl jq bash luci-lua-runtime luci-compat; do
    config_set "$GENERAL_CONFIG" "CONFIG_PACKAGE_$dep" y
  done
  log "  已加入 luci-app-wechatpush（微信/Telegram/邮件推送）"
else
  warn "wechatpush 获取失败，本次编译将不含该插件"
fi

# --- luci-theme-argon：优先用 feed 自带版本（与本仓库同分支、集成最好）---
ARGON_SOURCE="feeds/luci（随仓库 feed）"
if [ ! -d "feeds/luci/themes/luci-theme-argon" ] && [ ! -d "package/luci-theme-argon" ]; then
  # feed 里没有时才回退到上游仓库，保证「永远有 argon 可用」
  if fetch_repo https://github.com/jerrykuku/luci-theme-argon.git "$argon_dir" master main; then
    purge_feed_pkg luci-theme-argon
    safe_rm package/luci-theme-argon
    mkdir -p package/luci-theme-argon
    cp -a "$argon_dir/." package/luci-theme-argon/
    safe_rm package/luci-theme-argon/.git package/luci-theme-argon/.github
    ARGON_SOURCE="https://github.com/jerrykuku/luci-theme-argon"
    log "  argon 主题从上游仓库补齐"
  else
    warn "argon 主题在 feed 中缺失且上游拉取失败"
  fi
fi

############################ 3.5 记录各插件版本与上游更新时间 ############################
# 生成 markdown 表，随固件一起打包，并由 release.sh 写入发布说明、由 gen-readme.sh 写入 README。
PLUGIN_INFO_FILE="${PLUGIN_INFO_FILE:-$PWD/${ARTIFACT_PREFIX}.plugins.md}"
{
  printf '| 插件 | 版本 | 上游最近更新 | 仓库 |\n'
  printf '|---|---|---|---|\n'
} > "$PLUGIN_INFO_FILE"

pkg_ver() {
  local f v
  for f in "$@"; do
    [ -f "$f" ] || continue
    v="$(grep -m1 -E '^[[:space:]]*PKG_VERSION[[:space:]]*:?=' "$f" 2>/dev/null | sed -E 's/^[^=]*=[[:space:]]*//' | tr -d ' \r')"
    [ -n "$v" ] || continue
    # 处理 $(or$(X),1.2.3) 这类 make 表达式：取最后一个逗号后的真实版本号
    case "$v" in *'$('*) v="$(printf '%s' "$v" | sed -E 's/.*,([^,()]+)\)[^,()]*$/\1/')" ;; esac
    printf '%s' "$v"; return 0
  done
}
git_date() { git -C "$1" log -1 --format=%cs 2>/dev/null || true; }
feed_date() {
  local feed="$1" path="$2"
  [ -d "$feed" ] || return 0
  git -C "$feed" log -1 --format=%cs -- "$path" 2>/dev/null || true
}
plugin_row() {
  local v="${2:-}" d="${3:-}"
  printf '| %s | %s | %s | %s |\n' "$1" "${v:-(见固件清单)}" "${d:-(未知)}" "$4" >> "$PLUGIN_INFO_FILE"
}

plugin_row "kmod-tun" \
  "$(pkg_ver "$(find feeds package -path '*kmod-tun/Makefile' -print -quit 2>/dev/null)")" \
  "随内核 6.6" "openwrt base"
plugin_row "luci-theme-argon (默认主题)" \
  "$(pkg_ver "feeds/luci/themes/luci-theme-argon/Makefile" "package/luci-theme-argon/Makefile")" \
  "$(feed_date feeds/luci themes/luci-theme-argon)" "https://github.com/jerrykuku/luci-theme-argon"
plugin_row "EasyTier" \
  "$(pkg_ver "package/easytier/luci-app-easytier/Makefile" "package/easytier/easytier-noweb/Makefile" "package/easytier/easytier/Makefile")" \
  "$(git_date "$ez_dir")" "https://github.com/EasyTier/luci-app-easytier"
plugin_row "ZeroTier" \
  "$(pkg_ver "package/zerotier/Makefile")" \
  "$(git_date "$zt_dir")" "https://github.com/mwarning/zerotier-openwrt"
plugin_row "ddns-go" \
  "$(pkg_ver "package/ddns-go/Makefile")" \
  "$(git_date "$ddns_dir")" "https://github.com/sirpdboy/luci-app-ddns-go"
plugin_row "iStore (luci-app-store)" \
  "$(pkg_ver "package/luci-app-store/Makefile")" \
  "$(git_date "$istore_dir")" "https://github.com/linkease/istore"
plugin_row "wechatpush (luci-app-wechatpush)" \
  "$(pkg_ver "package/luci-app-wechatpush/Makefile")" \
  "$(git_date "$wxp_dir")" "https://github.com/tty228/luci-app-wechatpush"
log "  已生成插件版本信息: $PLUGIN_INFO_FILE（argon 来源: $ARGON_SOURCE）"

safe_rm "$SOURCE_TMP"

############################ 4. 默认主题切换为 argon ############################

log "设置默认主题为 ${DEFAULT_THEME}"
theme_switched=0
while IFS= read -r cfg_file; do
  [ -f "$cfg_file" ] || continue
  grep -q "mediaurlbase" "$cfg_file" || continue
  if grep -qE "mediaurlbase[[:space:]]+'?/luci-static/${DEFAULT_THEME}'?" "$cfg_file"; then
    log "  默认主题已是 ${DEFAULT_THEME}: $cfg_file"
  else
    old_theme="$(sed -nE "s#.*mediaurlbase[[:space:]]+'?([^'[:space:]]+)'?.*#\1#p" "$cfg_file" | head -n1)"
    log "  默认主题写入: $cfg_file（原值 ${old_theme:-未知} -> /luci-static/${DEFAULT_THEME}）"
  fi
  sed -i -E "s#(mediaurlbase[[:space:]]+'?)[^'[:space:]]+#\1/luci-static/${DEFAULT_THEME}#g" "$cfg_file"
  theme_switched=1
done < <(grep -rl "mediaurlbase" feeds package 2>/dev/null || true)

# 兜底：固件首次开机时强制写 uci，即便上面没找到配置文件也能生效
uci_dir="package/base-files/files/etc/uci-defaults"
mkdir -p "$uci_dir"
cat > "${uci_dir}/99_custom_default_theme" <<EOF
#!/bin/sh
# 由 immortalwrt-customize.sh 注入：把 LuCI 默认主题固定为 ${DEFAULT_THEME}
[ -x /bin/uci ] || [ -x /sbin/uci ] || exit 0
[ -f /etc/config/luci ] || touch /etc/config/luci
uci -q set luci.main=core
uci -q set luci.main.mediaurlbase='/luci-static/${DEFAULT_THEME}'
uci -q commit luci
exit 0
EOF
chmod +x "${uci_dir}/99_custom_default_theme"
log "  已注入 uci-defaults 兜底脚本"

# 确认 argon 主题源码确实存在，缺失就直接判定失败
if [ ! -d "feeds/luci/themes/luci-theme-argon" ] && [ ! -d "package/luci-theme-argon" ]; then
  die "未找到 luci-theme-argon 源码，无法设置默认主题"
fi
[ "$theme_switched" -eq 1 ] || warn "未在 feeds 中定位到 mediaurlbase 配置文件，已依赖 uci-defaults 兜底"

############################ 5. MTK 闭源无线（按目标平台自动启用）############################
# MTK 闭源驱动（kmod-mt7915 / wifi-profile / luci-app-mtk / datconf-lua）来自 MTK SDK，
# 只对 MediaTek 平台（mediatek/*）有意义；IPQ807X 属 Qualcomm，用 ath11k。
# 因此默认 auto：只在目标 board 为 mediatek 时才启用，避免在 qualcommax 上误选导致编不过。
USE_MTK=0
case "$ENABLE_MTK_WIFI" in
  1|y|yes|true|on) USE_MTK=1 ;;
  0|n|no|false|off) USE_MTK=0 ;;
  *)
    if grep -qE '^CONFIG_TARGET_mediatek=y' "$DEVICE_CONFIG" "$GENERAL_CONFIG" 2>/dev/null; then
      USE_MTK=1
    fi
    ;;
esac
if [ "$USE_MTK" -eq 1 ]; then
  log "启用 MTK 闭源无线驱动与配套管理界面"
  for sym in kmod-mt7915 wifi-profile luci-app-mtk datconf-lua; do
    config_set "$GENERAL_CONFIG" "CONFIG_PACKAGE_$sym" y
  done
  # MTK 驱动自带 hostapd 能力，关闭 opensource wpad 避免冲突
  for sym in wpad-openssl wpad-basic-openssl wpad-mbedtls wpad-basic-mbedtls wpad-wolfssl; do
    config_set "$GENERAL_CONFIG" "CONFIG_PACKAGE_$sym" n
  done
else
  log "跳过 MTK 闭源无线（当前目标非 MediaTek 平台，使用 ath11k）"
fi

############################ 6. 机型筛选（白名单优先，其次黑名单）############################
# 先按源码树里的机型定义动态解析出该 subtarget 的全部机型（未来上游新增机型会自动跟上），
# 再按 devices.include / devices.exclude 收敛。

TARGET_BOARD="${TARGET_BOARD:-qualcommax}"
TARGET_SUBTARGET="${TARGET_SUBTARGET:-ipq807x}"
image_mk="target/linux/${TARGET_BOARD}/image/${TARGET_SUBTARGET}.mk"
if [ -f "$image_mk" ]; then
  mapfile -t all_devices < <(sed -n 's/^TARGET_DEVICES[[:space:]]*+=[[:space:]]*\(.*\)$/\1/p' "$image_mk" \
    | tr ' ' '\n' | grep -vE '^[[:space:]]*$' | sort -u | tr -d '\r')
  log "源码树中 ${TARGET_BOARD}/${TARGET_SUBTARGET} 共 ${#all_devices[@]} 个机型"
else
  all_devices=()
  warn "未找到 $image_mk，跳过机型动态解析"
fi

include_file="${CUSTOM_DIR}/devices.include"
exclude_file="${CUSTOM_DIR}/devices.exclude"
read_list() {
  local f="$1"
  [ -f "$f" ] || return 0
  grep -vE '^[[:space:]]*(#|$)' "$f" 2>/dev/null | tr -d '\r' || true
}

selected=()
if [ -n "$(read_list "$include_file")" ]; then
  while IFS= read -r d; do
    [ -n "$d" ] && selected+=("$d")
  done < <(read_list "$include_file")
  log "白名单模式：${#selected[@]} 个机型"
elif [ "${#all_devices[@]}" -gt 0 ]; then
  selected=("${all_devices[@]}")
  log "白名单为空：编译全部 ${#selected[@]} 个机型"
fi

excluded=()
while IFS= read -r d; do
  [ -n "$d" ] && excluded+=("$d")
done < <(read_list "$exclude_file")

is_excluded() {
  local d="$1" e
  for e in "${excluded[@]:-}"; do
    [ "$e" = "$d" ] && return 0
  done
  return 1
}

# 机型是否真实存在：优先用源码树解析出的列表，其次用配置里已有的符号
is_known_device() {
  local d="$1" sym
  if [ "${#all_devices[@]}" -gt 0 ]; then
    local known
    for known in "${all_devices[@]}"; do
      [ "$known" = "$d" ] && return 0
    done
    return 1
  fi
  sym="CONFIG_TARGET_DEVICE_${TARGET_BOARD}_${TARGET_SUBTARGET}_DEVICE_${d}"
  grep -qE "^#? ?${sym}=y$" "$DEVICE_CONFIG" 2>/dev/null
}

# 先清零，再按最终名单放行（幂等）。生成的机型行直接写回 DEVICE_CONFIG，
# 这样 CI 里 `cat DEVICE_CONFIG GENERAL_CONFIG > .config` 能自然包含它们。
if grep -qE '^CONFIG_TARGET_DEVICE_' "$DEVICE_CONFIG" 2>/dev/null; then
  sed -i -E '/^CONFIG_TARGET_DEVICE_/s/^/# /' "$DEVICE_CONFIG"
fi
final_count=0
for d in "${selected[@]:-}"; do
  [ -n "$d" ] || continue
  if is_excluded "$d"; then
    log "  已按黑名单剔除: $d"
    continue
  fi
  if ! is_known_device "$d"; then
    warn "机型 $d 在当前 ${TARGET_BOARD}/${TARGET_SUBTARGET} 中不存在（可能上游已改名/移除），已忽略"
    continue
  fi
  sym="CONFIG_TARGET_DEVICE_${TARGET_BOARD}_${TARGET_SUBTARGET}_DEVICE_${d}"
  if grep -qE "^# ${sym}=y$|^${sym}=y$" "$DEVICE_CONFIG" 2>/dev/null; then
    sed -i -E "/^# ${sym}=y$/s/^# //" "$DEVICE_CONFIG"
  else
    printf '%s=y\n' "$sym" >> "$DEVICE_CONFIG"
  fi
  final_count=$((final_count + 1))
done
log "最终编译机型数量: $final_count"
[ "$final_count" -gt 0 ] || die "机型被全部剔除，请检查 ${CUSTOM_DIR}/devices.include|devices.exclude"

############################ 7. 刷新索引并自检 ############################

# 强制 make defconfig 重新扫描 package/ 树，保证新加入的包能被识别
safe_rm tmp/.packageinfo tmp/.targetinfo tmp/.packageauxvars

log "定制完成，关键配置项："
grep -E "^CONFIG_PACKAGE_(kmod-tun|luci-theme-argon|luci-app-argon-config|zerotier|luci-app-zerotier|easytier|easytier-noweb|luci-app-easytier|ddns-go|luci-app-ddns-go|luci-app-store|luci-app-wechatpush)=" "$GENERAL_CONFIG" || true
