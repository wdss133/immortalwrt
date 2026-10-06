#!/usr/bin/env bash
#
# customize.sh —— 小米 CR6608（MT7621）定制脚本（幂等 / 耐上游变化 / 万用）
#
# 运行位置：OpenWrt 源码树根目录（本仓库克隆，如 /mnt/openwrt）
# 调用方式：./scripts/custom/customize.sh [custom目录]
#
# ────────────────────────────────────────────────────────────────────────────
# 设计原则（「上游怎么变都能一直用」）：
#   1. 绝不修改本 CI 仓库里的主线文件，所有改动只发生在源码树（每次新克隆，天然干净）；
#   2. 所有写操作幂等，可重复执行；所有删除操作先判断存在性，缺失不报错；
#   3. 外部仓库一律「探测分支 + 失败重试」，上游把默认分支从 master 改成 main 也不中断；
#   4. 软件包清单集中在 custom/packages.seed，增删包不用改脚本；
#   5. 机型白/黑名单集中在 custom/devices.include / devices.exclude；
#   6. 关键项（argon 主题、kmod-tun）缺失才报错；其余第三方插件缺失只告警并自动降级；
#   7. 按目标架构做兼容性过滤：不支持的插件自动跳过，而不是编译到一半炸掉；
#   8. MTK 闭源无线驱动若缺少 Build/Prepare 会自动补上；冲突包自动移除；
#      最终若仍未进入配置，由 workflow 自动回退开源 mt76/wpad。
# ────────────────────────────────────────────────────────────────────────────
#
set -Eeuo pipefail

CUSTOM_DIR="${1:-${CUSTOM_DIR:-$PWD/custom}}"
WORKSPACE="$PWD"
# 主线配置：仓库根的 .config（改它不会提交回仓库，每次都是新克隆）
MAIN_CONFIG="${MAIN_CONFIG:-$PWD/.config}"
OUT_DIR="${OUT_DIR:-$PWD/ci-out}"
PLUGIN_INFO_FILE="${PLUGIN_INFO_FILE:-$PWD/${ARTIFACT_PREFIX:-CR6608}.plugins.md}"
THIRD_PARTY_SOURCES_FILE="${THIRD_PARTY_SOURCES_FILE:-$PWD/third-party-sources.txt}"
SOURCE_TMP="${SOURCE_TMP:-$PWD/.custom-src}"

DEFAULT_THEME="${DEFAULT_THEME:-argon}"
EASYTIER_VARIANT="${EASYTIER_VARIANT:-noweb}"   # noweb = 官方预编译（快）；full = 源码编译（慢）
ZEROTIER_SOURCE="${ZEROTIER_SOURCE:-mwarning}"  # mwarning = 新版包；feeds = 用 feeds 自带
MTK_WIFI="${MTK_WIFI:-auto}"                    # auto | on | off
DEFAULT_IP="${DEFAULT_IP:-192.168.1.1}"
DEFAULT_HOSTNAME="${DEFAULT_HOSTNAME:-CR6608}"
DEFAULT_PASSWORD_HASH="${DEFAULT_PASSWORD_HASH:-\$1\$V4UetPzk\$CYXluq4wUazHjmCDBCqXF.}"

log()  { printf '[custom] %s\n' "$*"; }
warn() { printf '::warning::%s\n' "$*"; }
die()  { printf '::error::%s\n' "$*" >&2; exit 1; }

mkdir -p "$OUT_DIR" "$SOURCE_TMP"
[ -s "$THIRD_PARTY_SOURCES_FILE" ] || printf 'Repository\tBranch\tCommit\tLocalDate\n' > "$THIRD_PARTY_SOURCES_FILE"
[ -f "$MAIN_CONFIG" ] || die "未找到主线配置 $MAIN_CONFIG"

############################ 通用工具 ############################

