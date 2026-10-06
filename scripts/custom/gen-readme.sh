#!/usr/bin/env bash
#
# gen-readme.sh —— 依据仓库「实际配置」重新生成 README.md
#
# 目的：让 README 永远与本仓库的真实配置一致（机型白名单、默认主题、新增插件、
#       发布策略、自动化时间、迁移说明），不需要人工维护。
#       上游怎么变、分支怎么换，只要改了 custom/ 里的配置，README 会自动跟上。
#
# 用法：gen-readme.sh [repo_root] [plugin_table_file]
# 环境变量（可选，用于文案）：
#   RELEASE_PREFIX / KEEP_RECENT / SOURCE_REPO / SOURCE_BRANCH / UPSTREAM_REPO / CUSTOM_BRANCH /
#   CUSTOM_DIR / DEVICE / WORKFLOW_FILE / MTK_STATE
#
set -Eeuo pipefail

ROOT="${1:-${GITHUB_WORKSPACE:-$PWD}}"
PLUGIN_TABLE="${2:-}"
cd "$ROOT"

CUSTOM_DIR="${CUSTOM_DIR:-custom}"
SEED="$CUSTOM_DIR/packages.seed"
INC="$CUSTOM_DIR/devices.include"
EXC="$CUSTOM_DIR/devices.exclude"
PREFIX="${RELEASE_PREFIX:-CR6608}"
KEEP_RECENT="${KEEP_RECENT:-36}"
SOURCE_REPO="${SOURCE_REPO:-https://github.com/wdss133/immortalwrt}"
SOURCE_BRANCH="${SOURCE_BRANCH:-openwrt-24.10}"
UPSTREAM_REPO="${UPSTREAM_REPO:-https://github.com/Heleguo/immortalwrt}"
CUSTOM_BRANCH="${CUSTOM_BRANCH:-custom-cr6608}"
DEVICE="${DEVICE:-xiaomi_mi-router-cr6608}"
WORKFLOW_FILE="${WORKFLOW_FILE:-.github/workflows/ImmortalWrt-CR6608-Daily.yml}"
MTK_STATE="${MTK_STATE:-auto}"
SOURCE_URL="${SOURCE_REPO%.git}"
UPSTREAM_URL="${UPSTREAM_REPO%.git}"
WF_BASENAME="$(basename "$WORKFLOW_FILE")"

strip_list() { grep -vE '^[[:space:]]*(#|$)' "$1" 2>/dev/null | tr -d '\r' || true; }

devices_block() {
  if [ -n "$(strip_list "$INC" 2>/dev/null || true)" ]; then
    strip_list "$INC" | sed 's/^/- /'
  else
    echo "- (未设置白名单，按源码树该 subtarget 的全部机型编译)"
  fi
  if [ -f "$EXC" ] && [ -n "$(strip_list "$EXC")" ]; then
    local ex; ex="$(strip_list "$EXC" | awk 'NR==1{printf "%s",$0; next} {printf "、%s",$0}')"
    [ -n "$ex" ] && echo "- 另排除：$ex"
  fi
}

added_block() {
  if [ -f "$SEED" ]; then
    grep -E '^CONFIG_PACKAGE_[^=]+=y' "$SEED" 2>/dev/null | sed -E 's/^CONFIG_PACKAGE_//; s/=y$//' | sed 's/^/- /' || true
  fi
}

plugin_block() {
  if [ -n "$PLUGIN_TABLE" ] && [ -s "$PLUGIN_TABLE" ]; then
    cat "$PLUGIN_TABLE"
  else
    cat <<'EOF'
| 插件 | 版本 | 上游最近更新 | 仓库 |
|---|---|---|---|
| kmod-tun | 随内核 6.6 | — | openwrt base |
| EasyTier (luci-app-easytier) | 见 Release 说明 | — | https://github.com/EasyTier/luci-app-easytier |
| ZeroTier | 见 Release 说明 | — | https://github.com/mwarning/zerotier-openwrt |
| ddns-go | 见 Release 说明 | — | https://github.com/sirpdboy/luci-app-ddns-go |
| iStore (luci-app-store) | 见 Release 说明 | — | https://github.com/linkease/istore |
| wechatpush (luci-app-wechatpush) | 见 Release 说明 | — | https://github.com/tty228/luci-app-wechatpush |
| Argon 主题（默认） | 随 immortalwrt/luci feed | — | https://github.com/jerrykuku/luci-theme-argon |

> 上表来自最近一次编译的发布说明；完整版本号与上游更新日期见对应 Release。
EOF
  fi
}

