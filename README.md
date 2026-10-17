# PiliPlus 外接屏版（AR 眼镜优化）· 自动出包流水线

基于官方 [PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus)（GPL-3.0）追加
**外接显示器播放功能**的自动构建仓库，专为 AR 眼镜 / 头显场景优化：

- 🕶️ 手机通过 USB3 直连 AR 眼镜（XREAL/Rokid 等），无需复杂设置
- 📱 手机即遥控器：选视频、控制播放，画面推流到头显大屏观看
- 🎬 支持 B 站视频经外接屏播放，附屏可独立显示遥控面板

本仓库**不含 PiliPlus 源码**：CI 每日检查官方新版本 → 拉取官方源码 → 套补丁 → 编译 arm64 APK → 自动发 Release。

## 用户安装

到 [Releases](https://github.com/byl669/PiliPlus-extscreen-for-AR/releases/latest) 下载
`PiliPlus-extscreen_arm64.apk` 安装。应用内「关于 → 当前版本」可检查更新
（更新源为本仓库的 `extscreen/updates.json`，每日自动构建跟随官方）。

- 包名 `com.example.piliplus.extscreen`，与官方版共存
- 外接屏功能默认关闭，在「设置」中手动开启

## 仓库结构

```
extscreen/
├── 0001-extscreen-core.patch      核心功能补丁（12 文件，--3way 可重放）
├── new-files/                     新增文件（外接屏页面/UpdateInstaller/ExternalDisplayManager 等）
├── media_kit.tar.gz               vendored media_kit（含外接屏必需的多屏隔离修复，手动上传）
├── media_kit.sha256               media_kit.tar.gz 的 SHA256 校验值
├── updates.json                   应用内更新清单（CI 自动回写）
├── ext-counter                    ext.N 计数器（CI 递增）
└── last-tag                       上次构建的官方 tag（CI 回写）
.github/workflows/extscreen-build.yml   构建工作流（每日 06:30 北京时间 + 手动触发）
```

## 版本规则

- 版本名 `<官方tag>-ext.N`，versionCode = 5474 + N，严格递增
- 签名固定（Secrets 中的 keystore），换签名将导致所有设备无法覆盖升级