detect_branch() {
  local repo_url="$1"
  shift
  local candidate
  for candidate in "$@"; do
    if git ls-remote --exit-code --heads "$repo_url" "$candidate" >/dev/null 2>&1; then
      printf '%s\n' "$candidate"; return 0
    fi
  done
  # 候选全失败时退回远端 HEAD 指向的分支
  candidate="$(git ls-remote --symref "$repo_url" HEAD 2>/dev/null \
    | awk '/^ref:/{sub("refs/heads/","",$2); print $2; exit}')"
  [ -n "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
  return 1
}

git_date() { git -C "$1" log -1 --format=%cs 2>/dev/null || true; }

record_revision() {
  local repo_url="$1" branch="$2" dir="$3" commit
  commit="$(git -C "$dir" rev-parse HEAD 2>/dev/null || true)"
  grep -Fq -- "$repo_url	$branch	$commit" "$THIRD_PARTY_SOURCES_FILE" 2>/dev/null && return 0
  printf '%s\t%s\t%s\t%s\n' "$repo_url" "$branch" "${commit:-unknown}" "$(git_date "$dir")" >> "$THIRD_PARTY_SOURCES_FILE"
}

# fetch_repo <url> <临时目录> <候选分支...>
fetch_repo() {
  local url="$1" dest="$2"
  shift 2
  local branch attempt
  branch="$(detect_branch "$url" "$@")" || { warn "分支探测失败（候选: $*）: $url"; return 1; }
  rm -rf "$dest"
  for ((attempt = 1; attempt <= 3; attempt++)); do
    if git clone --depth=1 --no-tags --single-branch --branch "$branch" "$url" "$dest" >/dev/null 2>&1; then
      record_revision "$url" "$branch" "$dest"
      log "已获取 $url [$branch] @ $(git -C "$dest" rev-parse --short HEAD)"
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

safe_rm() {
  local target
  for target in "$@"; do
    rm -rf "$target" 2>/dev/null || true
  done
}

# 目标架构：优先 CONFIG_TARGET_ARCH_PACKAGES="mipsel_24kc"；
# 若 .config 尚未展开该符号，则从 target/linux/<board>/Makefile 的 ARCH
# 与 <subtarget>/target.mk 的 CPU_TYPE 推导（ramips/mt7621 => mipsel_24kc => mipsel）。
target_arch() {
  local v board sub a c f
  v="$(grep -m1 -E '^CONFIG_TARGET_ARCH_PACKAGES=' "$MAIN_CONFIG" 2>/dev/null \
       | sed -E 's/^[^=]*=//; s/"//g; s/^[[:space:]]+//')"
  board="$(grep -m1 -oE '^CONFIG_TARGET_[A-Za-z0-9]+=y' "$MAIN_CONFIG" \
       | sed -E 's/^CONFIG_TARGET_//; s/=y$//')"
  sub="$(grep -m1 -oE "^CONFIG_TARGET_${board}_[A-Za-z0-9]+=y" "$MAIN_CONFIG" 2>/dev/null \
       | sed -E "s/^CONFIG_TARGET_${board}_//; s/=y\$//")"
  if [ -z "$v" ] && [ -n "$board" ]; then
    for f in "target/linux/$board/$sub/target.mk" "target/linux/$board/Makefile"; do
      [ -f "$f" ] || continue
      v="$(grep -m1 -E '^ARCH_PACKAGES[:?]?=' "$f" 2>/dev/null | sed -E 's/^[^=]*=//; s/[[:space:]]//g')"
      [ -n "$v" ] && break
    done
  fi
  if [ -z "$v" ] && [ -n "$board" ]; then
    a="$(grep -m1 -E '^ARCH:?=' "target/linux/$board/Makefile" 2>/dev/null | sed -E 's/^[^=]*=//; s/[[:space:]]//g')"
    c="$(grep -m1 -E '^CPU_TYPE:?=' "target/linux/$board/$sub/target.mk" 2>/dev/null | sed -E 's/^[^=]*=//; s/[[:space:]]//g')"
    [ -n "$a" ] && v="${a}${c:+_$c}"
  fi
  printf '%s\n' "${v%%_*}"
}
ARCH_NAME="$(target_arch)"
[ -n "$ARCH_NAME" ] || ARCH_NAME=unknown
log "目标架构: ${ARCH_NAME}（由 CONFIG_TARGET_ARCH_PACKAGES / ARCH_PACKAGES 推导）"

############################ 1. 基础默认设置 ############################
# 这些是「编译进固件、首次开机即生效」的默认值，全部幂等。

log "应用基础默认设置（IP / 主机名 / 时区 / 密码 / 主机名替换）"

# --- 修复 libustream-ssl 后端冲突（不改会让 package/install 阶段必炸）---
# libustream-ssl 的 openssl/mbedtls/wolfssl 三个变体都会安装 /lib/libustream-ssl.so，
# 而 immortalwrt 的 include/target.mk 把 libustream-openssl 写进了 DEFAULT_PACKAGES，
# 与 luci-ssl / wpad 拉入的 libustream-mbedtls 冲突，安装时 check_data_file_clashes。
# 处理：从 DEFAULT_PACKAGES 里删掉 libustream-openssl，只保留 mbedtls（体积也最小）。
if [ -f include/target.mk ]; then
  if grep -q 'libustream-openssl' include/target.mk; then
    sed -i '/libustream-openssl/d' include/target.mk
    log "  已从 include/target.mk 的 DEFAULT_PACKAGES 移除 libustream-openssl"
  else
    log "  include/target.mk 已无 libustream-openssl 默认项"
  fi
fi
config_set "$MAIN_CONFIG" CONFIG_PACKAGE_libustream-mbedtls y
config_set "$MAIN_CONFIG" CONFIG_PACKAGE_libustream-openssl n
config_set "$MAIN_CONFIG" CONFIG_PACKAGE_libustream-wolfssl n

# --- 默认 IP / 主机名 / 时区 ---
CG="package/base-files/files/bin/config_generate"
if [ -f "$CG" ]; then
  sed -i "s#192\.168\.1\.1#${DEFAULT_IP}#g" "$CG"
  sed -i "s#OpenWrt#${DEFAULT_HOSTNAME}#g" "$CG"
  grep -q "zonename='Asia/Shanghai'" "$CG" || \
    sed -i "s#'UTC'#'CST-8'#g" "$CG"
  log "  默认 IP=${DEFAULT_IP}  主机名=${DEFAULT_HOSTNAME}  时区=CST-8"
else
  warn "未找到 $CG，跳过默认 IP / 主机名 / 时区设置"
fi

# --- 默认密码（保持与上游未设密码不同的行为：不强制，仅在有 shadow 时写入）---
if [ -n "$DEFAULT_PASSWORD_HASH" ] && [ -f package/base-files/files/etc/shadow ]; then
  sed -i "s#^root::0:0:99999:7:::#root:${DEFAULT_PASSWORD_HASH}:0:0:99999:7:::#g" \
    package/base-files/files/etc/shadow || true
  log "  默认 root 密码已写入"
fi

############################ 2. 定制清单写入配置 ############################

log "应用定制清单: ${CUSTOM_DIR}/packages.seed"
if [ -f "${CUSTOM_DIR}/packages.seed" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%$'\r'}"
    case "$line" in
      '') continue ;;
    esac
    if [[ "$line" =~ ^[[:space:]]*# ]]; then
      # 只有 "# CONFIG_xxx is not set" 是有效指令，其余说明文字静默跳过
      if [[ "$line" =~ ^#[[:space:]]+(CONFIG_[A-Za-z0-9_.-]+)[[:space:]]+is[[:space:]]+not[[:space:]]+set ]]; then
        config_set "$MAIN_CONFIG" "${BASH_REMATCH[1]}" n
      fi
      continue
    fi
    if [[ "$line" =~ ^(CONFIG_[A-Za-z0-9_.-]+)=(y|n|m)$ ]]; then
      config_set "$MAIN_CONFIG" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    elif [[ "$line" =~ ^(CONFIG_[A-Za-z0-9_.-]+)=(.*)$ ]]; then
      config_set "$MAIN_CONFIG" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    else
      warn "无法解析的定制行，已忽略: $line"
    fi
  done < "${CUSTOM_DIR}/packages.seed"
else
  warn "未找到 ${CUSTOM_DIR}/packages.seed，跳过清单应用"
fi

# 硬需求：不管 seed 怎么写都强制生效
config_set "$MAIN_CONFIG" CONFIG_PACKAGE_luci-theme-argon y
config_set "$MAIN_CONFIG" CONFIG_PACKAGE_luci-app-argon-config y
config_set "$MAIN_CONFIG" CONFIG_PACKAGE_kmod-tun y
config_set "$MAIN_CONFIG" CONFIG_PACKAGE_luci-theme-aurora n
config_set "$MAIN_CONFIG" CONFIG_PACKAGE_luci-app-aurora-config n

############################ 3. 移除 Aurora 主题 ############################
# Aurora 是第三方主题（eamonxg/luci-theme-aurora），可能来自 feeds / package / 历史缓存。
# 做「存在即清除」的幂等处理：不存在时是 no-op。

log "确保 Aurora 主题及其配置插件不存在"
for pkg in luci-theme-aurora luci-app-aurora-config; do
  safe_rm "feeds/luci/themes/$pkg" "feeds/luci/applications/$pkg" \
          "package/feeds/luci/$pkg" "package/$pkg"
done
while IFS= read -r leftover; do
  case "$leftover" in */.git/*|*/.git) continue ;; esac
  log "  清理残留: $leftover"
  safe_rm "$leftover"
done < <(find package feeds -maxdepth 5 -type d -iname '*aurora*' -print 2>/dev/null || true)
sed -i -E '/^CONFIG_PACKAGE_[A-Za-z0-9_.-]*aurora[A-Za-z0-9_.-]*=y$/d' "$MAIN_CONFIG" 2>/dev/null || true

############################ 4. MTK 闭源无线驱动 ############################
# 本仓库（Heleguo fork）自带 package/mtk：MTK SDK 的闭源 mt_wifi 驱动（mt7915）、
# 配套无线管理界面 luci-app-mtk，以及 datconf 工具链。
# CR6608（MT7621 + MT7905/MT7975）走的就是这套闭源驱动；开源路线是 mt76（kmod-mt7915e）。

MTK_DIR="package/mtk"
MTK_ENABLE=0
case "$MTK_WIFI" in
  1|y|yes|true|on) MTK_ENABLE=1 ;;
  0|n|no|false|off) MTK_ENABLE=0 ;;
  *)
    # auto：本仓库的 ramips/mediatek 目标都适用闭源驱动
    if [ -d "$MTK_DIR/mt7915" ] && grep -qE '^CONFIG_TARGET_(ramips|mediatek)($|=)' "$MAIN_CONFIG"; then
      MTK_ENABLE=1
    fi
    ;;
esac

mtk_prepare_makefile() {
  # 上游 package/mtk/mt7915/Makefile 缺少 Build/Prepare（USE_SOURCE_DIR 被注释掉，
  # 而 include/package.mk 只在设置 USE_SOURCE_DIR/USE_GIT_* 时才定义 Build/Prepare/Default），
  # 因此 PKG_BUILD_DIR 不会被创建，编译必然失败。这里幂等地补一个 Build/Prepare。
  local mk="$MTK_DIR/mt7915/Makefile"
  [ -f "$mk" ] || { warn "未找到 $mk"; return 1; }
  if ! grep -qE '^define Build/Prepare' "$mk"; then
    printf '\n# 由 scripts/custom/customize.sh 注入：从 src/ 填充 PKG_BUILD_DIR\ndefine Build/Prepare\n\trm -rf $(PKG_BUILD_DIR)\n\tmkdir -p $(PKG_BUILD_DIR)\n\t$(CP) ./src/* $(PKG_BUILD_DIR)/\nendef\n' >> "$mk"
    log "  已为 $mk 注入 Build/Prepare"
  else
    log "  $mk 已有 Build/Prepare，跳过注入"
  fi

  # DEPENDS 里的 +@KERNEL_WIRELESS_EXT：本树未定义该符号，会让包在 defconfig 阶段被隐藏。
  # 驱动本身使用 WEXT，只要内核开了 WEXT 即可，这里去掉这个无谓的门槛。
  if ! grep -rqs 'KERNEL_WIRELESS_EXT' target/linux/*/config-* include/ 2>/dev/null; then
    if grep -q 'KERNEL_WIRELESS_EXT' "$mk"; then
      sed -i 's/[[:space:]]*+@KERNEL_WIRELESS_EXT//g' "$mk"
      log "  已移除 DEPENDS 中未定义的 +@KERNEL_WIRELESS_EXT"
    fi
  fi
  return 0
}

if [ "$MTK_ENABLE" -eq 1 ]; then
  log "启用 MTK 闭源无线驱动与配套管理界面（MTK_WIFI=$MTK_WIFI）"

  if [ ! -d "$MTK_DIR" ]; then
    warn "本仓库没有 $MTK_DIR（可能换成了 immortalwrt 官方源），将使用开源 mt76/wpad"
    MTK_ENABLE=0
  else
    mtk_prepare_makefile || MTK_ENABLE=0
  fi
fi

if [ "$MTK_ENABLE" -eq 1 ]; then
  # 4.1 驱动与配套工具
  config_set "$MAIN_CONFIG" CONFIG_PACKAGE_kmod-mt7915 y
  config_set "$MAIN_CONFIG" CONFIG_PACKAGE_wifi-profile y
  config_set "$MAIN_CONFIG" CONFIG_PACKAGE_luci-app-mtk y
  config_set "$MAIN_CONFIG" CONFIG_PACKAGE_datconf-lua y
  config_set "$MAIN_CONFIG" CONFIG_PACKAGE_datconf y
  config_set "$MAIN_CONFIG" CONFIG_PACKAGE_kvcedit y
  config_set "$MAIN_CONFIG" CONFIG_PACKAGE_libkvcutil y
  # luc-app-mtk 是 lua 控制器，需要 lua 运行时与兼容层
  for dep in luci-compat luci-lua-runtime liblua; do
    config_set "$MAIN_CONFIG" "CONFIG_PACKAGE_$dep" y
  done

  # 4.2 MTK_MT7915_* 编译选项
  #   第一路 = MT7915（CR6608 的 MT7905+MT7975 组合），第二/三路 = None
  config_set "$MAIN_CONFIG" CONFIG_MTK_MT7915_SUPPORT_OPENWRT y
  config_set "$MAIN_CONFIG" CONFIG_MTK_MT7915_WIFI_DRIVER y
  config_set "$MAIN_CONFIG" CONFIG_MTK_MT7915_FIRST_IF_MT7915 y
  config_set "$MAIN_CONFIG" CONFIG_MTK_MT7915_CHIP_MT7915 y
  config_set "$MAIN_CONFIG" CONFIG_MTK_MT7915_SECOND_IF_NONE y
  config_set "$MAIN_CONFIG" CONFIG_MTK_MT7915_THIRD_IF_NONE y
  config_set "$MAIN_CONFIG" CONFIG_MTK_MT7915_MT_WIFI y
  config_set "$MAIN_CONFIG" CONFIG_MTK_MT7915_WIFI_BASIC_FUNC y
  config_set "$MAIN_CONFIG" CONFIG_MTK_MT7915_MT_AP_SUPPORT y
  config_set "$MAIN_CONFIG" CONFIG_MTK_MT7915_MT_MAC y
  config_set "$MAIN_CONFIG" CONFIG_MTK_MT7915_WIFI_MT_MAC y
  # 硬件加速：用内核自带的 MTK PPE（CONFIG_NET_MEDIATEK_SOC），不启用驱动的 HNAT/WHNAT 集成，
  # 否则会引入本树不存在的 kmod-mediatek_hnat / kmod-warp 依赖，导致包被 defconfig 丢弃。
  config_set "$MAIN_CONFIG" CONFIG_MTK_MT7915_FAST_NAT_SUPPORT n
  config_set "$MAIN_CONFIG" CONFIG_MTK_MT7915_WHNAT_SUPPORT n
  config_set "$MAIN_CONFIG" CONFIG_MTK_MT7915_WARP_V2 n
  config_set "$MAIN_CONFIG" CONFIG_MTK_MT7915_6G_SUPPORT n
  config_set "$MAIN_CONFIG" CONFIG_MTK_MT7915_MT7976_SUPPORT n

  # 4.3 wifi-profile 的 l1profile 选择（决定装哪套 .dat 标定文件）
  config_set "$MAIN_CONFIG" CONFIG_first_card y
  config_set "$MAIN_CONFIG" CONFIG_first_card_name '"MT7915"'
  config_set "$MAIN_CONFIG" CONFIG_second_card n

  # 4.4 移除与闭源驱动冲突的开源无线栈
  #   - wpad-* / kmod-mac80211 提供 hostapd 与 mt76，会和闭源驱动抢同一块 PCIe 无线
  #   - wifi-scripts 提供 /sbin/wifi，与 wifi-profile 装到 /sbin/wifi 的 wifi_jedi 撞文件
  #     （check_data_file_clashes 会让 package/install 阶段报错）
  for sym in wpad-basic-mbedtls wpad-basic-openssl wpad-mbedtls wpad-openssl wpad-wolfssl \
             wpad-mini kmod-mac80211 kmod-mt7915e kmod-mt7916-firmware kmod-mt7615e \
             kmod-mt7615-firmware kmod-mt7603 wifi-scripts; do
    config_set "$MAIN_CONFIG" "CONFIG_PACKAGE_$sym" n
  done
  safe_rm package/network/config/wifi-scripts

  # 目标 DEFAULT_PACKAGES 里通常强制包含 wpad / kmod-mac80211 / wifi-scripts，
  # 只写 "is not set" 会被 make defconfig 重新拉回 =y，所以直接把它们从
  # DEFAULT_PACKAGES 声明里删掉（只动源码树，不改本仓库文件）。
  for f in "target/linux/${TARGET_BOARD:-ramips}/Makefile" \
           "target/linux/${TARGET_BOARD:-ramips}/${TARGET_SUBTARGET:-mt7621}/target.mk" \
           include/target.mk; do
    [ -f "$f" ] || continue
    if grep -qE '\b(wpad|kmod-mac80211|wifi-scripts)' "$f"; then
      sed -i -E 's/\bwpad-[A-Za-z0-9_.-]+//g; s/\bkmod-mac80211//g; s/\bwifi-scripts//g' "$f"
      log "  已从 $f 的 DEFAULT_PACKAGES 移除开源无线项"
    fi
  done
  log "  已移除开源无线栈（wpad / mac80211 / wifi-scripts）"
else
  log "使用开源 mt76/wpad 无线栈（MTK_WIFI=$MTK_WIFI）"
fi

############################ 5. 拉取第三方软件包 ############################

log "拉取第三方软件包（架构: ${ARCH_NAME}）"

# --- EasyTier（含 luci-app-easytier）---
ez_dir="$SOURCE_TMP/easytier"
ez_ok=0
if fetch_repo https://github.com/EasyTier/luci-app-easytier.git "$ez_dir" main master; then
  ez_variant_dir="$ez_dir/easytier-${EASYTIER_VARIANT}"
  ez_pkg_mk="$ez_variant_dir/Makefile"
  # 兼容性过滤：包声明的架构白名单里必须有本架构，且 Makefile 里有对应的 ARCH 映射
  if [ -f "$ez_pkg_mk" ] && grep -qE "\\b${ARCH_NAME}\\b" "$ez_pkg_mk"; then
    safe_rm package/easytier
    mkdir -p package/easytier
    cp -a "$ez_dir/." package/easytier/
    safe_rm package/easytier/.git package/easytier/.github
    if [ "$EASYTIER_VARIANT" = "noweb" ]; then
      safe_rm package/easytier/easytier
      config_set "$MAIN_CONFIG" CONFIG_PACKAGE_easytier-noweb y
      config_set "$MAIN_CONFIG" CONFIG_PACKAGE_easytier n
    else
      safe_rm package/easytier/easytier-noweb
      config_set "$MAIN_CONFIG" CONFIG_PACKAGE_easytier y
      config_set "$MAIN_CONFIG" CONFIG_PACKAGE_easytier-noweb n
    fi
    config_set "$MAIN_CONFIG" CONFIG_PACKAGE_luci-app-easytier y
    ez_ok=1
    log "  已加入 EasyTier（${EASYTIER_VARIANT}，支持 ${ARCH_NAME}）"
  else
    warn "EasyTier 不支持当前架构 ${ARCH_NAME}（或包结构变化），本次跳过"
  fi
fi
if [ "$ez_ok" -ne 1 ]; then
  warn "本次编译不含 EasyTier（ZeroTier 仍可用）"
  for s in easytier easytier-noweb luci-app-easytier; do
    config_set "$MAIN_CONFIG" "CONFIG_PACKAGE_$s" n
  done
fi

# --- ZeroTier（默认用 mwarning 新版包替换 feeds 旧版；失败/被丢弃自动回退）---
zt_dir="$SOURCE_TMP/zerotier"
zt_backup="feeds/packages/net/zerotier.cifeedbackup"
if [ "$ZEROTIER_SOURCE" = "mwarning" ]; then
  if fetch_repo https://github.com/mwarning/zerotier-openwrt.git "$zt_dir" master main \
     && [ -f "$zt_dir/zerotier/Makefile" ]; then
    [ -d feeds/packages/net/zerotier ] && [ ! -d "$zt_backup" ] && cp -a feeds/packages/net/zerotier "$zt_backup" 2>/dev/null || true
    safe_rm feeds/packages/net/zerotier package/feeds/packages/zerotier package/zerotier
    mv "$zt_dir/zerotier" package/zerotier
    printf 'ZEROTIER_BACKUP=%s\n' "$zt_backup" > "$OUT_DIR/zerotier-fallback.env"
    log "  已用 mwarning/zerotier-openwrt 替换 feeds 版 zerotier"
  else
    warn "ZeroTier 新版包获取失败或结构变化，回退 feeds 自带版本"
  fi
fi
config_set "$MAIN_CONFIG" CONFIG_PACKAGE_zerotier y
config_set "$MAIN_CONFIG" CONFIG_PACKAGE_luci-app-zerotier y

# --- ddns-go ---
ddns_dir="$SOURCE_TMP/ddns-go"
if fetch_repo https://github.com/sirpdboy/luci-app-ddns-go.git "$ddns_dir" main master; then
  safe_rm feeds/packages/net/ddns-go package/feeds/packages/ddns-go package/ddns-go
  safe_rm feeds/luci/applications/luci-app-ddns-go package/feeds/luci/luci-app-ddns-go package/luci-app-ddns-go
  added=0
  [ -d "$ddns_dir/ddns-go" ] && { mv "$ddns_dir/ddns-go" package/ddns-go; added=1; }
  [ -d "$ddns_dir/luci-app-ddns-go" ] && { mv "$ddns_dir/luci-app-ddns-go" package/luci-app-ddns-go; added=1; }
  if [ "$added" -eq 1 ]; then
    config_set "$MAIN_CONFIG" CONFIG_PACKAGE_ddns-go y
    config_set "$MAIN_CONFIG" CONFIG_PACKAGE_luci-app-ddns-go y
    log "  已加入 ddns-go"
  else
    warn "ddns-go 仓库结构变化，未找到子目录，本次跳过"
  fi
else
  warn "ddns-go 获取失败，本次编译将不含 ddns-go"
fi

# --- iStore：4 个子包放到 package/ 顶层 ---
istore_src="$SOURCE_TMP/istore"
if fetch_repo https://github.com/linkease/istore.git "$istore_src" main master; then
  istore_ok=1
  for pkg in luci-app-store luci-lib-taskd luci-lib-xterm taskd; do
    if [ -d "$istore_src/luci/$pkg" ]; then
      safe_rm "package/$pkg"
      cp -a "$istore_src/luci/$pkg" "package/$pkg"
      # 去掉本构建无法满足的依赖：libuci-lua(24.10 已移除) / tar / mount-utils
      # 这些会生成 select PACKAGE_xxx，目标未定义时会让该包在 defconfig 阶段被静默丢弃。
      find "package/$pkg" -name Makefile -exec sed -i -E 's/[[:space:]]*\+(libuci-lua|tar|mount-utils)//g' {} + 2>/dev/null || true
      log "  已放入 package/$pkg"
    else
      warn "istore 缺少子包 luci/$pkg"; istore_ok=0
    fi
  done
  if [ "$istore_ok" -eq 1 ]; then
    for sym in luci-app-store luci-lib-taskd luci-lib-xterm taskd luci-compat luci-lua-runtime; do
      config_set "$MAIN_CONFIG" "CONFIG_PACKAGE_$sym" y
    done
    log "  iStore 已加入"
  fi
else
  warn "iStore 获取失败，本次编译将不含 iStore"
fi

# --- luci-app-wechatpush（微信 / Telegram / 邮件 推送通知）---
wxp_dir="$SOURCE_TMP/wechatpush"
if fetch_repo https://github.com/tty228/luci-app-wechatpush.git "$wxp_dir" master main; then
  safe_rm package/luci-app-wechatpush
  mkdir -p package/luci-app-wechatpush
  cp -a "$wxp_dir/." package/luci-app-wechatpush/
  safe_rm package/luci-app-wechatpush/.git package/luci-app-wechatpush/.github
  config_set "$MAIN_CONFIG" CONFIG_PACKAGE_luci-app-wechatpush y
  for dep in iputils-arping curl jq bash luci-lua-runtime luci-compat; do
    config_set "$MAIN_CONFIG" "CONFIG_PACKAGE_$dep" y
  done
  log "  已加入 luci-app-wechatpush"
else
  warn "wechatpush 获取失败，本次编译将不含该插件"
fi

# --- argon 主题：优先用 feed 自带（与本仓库同分支、集成最好），缺失才从上游补齐 ---
ARGON_SOURCE="feeds/luci（随仓库 feed）"
if [ ! -d "feeds/luci/themes/luci-theme-argon" ] && [ ! -d "package/luci-theme-argon" ]; then
  argon_dir="$SOURCE_TMP/argon"
  if fetch_repo https://github.com/jerrykuku/luci-theme-argon.git "$argon_dir" master main; then
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

############################ 5.5 记录各插件版本与上游更新时间 ############################

pkg_ver() {
  local f v
  for f in "$@"; do
    [ -f "$f" ] || continue
    v="$(grep -m1 -E '^[[:space:]]*PKG_VERSION[[:space:]]*:?=' "$f" 2>/dev/null | sed -E 's/^[^=]*=[[:space:]]*//' | tr -d ' \r')"
    [ -n "$v" ] || continue
    case "$v" in *'$('*) v="$(printf '%s' "$v" | sed -E 's/.*,([^,()]+)\)[^,()]*$/\1/')" ;; esac
    printf '%s' "$v"; return 0
  done
}

