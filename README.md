# PiliPlus 外接屏版（AR 眼镜优化）· 自动出包流水线

基于官方 [PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus)（GPL-3.0）追加  
**外接显示器播放功能**的自动构建仓库，专为 AR 眼镜 / 头显场景优化：

- 🕶️ 手机通过 USB3 直连 AR 眼镜（XREAL/Rokid 等），无需复杂设置
- 📱 手机即遥控器：选视频、控制播放，画面推流到头显大屏观看
- 🎬 支持 B 站视频经外接屏播放，附屏可独立显示遥控面板

本仓库**不含 PiliPlus 源码**：CI 每日检查官方新版本 → 拉取官方源码 → 套补丁 → 编译 arm64 APK → 自动发 Release。

## 用户安装

到 [Releases](https://github.com/byl669/PiliPlus-extscreen-for-AR/releases/latest) 下载  
`PiliPlus-extscreen_arm64.apk` 安装（arm64 手机/设备，安卓 9 及以上）。应用内「关于 → 当前版本」可检查更新  
（更新源为本仓库的 `extscreen/updates.json`，每日自动构建跟随官方）。

- 包名 `com.example.piliplus.extscreen`，**与官方版共存**，可同时安装互不影响
- 应用名显示为「PiliPlus·外接屏版」

## 使用教程：把 B 站视频放到 AR 眼镜上看


### 第 1 步：连接 AR 眼镜

用 **USB3 线**（或原厂转接坞）把 AR 眼镜接到手机。  
系统会把眼镜识别为一块**副屏**，无需安装任何附加 App。

> 💡 若提示「未检测到外接显示器，请先连接 HDMI 或投屏」，检查线材是否支持视频输出（普通充电线不行，必须 USB3 以上）。

### 第 2 步：投播到眼镜

正常在手机上打开任意 B 站视频 → 进入播放页 → &#x70B9;**「在外接显示器播放」**：

- 🕶️ 眼镜里出现视频画面
- 📱 手机自动变成**遥控面板**：播放/暂停、拖进度条、倍速、时间显示

投屏中换集、换画质会自动接管，不用重新投。

### 第 3 步：收回手机看

在遥控面板&#x70B9;**「回到本机播放」**——自动取回眼镜里的播放进度，手机接着看。

### 常见问题

| 现象             | 处理                                      |
| -------------- | --------------------------------------- |
| 点投播提示未检测到外接显示器 | 换 USB3 线 / 直插手机口试；确认眼镜本身工作正常            |
| 眼镜有画面但黑屏       | 在手机「设置 → 显示」确认副屏已识别；重进播放页               |
| 想同时用官方版        | 直接安装官方版即可，两者包名不同、互不干扰                   |
| 应用内检查更新失败      | 等 CI 下一次构建；或直接到 Releases 页下载最新 APK 覆盖安装 |

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
