#!/usr/bin/env bash
#
# gen-readme.sh —— 依据仓库「实际配置」重新生成 README.md
#
# 目的：让 README 永远与本分支的真实变更一致（机型、主题、新增插件、插件最新版本号、
#       发布策略、迁移说明），不需要人工维护；换上游分支 / 重新 fork 后照旧可用。
#
# 用法：gen-readme.sh [repo_root] [plugin_table_file]
# 环境变量（可选，用于文案）：
#   RELEASE_PREFIX / KEEP_DAYS / SOURCE_BRANCH / SOURCE_REPO / UPSTREAM_REPO / CUSTOM_BRANCH /
#   CUSTOM_DIR / TARGET_ID / ARTIFACT_PREFIX
#
set -Eeuo pipefail

ROOT="${1:-${GITHUB_WORKSPACE:-$PWD}}"
PLUGIN_TABLE="${2:-}"
cd "$ROOT"

CUSTOM_DIR="${CUSTOM_DIR:-custom}"
SEED="$CUSTOM_DIR/packages.seed"
INC="$CUSTOM_DIR/devices.include"
EXC="$CUSTOM_DIR/devices.exclude"
PREFIX="${RELEASE_PREFIX:-${ARTIFACT_PREFIX:-IPQ807X-ImmortalWrt}}"
KEEP_DAYS="${KEEP_DAYS:-30}"
SOURCE_BRANCH="${SOURCE_BRANCH:-openwrt-24.10}"
SOURCE_REPO="${SOURCE_REPO:-https://github.com/wdss133/immortalwrt}"
UPSTREAM_REPO="${UPSTREAM_REPO:-https://github.com/Heleguo/immortalwrt}"
CUSTOM_BRANCH="${CUSTOM_BRANCH:-custom-ipq807x}"
TARGET_ID="${TARGET_ID:-qualcommax_ipq807x}"
SOURCE_URL="${SOURCE_REPO%.git}"
UPSTREAM_URL="${UPSTREAM_REPO%.git}"

strip_list() { grep -vE '^[[:space:]]*(#|$)' "$1" 2>/dev/null | tr -d '\r' || true; }

devices_block() {
  if [ -n "$(strip_list "$INC" 2>/dev/null || true)" ]; then
    strip_list "$INC" | sed 's/^/- /'
  else
    echo "- **全部机型**（未设置白名单，按源码树该 subtarget 的全部机型编译）"
  fi
  if [ -f "$EXC" ]; then
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
| luci-theme-argon (默认主题) | 随 immortalwrt/luci feed | — | https://github.com/jerrykuku/luci-theme-argon |
| EasyTier | 见 Release 说明 | — | https://github.com/EasyTier/luci-app-easytier |
| ZeroTier | 见 Release 说明 | — | https://github.com/mwarning/zerotier-openwrt |
| ddns-go | 见 Release 说明 | — | https://github.com/sirpdboy/luci-app-ddns-go |
| iStore (luci-app-store) | 见 Release 说明 | — | https://github.com/linkease/istore |
| wechatpush (luci-app-wechatpush) | 见 Release 说明 | — | https://github.com/tty228/luci-app-wechatpush |

> 上表来自最近一次编译的发布说明；完整版本号与上游更新日期见对应 Release。
EOF
  fi
}

OUT="$(mktemp)"
{
  cat <<EOF
# ImmortalWrt IPQ807X 定制固件 CI

> 本仓库是 [Heleguo/immortalwrt](${UPSTREAM_URL})（分支 \`${SOURCE_BRANCH}\`）的 **自动编译定制分支**：
> 每日自动同步上游主线，按下面的定制编译 **${TARGET_ID}**（内核 6.6）固件并发布。
> 全部定制均以 **新增文件 + 幂等脚本** 实现，不改动上游任何既有文件，上游同步不产生冲突，
> 换上游分支 / 重新 fork 后按原要求照跑。

## ✅ 本仓库相对上游的实际变更

### 1) 编译目标与机型
- 目标：**${TARGET_ID}**（\`qualcommax / ipq807x\`，内核 **6.6**，Qualcomm ath11k 无线）
- 机型：

$(devices_block)

### 2) 默认主题
- 默认主题改为 **argon**，并在 \`/etc/uci-defaults\` 注入兜底脚本，保证首次开机即生效。
- **移除 Aurora 主题及其配置插件**（\`luci-theme-aurora\` / \`luci-app-aurora-config\`），
  存在则删除（源码树 + feeds + 软链 + 配置项全部清理），不存在时静默跳过。

### 3) 内核特性
- 启用 **\`kmod-tun\`**，用于适配 ZeroTier / EasyTier。

### 4) 新增内置插件
（来源于 \`${CUSTOM_DIR}/packages.seed\`）

$(added_block)

其中第三方插件在编译时从各自上游仓库拉取**最新版**；分支名自动探测，
上游把 \`master\` 改成 \`main\`、或改目录结构都不会打断流水线。

### 5) 内置插件最新版本与上游更新日期

$(plugin_block)

### 6) 发布策略（全自动）
每次编译后：
- 更新滚动 Release \`${PREFIX}-latest\` —— **下载链接固定**，永远指向最新固件；
- **同时创建一个「时间戳 tag」的新 Release** \`${PREFIX}-YYYYMMDD-HHMM\`（北京时间），作为本次编译的快照；
- 自动清理：仅保留 \`latest\` 与最近 **${KEEP_DAYS}** 天的时间戳 Release，避免无限增长。

### 7) 自动化
- **每日北京时间 21:00**（UTC 13:00）自动执行：同步上游 → 应用定制 → 编译 → 发布 → 重写本 README；
- 也可在 Actions 页手动 \`Run workflow\`，可选是否先同步上游、EasyTier 变体、Release 保留天数。

## 🚀 刷机
从 \`${PREFIX}-latest\` 下载对应机型文件：
- 已刷过 OpenWrt / ImmortalWrt：\`sysupgrade -n <...sysupgrade.bin>\`（或 LuCI「系统 → 备份/刷写固件」，首刷建议不保留配置）；
- 原厂 / 未刷过：经 uboot / breed 或 initramfs 中转，再用对应 \`factory\` 镜像。

> 具体默认 IP 与密码以该机型在 ImmortalWrt 上游的默认值为准。

## 🔁 换分支 / 重新 fork 后继续使用
定制全部收敛在 **自有文件** 中，迁移时带上这些文件即可按原要求运行：

| 文件 | 作用 |
|---|---|
| \`.github/workflows/ImmortalWrt-IPQ807X-Daily.yml\` | 同步 + 编译 + 发布 + 文档 流水线 |
| \`scripts/custom/immortalwrt-customize.sh\` | 应用全部定制（主题 / 机型 / 插件 / 插件版本表） |
| \`scripts/custom/release.sh\` | 生成发布说明 + \`latest\`/时间戳 发布 + 清理旧 Release |
| \`scripts/custom/gen-readme.sh\` | 生成本 README |
| \`${CUSTOM_DIR}/packages.seed\` | 新增/启用插件清单（改包只改这里） |
| \`${CUSTOM_DIR}/General.config\` | 通用配置（主题、中文、基础工具、插件开关） |
| \`${CUSTOM_DIR}/IPQ807X.config\` | 目标 board/subtarget 配置 |
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