{
  printf '| 插件 | 版本 | 上游最近更新 | 仓库 |\n'
  printf '|---|---|---|---|\n'
} > "$PLUGIN_INFO_FILE"
plugin_row() {
  printf '| %s | %s | %s | %s |\n' "$1" "${2:-(见固件清单)}" "${3:-(未知)}" "$4" >> "$PLUGIN_INFO_FILE"
}
feed_date() { [ -d "$1" ] && git -C "$1" log -1 --format=%cs -- "$2" 2>/dev/null || true; }

plugin_row "kmod-tun" \
  "$(pkg_ver "$(find package feeds -path '*kmod-tun/Makefile' -print -quit 2>/dev/null || true)")" \
  "随内核 6.6" "openwrt base"
plugin_row "EasyTier (luci-app-easytier)" \
  "$(pkg_ver "package/easytier/luci-app-easytier/Makefile" "package/easytier/easytier-${EASYTIER_VARIANT}/Makefile")" \
  "$(git_date "$ez_dir")" "https://github.com/EasyTier/luci-app-easytier"
plugin_row "ZeroTier" \
  "$(pkg_ver "package/zerotier/Makefile" "feeds/packages/net/zerotier/Makefile")" \
  "$(git_date "$zt_dir")" "https://github.com/mwarning/zerotier-openwrt"
