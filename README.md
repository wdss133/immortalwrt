# 小米 CR6608 固件自动编译

> 本仓库是 [Heleguo/immortalwrt](https://github.com/Heleguo/immortalwrt)（分支 `openwrt-24.10`）的 **自动编译定制分支**：
> 每日自动同步上游主线，按下面的定制编译 **小米 CR6608（MT7621 / ramips-mt7621）** 固件并发布。
> 该上游 fork 相对 ImmortalWrt 官方的关键增强是 **MTK 闭源无线驱动 + MTK PPE 硬件加速补丁**，
> 因此源码必须取自本仓库 / 该 fork，换成 ImmortalWrt 官方源会丢掉 `package/mtk` 与 ramips 硬加速补丁。
> 全部定制均以 **新增文件 + 幂等脚本** 实现，不改动上游既有文件，上游同步不产生冲突。

## ✅ 本仓库相对上游的实际变更

### 1) 编译目标与机型
- 目标：**ramips / mt7621**，机型：`xiaomi_mi-router-cr6608`

- xiaomi_mi-router-cr6608

### 2) 无线与硬件加速
- **MTK 闭源无线驱动**（`package/mtk/mt7915`，MTK SDK 的 `mt_wifi`）+ 配套管理界面 `luci-app-mtk`
  - 脚本会自动为缺失的 `Build/Prepare` 打补丁，并移除与之冲突的开源无线栈
    （`wpad-*` / `kmod-mac80211` / `wifi-scripts`）
  - 若最终未进入配置，会自动回退到开源 **mt76/wpad**，保证一定产出可用固件
  - 由 `MTK_WIFI` 控制：`auto`（默认，先试闭源）/ `on` / `off`
- **硬件加速**：使用内核自带 **MTK PPE**（`CONFIG_NET_MEDIATEK_SOC`，MT7621 的 `mtk_eth_soc`）
  + `kmod-nft-offload` 流卸载

### 3) 默认主题
- 默认主题改为 **argon**，并在 `/etc/uci-defaults` 注入兜底脚本，首次开机即生效。
- **移除 Aurora 主题及其配置插件**（`luci-theme-aurora` / `luci-app-aurora-config`），
  存在则删除（源码树 + feeds + 软链 + 配置项全部清理），不存在时静默跳过。

### 4) 内核特性
- 启用 **`kmod-tun`**，用于适配 ZeroTier / EasyTier。

### 5) 新增内置插件
（来源于 `custom/packages.seed`）

- luci-theme-argon
- luci-app-argon-config
- kmod-tun
- easytier-noweb
- luci-app-easytier
- zerotier
- luci-app-zerotier
- ddns-go
- luci-app-ddns-go
- luci-app-store
- luci-lib-taskd
- luci-lib-xterm
- taskd
- luci-compat
- luci-lua-runtime
- luci-app-wechatpush

第三方插件在编译时从各自上游仓库拉取**最新版**；分支名自动探测，并按目标架构
（`mipsel`）做兼容性过滤——上游换分支、换目录结构、或某个插件不支持本架构，都不会让整条流水线崩掉。

**Go 类插件的自动版本降级**：openwrt-24.10 自带 Go 1.23，而上游插件经常很快跟进到更高版本
（例如 ddns-go 6.13+ 要求 go ≥ 1.25）。脚本会自动读取本分支可用的 Go 版本，
把这类插件**钉到最新的、Go 够用的上游 tag**，并自动重算 `PKG_HASH`——上游以后又发新版也无需人工干预。
若某个包最终仍无法编译，编译阶段会自动剔除该包并重试，保证固件一定能产出，
被剔除的包会列在 Release 说明的「本次未编入的包」一节。

### 6) 内置插件最新版本与上游更新日期

| 插件 | 版本 | 上游最近更新 | 仓库 |
|---|---|---|---|
| kmod-tun | (见固件清单) | 随内核 6.6 | openwrt base |
| EasyTier (luci-app-easytier) | 2.6.4 | 2026-09-25 | https://github.com/EasyTier/luci-app-easytier |
| ZeroTier | 1.16.0 | 2025-09-12 | https://github.com/mwarning/zerotier-openwrt |
| ddns-go | 6.12.5 | 2026-06-23 | https://github.com/sirpdboy/luci-app-ddns-go |
| iStore (luci-app-store) | 0.2.1-r1 | 2026-09-25 | https://github.com/linkease/istore |
| wechatpush (luci-app-wechatpush) | 3.6.13 | 2026-10-10 | https://github.com/tty228/luci-app-wechatpush |
| Argon 主题（默认） | 2.4.3 | 2026-09-03 | https://github.com/jerrykuku/luci-theme-argon |
| MTK 闭源无线（mt_wifi / luci-app-mtk） | 20230628-7a2544-TEST | (随本仓库) | MTK SDK（仓库内 package/mtk） |

### 7) 发布策略（全自动）
每次编译后：
- 更新滚动 Release `CR6608-latest` —— **下载链接固定**，永远指向最新固件；
- **同时创建一个「时间戳 tag」的新 Release** `CR6608-YYYYMMDD-HHMM`（北京时间），作为本次编译的快照；
- **每个月的最后一次编译自动作为月度归档保留**；
- 保留规则为并集：`latest` + 最近 **36** 个时间戳版本 + 每月最后一次 + 当天全部，
  其余旧 Release 自动清理，改包只改 `custom/packages.seed`。

### 8) 自动化
- **每日北京时间 21:00**（UTC 13:00）自动执行：同步上游 → 应用定制 → 编译 → 发布 → 重写本 README；
- 也支持 `push` 到 `.config` / `custom/` / `scripts/` 时自动编译；
- 也可在 Actions 页手动 `Run workflow`，可选是否先同步上游、是否发布 Release、MTK/开源无线、EasyTier 变体。

## 🚀 刷机
从 `CR6608-latest` 下载 `...squashfs-sysupgrade.bin`：
- 已刷过 OpenWrt / ImmortalWrt：`sysupgrade -n <固件>`，或 LuCI「系统 → 备份/刷写固件」，首刷建议不保留配置；
- 原厂固件：先用 `...initramfs-kernel.bin` 经 Breed / U-Boot 中转，再 `sysupgrade` 到 squashfs 版本。

默认地址 **192.168.1.1**。

## 🔁 换分支 / 重新 fork 后继续使用
定制全部收敛在 **自有文件** 中，迁移时带上这些文件即可按原要求运行：

| 文件 | 作用 |
|---|---|
| `.github/workflows/ImmortalWrt-CR6608-Daily.yml` | 同步 + 编译 + 发布 + 文档 流水线 |
| `scripts/custom/customize.sh` | 应用全部定制（基础默认值 / 主题 / MTK 无线 / 机型 / 插件 / 插件版本表） |
| `scripts/custom/fallback-openwrt-wifi.sh` | MTK 无线未进入配置时回退开源 mt76/wpad |
| `scripts/custom/release.sh` | 生成发布说明 + `latest`/时间戳 发布 + 清理旧 Release |
| `scripts/custom/gen-readme.sh` | 生成本 README |
| `.config` | 目标与基础组件配置种子 |
| `custom/packages.seed` | 新增/启用插件清单（改包只改这里） |
| `custom/devices.include`、`devices.exclude` | 机型白名单 / 黑名单 |

上游源码：https://github.com/wdss133/immortalwrt（分支 openwrt-24.10）。
镜像 / 覆盖分支：`custom-cr6608`（其 `custom/` 目录会被编译时优先采用）。

---

_本 README 由 `scripts/custom/gen-readme.sh` 自动生成；要改内容请改脚本或 `custom/` 配置，勿手工大改。_