OUT="$(mktemp)"
{
  cat <<EOF
# 小米 CR6608 固件自动编译

> 本仓库是 [Heleguo/immortalwrt](${UPSTREAM_URL})（分支 \`${SOURCE_BRANCH}\`）的 **自动编译定制分支**：
> 每日自动同步上游主线，按下面的定制编译 **小米 CR6608（MT7621 / ramips-mt7621）** 固件并发布。
> 该上游 fork 相对 ImmortalWrt 官方的关键增强是 **MTK 闭源无线驱动 + MTK PPE 硬件加速补丁**，
> 因此源码必须取自本仓库 / 该 fork，换成 ImmortalWrt 官方源会丢掉 \`package/mtk\` 与 ramips 硬加速补丁。
> 全部定制均以 **新增文件 + 幂等脚本** 实现，不改动上游既有文件，上游同步不产生冲突。

## ✅ 本仓库相对上游的实际变更

### 1) 编译目标与机型
- 目标：**ramips / mt7621**，机型：\`${DEVICE}\`

$(devices_block)

### 2) 无线与硬件加速
- **MTK 闭源无线驱动**（\`package/mtk/mt7915\`，MTK SDK 的 \`mt_wifi\`）+ 配套管理界面 \`luci-app-mtk\`
  - 脚本会自动为缺失的 \`Build/Prepare\` 打补丁，并移除与之冲突的开源无线栈
    （\`wpad-*\` / \`kmod-mac80211\` / \`wifi-scripts\`）
  - 若最终未进入配置，会自动回退到开源 **mt76/wpad**，保证一定产出可用固件
  - 由 \`MTK_WIFI\` 控制：\`auto\`（默认，先试闭源）/ \`on\` / \`off\`
- **硬件加速**：使用内核自带 **MTK PPE**（\`CONFIG_NET_MEDIATEK_SOC\`，MT7621 的 \`mtk_eth_soc\`）
  + \`kmod-nft-offload\` 流卸载

### 3) 默认主题
- 默认主题改为 **argon**，并在 \`/etc/uci-defaults\` 注入兜底脚本，首次开机即生效。
- **移除 Aurora 主题及其配置插件**（\`luci-theme-aurora\` / \`luci-app-aurora-config\`），
  存在则删除（源码树 + feeds + 软链 + 配置项全部清理），不存在时静默跳过。

### 4) 内核特性
- 启用 **\`kmod-tun\`**，用于适配 ZeroTier / EasyTier。

### 5) 新增内置插件
（来源于 \`${CUSTOM_DIR}/packages.seed\`）

$(added_block)

第三方插件在编译时从各自上游仓库拉取**最新版**；分支名自动探测，并按目标架构
（\`mipsel\`）做兼容性过滤——上游换分支、换目录结构、或某个插件不支持本架构，都不会让整条流水线崩掉。

### 6) 内置插件最新版本与上游更新日期

$(plugin_block)

### 7) 发布策略（全自动）
每次编译后：
- 更新滚动 Release \`${PREFIX}-latest\` —— **下载链接固定**，永远指向最新固件；
- **同时创建一个「时间戳 tag」的新 Release** \`${PREFIX}-YYYYMMDD-HHMM\`（北京时间），作为本次编译的快照；
- 自动清理：保留 \`latest\` + 最近 **${KEEP_RECENT}** 个时间戳版本 + 每月最后一次编译 + 当天全部。

### 8) 自动化
- **每日北京时间 21:00**（UTC 13:00）自动执行：同步上游 → 应用定制 → 编译 → 发布 → 重写本 README；
- 也支持 \`push\` 到 \`.config\` / \`custom/\` / \`scripts/\` 时自动编译；
- 也可在 Actions 页手动 \`Run workflow\`，可选是否先同步上游、是否发布 Release、MTK/开源无线、EasyTier 变体。

## 🚀 刷机
从 \`${PREFIX}-latest\` 下载 \`...squashfs-sysupgrade.bin\`：
- 已刷过 OpenWrt / ImmortalWrt：\`sysupgrade -n <固件>\`，或 LuCI「系统 → 备份/刷写固件」，首刷建议不保留配置；
- 原厂固件：先用 \`...initramfs-kernel.bin\` 经 Breed / U-Boot 中转，再 \`sysupgrade\` 到 squashfs 版本。

默认地址 **192.168.1.1**。

## 🔁 换分支 / 重新 fork 后继续使用
定制全部收敛在 **自有文件** 中，迁移时带上这些文件即可按原要求运行：

| 文件 | 作用 |
|---|---|
| \`.github/workflows/${WF_BASENAME}\` | 同步 + 编译 + 发布 + 文档 流水线 |
| \`scripts/custom/customize.sh\` | 应用全部定制（基础默认值 / 主题 / MTK 无线 / 机型 / 插件 / 插件版本表） |
| \`scripts/custom/fallback-openwrt-wifi.sh\` | MTK 无线未进入配置时回退开源 mt76/wpad |
| \`scripts/custom/release.sh\` | 生成发布说明 + \`latest\`/时间戳 发布 + 清理旧 Release |
| \`scripts/custom/gen-readme.sh\` | 生成本 README |
| \`.config\` | 目标与基础组件配置种子 |
| \`${CUSTOM_DIR}/packages.seed\` | 新增/启用插件清单（改包只改这里） |
| \`${CUSTOM_DIR}/devices.include\`、\`devices.exclude\` | 机型白名单 / 黑名单 |

上游源码：${SOURCE_URL}（分支 ${SOURCE_BRANCH}）。
镜像 / 覆盖分支：\`${CUSTOM_BRANCH}\`（其 \`${CUSTOM_DIR}/\` 目录会被编译时优先采用）。

---

_本 README 由 \`scripts/custom/gen-readme.sh\` 自动生成；要改内容请改脚本或 \`${CUSTOM_DIR}/\` 配置，勿手工大改。_
EOF
} > "$OUT"

cp "$OUT" README.md
rm -f "$OUT" 2>/dev/null || true
printf '[readme] 已生成 README.md\n'