plugin_row "ddns-go" \
  "$(pkg_ver "package/ddns-go/Makefile")" \
  "$(git_date "$ddns_dir")" "https://github.com/sirpdboy/luci-app-ddns-go"
plugin_row "iStore (luci-app-store)" \
  "$(pkg_ver "package/luci-app-store/Makefile")" \
  "$(git_date "$istore_src")" "https://github.com/linkease/istore"
plugin_row "wechatpush (luci-app-wechatpush)" \
  "$(pkg_ver "package/luci-app-wechatpush/Makefile")" \
  "$(git_date "$wxp_dir")" "https://github.com/tty228/luci-app-wechatpush"
plugin_row "Argon 主题（默认）" \
  "$(pkg_ver "feeds/luci/themes/luci-theme-argon/Makefile" "package/luci-theme-argon/Makefile")" \
  "$(feed_date feeds/luci themes/luci-theme-argon)" "https://github.com/jerrykuku/luci-theme-argon"
if [ "$MTK_ENABLE" -eq 1 ]; then
  plugin_row "MTK 闭源无线（mt_wifi / luci-app-mtk）" \
    "$(pkg_ver "package/mtk/mt7915/Makefile")" \
    "(随本仓库)" "MTK SDK（仓库内 package/mtk）"
fi
log "已生成插件版本信息: $PLUGIN_INFO_FILE（argon 来源: $ARGON_SOURCE，MTK: $MTK_ENABLE）"

