> [!WARNING]
> **当前签名状态与首次打开说明**
>
> Snoopy 目前使用 ad-hoc 签名，尚未使用 Apple Developer ID 签名或完成 Apple 公证。macOS 可能提示“无法验证开发者”或阻止打开。仅当文件来自你信任的来源时：先尝试打开一次，然后前往 **系统设置 → 隐私与安全性**，滚动到页面底部，在对应提示旁选择 **仍要打开** 并再次确认。
>
> 我们欢迎熟悉 macOS Developer ID、Hardened Runtime 和公证流程的贡献者通过 [Issue](../../issues) 讨论方案，或提交改进构建/签名流程的 Pull Request。请勿在 Issue、PR 或仓库中上传证书、私钥或其他签名凭据。

# Snoopy Saver

**简体中文** · [English](README_EN.md)

> [!IMPORTANT]
> **最新版本：Snoopy 1.1（V1.1.0）· 2026-07-21**
>
> 1.1 重点修复了长时间运行后的高功耗、风扇升速和 IdleScene 掉帧，并重构播放器、图层、HEIC 解码缓存与后台任务的生命周期，同时更新了系统设置中的封面缩略图。
>
> - [GitHub Release：分卷下载与完整更新说明](https://github.com/Cyber-Yichen/Snoopy-Saver/releases/tag/V1.1.0)——下载安装器 ZIP 和 4 个 DMG 分卷，全部放在同一目录后运行安装器。
> - [百度网盘：完整压缩包](https://pan.baidu.com/s/17pI0PTYSRbr7G-a06zrEBg?pwd=f2vm)——文件 `SnoopyScreenSaver 1.1zip.zip`，提取码 `f2vm`。

Snoopy Saver 的核心目标，是把 tvOS 中的史努比屏幕保护程序尽可能完整地移植到 macOS：保留全屏动画，也重建由背景、角色、访客、天气效果和调色板共同组成的多图层场景，并按照日期、时间、天气和近期播放记录选择下一段内容。

本项目当前已经完成：

- 从 tvOS 26.5 模拟器识别并适配完整的场景目录；
- 重建多图层 IdleScene、半色调背景和角色动作衔接；
- 解析并复现 16 个官方转场分类、13 个转场配对和五种视觉样式，并让转场结束与全屏动画结尾对齐；
- 支持节日、史努比生日、时间段、天气和日常活动等特殊内容；
- 提供同时兼容 Apple Silicon 与 Intel Mac 的通用屏保构建。

## 你可以看到什么

基于本项目测试使用的 tvOS 26.5 素材集：

| 内容 | 数量 / 表现 |
| --- | --- |
| 全屏故事动画 | 65 个 ActiveScene |
| 多图层休闲场景 | 39 个 IdleScene |
| 环境调色板 | 84 套日期、时间与天气配色 |
| 官方转场 | 16 个场景分类、13 个条件配对；横向、时钟、圆形、思考气泡、睡梦气泡 5 种样式 |
| 特殊内容 | 节日、季节、纪念日、日常作息、天气、日出日落与月相等 |

屏保启动时有相同概率进入全屏动画或多图层场景。IdleScene 通常持续 20–60 秒，期间史努比会更换动作，Woodstock 和其他访客也可能出现，随后插播一段全屏动画。无声音、无时钟和文字叠加。

日期主题覆盖四季、圣诞节/平安夜、万圣节、感恩节、新年、情人节、农历新年、地球日、航空日、父亲节、母亲节、美国独立日，以及登月、首篇 Peanuts 漫画、Snoopy 首次登场、Snoopy 生日和贝多芬生日等纪念日。作息主题覆盖早晨、上学/上班、早午餐、午餐、下午、晚餐、睡前和深夜；天气主题覆盖晴朗、雾、风、雨、雷暴、冰冻和雪。

### 不同时间与季节

下面的画面由最终版场景目录按照对应日期、时间和天气条件实际评分后选出。相同条件下仍可能出现其他同分场景，近期播放记录也会影响最终选择。

<table>
  <tr>
    <td width="50%"><img src="Assets/spring-morning.jpg" alt="春日清晨"><br><sub>春日清晨 · 晴朗</sub></td>
    <td width="50%"><img src="Assets/summer-afternoon.jpg" alt="夏日下午"><br><sub>夏日下午 · 晴朗</sub></td>
  </tr>
  <tr>
    <td width="50%"><img src="Assets/autumn-evening.jpg" alt="秋日傍晚"><br><sub>秋日傍晚 · 有风</sub></td>
    <td width="50%"><img src="Assets/winter-late-night.jpg" alt="冬季深夜"><br><sub>冬季深夜 · 下雪</sub></td>
  </tr>
</table>

### 8 月 10 日：史努比生日彩蛋

每年 8 月 10 日，日期相关性会优先触发史努比生日内容。冒烟测试确认清晨、下午、傍晚和深夜四个时段均能选中生日专属的全屏故事、多图层场景、访客与角色动作。

![8 月 10 日史努比生日彩蛋](Assets/birthday-aug10.jpg)

<sub>测试日期：2026-08-10，Asia/Shanghai；截图来自全屏生日场景。</sub>

> 本仓库只包含屏保实现源码、构建/安装/验证脚本和设置缩略图，不包含素材获取代码、实现分析记录、用于运行的 Apple 或 Peanuts 媒体，也不提交构建好的 `.saver`。README 中的少量低分辨率截图仅用于功能展示与测试记录。

## 工作方式

```mermaid
flowchart TD
    A[启动屏保] --> B[黑屏淡入]
    B --> C{首次场景 50 / 50}
    C --> D[IdleScene 多图层场景]
    C --> E[ActiveScene 全屏动画]
    D --> F[日期 / 时间 / 天气相关性评分]
    F --> J[最近播放与频率衰减]
    J --> K[最高分并列时随机]
    K --> G[角色动作、访客与环境效果]
    G -->|20–60 秒| E
    E --> H[提前预载下一组 IdleScene]
    H --> I[官方转场与视频结尾对齐]
    I --> D
```

## 主要技术

- Swift 5、AppKit 与 `ScreenSaver.framework`
- AVFoundation：全屏视频、分段动作和预加载
- Core Animation：多图层合成、蒙版和转场
- Core Location + Open-Meteo：可选的天气、日出和日落匹配
- ImageIO：HEIC 序列解码与受限缓存
- Shell：通用架构构建和安装辅助

最低目标系统为 macOS 12。屏幕比例适配覆盖 16:9、16:10、3:2、21:9 和 4:3，不拉伸画面。

## 从源码构建

需要：

- macOS 与 Xcode
- 由使用者自行合法准备的本地素材

```bash
Scripts/build_saver.sh
```

本仓库不提供 Apple 素材、素材获取下载器、解密工具或获取教程。完整构建要求使用者自行准备其有权访问的本地素材，并放入构建脚本期望的 `LocalAssets/` 目录。只验证代码编译、不打包媒体时可运行：

```bash
Scripts/build_saver.sh --code-only
```

所有本地媒体路径都被 `.gitignore` 排除。

### 1080p 与 CDN 精简版

仓库提供的变体脚本只处理使用者已经合法准备的本地素材，不负责从 Apple 获取内容。完整低清流水线会先按 Asset ID 只保留一个首选版本。普通视频由 FFmpeg 转为最高 1920×1080、HEVC Main 8-bit、无音轨的低码率文件；Apple HEVC Alpha 角色/访客视频不能由普通 libx265 正确处理，因此随后在 macOS 上优先恢复 Apple 原生 1080p 文件，只有 4K 来源时才用 AVFoundation 的 HEVC-with-Alpha 编码器缩放。最后再用 ImageIO 处理超出 1080p 的 HEIC Alpha 帧：

```bash
python3 Scripts/build_lowres_assets.py LocalAssets .tmp/lowres-assets
Scripts/preserve_alpha_movies.sh LocalAssets .tmp/lowres-assets
Scripts/downscale_heic_assets.sh .tmp/lowres-assets
Scripts/validate_alpha_movies.sh .tmp/lowres-assets
python3 Scripts/validate_prepared_assets.py .tmp/lowres-assets --lowres
```

普通 MOV 步骤需要 FFmpeg；本项目的发布流水线在 Linux VM 中运行它，因此不要求在 macOS 上安装 Homebrew。Alpha MOV 与 HEIC 步骤使用 Xcode 自带的 Swift、AVFoundation 和系统 ImageIO。tvOS 26.5 测试集中的 258 段透明 MOV 会逐文件检查 `ContainsAlphaChannel`，并限制在 1920×1080 以内。

CDN 精简版保留少量可离线播放的视频和完整元数据，其余低清视频写入带文件大小和 SHA-256 的清单：

```bash
python3 Scripts/build_cdn_lite_assets.py \
  .tmp/lowres-assets .tmp/cdn-lite \
  --cdn-base-url https://cdn.snoopy.bdmzw.top/media/1.1-r2 \
  --payload-output .tmp/cdn-payload
Scripts/build_variants.sh .tmp/lowres-assets .tmp/cdn-lite
```

构建产物位于 `.build/Variants/`：标准版、1080p 版、CDN 精简版，以及可单独分发的清单和下载脚本。
`.tmp/cdn-payload` 可原样发布到源站 `/www/wwwroot/snoopy.bdmzw.top/media/1.1-r2`。
发布后，同一版本的远程清单位于 `https://cdn.snoopy.bdmzw.top/media/1.1-r2/cdn-manifest.json`。

CDN 精简版每次启动都会在后台检查同源 HTTPS 清单，并把缺失或变化的媒体下载到固定目录 `~/Library/Application Support/Snoopy/Assets/Resolved`。本地文件的大小、SHA-256 和记录的修改时间与服务器一致时会直接复用，不重复下载；新文件只有在校验完成后才原子替换。多显示器同时启动时会合并短时间内的重复检查。

完整 4K/1080p 包始终优先使用包内素材，只有包内缺失的文件才会回退到 CDN 缓存，避免旧缓存覆盖透明视频。三个构建变体使用独立的 Bundle ID、Swift 模块名和运行时主类，可以安全地由 macOS 屏保辅助进程同时发现。

CDN 版会记录启动、清单校验、下载/复用结果、实际媒体来源、场景、转场和播放错误。日志限制为 5 MB，并保留一份轮换备份；运行 `Scripts/collect_cdn_logs.sh` 可将当前日志复制到桌面，方便附在 Issue 中。屏保沙盒内的原始路径通常是 `~/Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver/Data/Library/Logs/Snoopy/CDN-Lite.log`。

也可以手动运行同样受路径和 SHA-256 约束的下载器：

```bash
python3 Scripts/download_cdn_assets.py cdn-manifest.json \
  --base-url https://cdn.snoopy.bdmzw.top/media/1.1-r2
```

安装本地构建：

```bash
Scripts/install_saver.sh
```

## 安全与稳定性

发布前测试包括：

- AddressSanitizer 构建完成 12 次快速场景切换，无越界访问或释放后使用；
- 普通构建完成 20 次快速强制切换，根图层无持续累积，停止后清空；
- 原生验证 258 段 HEVC Alpha 视频均保留透明通道且不超过 1920×1080，CDN 实际返回样本也通过像素级透明度检查；
- CDN 更新器确认首次下载后，第二次运行对一致文件执行零重复下载；
- HEIC 解码缓存限制为 256 MB；官方转场帧按阶段释放，屏保停止时清空全部媒体缓存；
- 播放器、预加载、通知、KVO、时间观察器、定位和网络会话均显式清理；
- 运行时代码不执行外部命令，不包含第三方二进制或可执行资源；
- 天气请求仅通过 HTTPS 访问 Open-Meteo，并使用无 Cookie、无磁盘缓存、带超时和响应大小限制的临时会话。

本轮修复后的 1440×900 测试窗口内，1080p 构建 6 次强制切换峰值常驻内存为 746 MB，CDN 精简构建 4 次切换为 764 MB；停止后所有根图层均清空。不同素材、分辨率、显示器和 macOS 版本会产生不同结果。

## 参与贡献

欢迎通过 Issue 报告黑屏、画面比例、转场、素材选择和兼容性问题，也欢迎提交 Pull Request。涉及签名、公证或自动发布时，请只贡献流程、配置和文档，不要提交任何个人证书或密钥。

提交前请确认：

- 没有加入 `LocalAssets/`、MOV、HEIC、`.saver` 或其他 Apple/Peanuts 媒体；
- 能完成代码构建及相关 Smoke Test；
- 新增行为在 Apple Silicon 和 Intel 目标上都可编译。

## 免责声明

本项目是独立的非官方学习与技术交流项目，与 **Peanuts Worldwide、花生漫画、Apple Inc.** 及其关联公司均无隶属、授权、认可或合作关系。

Snoopy、Peanuts 及相关角色、名称和素材的权利归其各自权利人所有；Apple、tvOS、macOS 及相关商标和素材的权利归 Apple Inc. 所有。本仓库不提供、授权或授予任何第三方媒体素材的再分发权利。请仅在适用法律及你拥有合法访问权限的设备和模拟器环境中使用本项目。