safe_rm "$SOURCE_TMP"

############################ 6. 默认主题切换为 argon ############################

log "设置默认主题为 ${DEFAULT_THEME}"
theme_switched=0
while IFS= read -r cfg_file; do
  [ -f "$cfg_file" ] || continue
  grep -q "mediaurlbase" "$cfg_file" || continue
  if grep -qE "mediaurlbase[[:space:]]+'?/luci-static/${DEFAULT_THEME}'?" "$cfg_file"; then
    log "  默认主题已是 ${DEFAULT_THEME}: $cfg_file"
  else
    old="$(sed -nE "s#.*mediaurlbase[[:space:]]+'?([^'[:space:]]+)'?.*#\1#p" "$cfg_file" | head -n1)"
    log "  默认主题写入: $cfg_file（${old:-未知} -> /luci-static/${DEFAULT_THEME}）"
  fi
  sed -i -E "s#(mediaurlbase[[:space:]]+'?)[^'[:space:]]+#\1/luci-static/${DEFAULT_THEME}#g" "$cfg_file"
  theme_switched=1
done < <(grep -rl "mediaurlbase" feeds package 2>/dev/null || true)

# 兜底：固件首次开机时强制写 uci，即便上面没定位到配置文件也能生效
uci_dir="package/base-files/files/etc/uci-defaults"
mkdir -p "$uci_dir"
cat > "${uci_dir}/99_custom_default_theme" <<EOF
#!/bin/sh
# 由 customize.sh 注入：把 LuCI 默认主题固定为 ${DEFAULT_THEME}
[ -x /bin/uci ] || [ -x /sbin/uci ] || exit 0
[ -f /etc/config/luci ] || touch /etc/config/luci
uci -q set luci.main=core
uci -q set luci.main.mediaurlbase='/luci-static/${DEFAULT_THEME}'
uci -q commit luci
exit 0
EOF
chmod +x "${uci_dir}/99_custom_default_theme"

if [ ! -d "feeds/luci/themes/luci-theme-argon" ] && [ ! -d "package/luci-theme-argon" ]; then
  die "未找到 luci-theme-argon 源码，无法设置默认主题"
fi
[ "$theme_switched" -eq 1 ] || warn "未在 feeds 中定位到 mediaurlbase 配置文件，已依赖 uci-defaults 兜底"

############################ 7. 机型筛选 ############################

include_file="${CUSTOM_DIR}/devices.include"
exclude_file="${CUSTOM_DIR}/devices.exclude"
read_list() { [ -f "$1" ] && grep -vE '^[[:space:]]*(#|$)' "$1" 2>/dev/null | tr -d '\r' || true; }

keep_list=()
while IFS= read -r d; do [ -n "$d" ] && keep_list+=("$d"); done < <(read_list "$include_file")

if [ "${#keep_list[@]}" -gt 0 ]; then
  log "白名单模式：${#keep_list[@]} 个机型"
  sed -i -E '/^CONFIG_TARGET_[A-Za-z0-9_]+_DEVICE_.*=y/s/^/# /' "$MAIN_CONFIG"
  for device in "${keep_list[@]}"; do
    if grep -qE "^# CONFIG_TARGET_[A-Za-z0-9_]+_DEVICE_${device}=y" "$MAIN_CONFIG"; then
      sed -i -E "/^# (CONFIG_TARGET_[A-Za-z0-9_]+_DEVICE_${device})=y/s/^# //" "$MAIN_CONFIG"
      log "  白名单放行机型: $device"
    elif grep -qE "^CONFIG_TARGET_[A-Za-z0-9_]+_DEVICE_${device}=y" "$MAIN_CONFIG"; then
      log "  白名单机型已选中: $device"
    else
      warn "devices.include 中的 $device 在当前配置里不存在，已忽略"
    fi
  done
fi

while IFS= read -r d; do
  [ -n "$d" ] || continue
  before="$(grep -cE '^CONFIG_TARGET_[A-Za-z0-9_]+_DEVICE_' "$MAIN_CONFIG" || true)"
  sed -i -E "/^CONFIG_TARGET_[A-Za-z0-9_]+_DEVICE_${d}=y/d" "$MAIN_CONFIG"
  after="$(grep -cE '^CONFIG_TARGET_[A-Za-z0-9_]+_DEVICE_' "$MAIN_CONFIG" || true)"
  [ "$before" != "$after" ] && log "  已按黑名单剔除: $d"
done < <(read_list "$exclude_file")

dev_selected="$(grep -cE '^CONFIG_TARGET_[A-Za-z0-9_]+_DEVICE_.*=y' "$MAIN_CONFIG" || true)"
log "当前选中的机型数量: $dev_selected"
[ "$dev_selected" -gt 0 ] || die "没有任何机型被选中，请检查 ${CUSTOM_DIR}/devices.include"

############################ 8. 刷新索引并自检 ############################

safe_rm tmp/.packageinfo tmp/.targetinfo tmp/.packageauxvars

log "定制完成，当前关键项："
grep -E '^CONFIG_PACKAGE_(kmod-tun|luci-theme-argon|luci-app-argon-config|zerotier|luci-app-zerotier|easytier-noweb|easytier|luci-app-easytier|ddns-go|luci-app-ddns-go|luci-app-store|luci-app-wechatpush|luci-app-wol|luci-app-upnp|kmod-mt7915|wifi-profile|luci-app-mtk|datconf-lua)=' "$MAIN_CONFIG" || true
log "MTK 状态: MTK_ENABLE=$MTK_ENABLE"
