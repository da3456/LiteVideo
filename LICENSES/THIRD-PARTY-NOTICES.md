# 第三方组件与许可清单

本清单说明 **LiteVideo**（以及其上游 **YourPipe**）随源码/安装包一起分发的第三方组件、
它们的许可，以及参考但未包含其代码的项目。

- 本仓库整体按 **GNU GPL v3.0**（见仓库根目录 [LICENSE](../LICENSE)）分发。
- LiteVideo 是 [Ember5843/YourPipe](https://github.com/Ember5843/YourPipe) 的 fork；
  上游与各层的既有版权声明、许可声明**均原样保留**，本清单只做补充说明，不做替代。

---

## 1. 随包分发的第三方代码与二进制

这些文件在本仓库内，会被编进最终 HAP。

| 组件 | 位置 | 版本 | 许可 | 分发形态 |
|---|---|---|---|---|
| **MPV / libmpv** | `libmpv_napi/src/main/cpp/mpv-sdk/lib/arm64-v8a/libmpv.so*`（+ `include/mpv/`） | 二进制内标记 `mpv v0.41.0-dev-g48c985526`，SONAME `libmpv.so.2` | LGPL-2.1+（libmpv；mpv 播放器本体为 GPL-2.0+） | 动态库，随包提供 |
| **FFmpeg** | `libmpv_napi/src/main/cpp/ffmpeg-sdk/lib/arm64-v8a/libav*.a`、`libswresample.a`（+ `include/` 内 130 个逐字来自 FFmpeg 的头文件） | FFmpeg **n8.0**（`libavcodec 62.11.100` / `libavformat 62.3.100` / `libavutil 60.8.100` / `libswresample 6.1.100`） | LGPL-2.1+（见下面第 3 节说明） | **静态库**，链入 `libmpv_napi.so` |
| **dav1d** | 同上 `libdav1d.a` | 随 ffmpeg-sdk 一起 vendored，未单独标注 | BSD-2-Clause | 静态库 |
| **mbedTLS** | 同上 `libmbedtls.a` / `libmbedcrypto.a` / `libmbedx509.a` | 同上 | Apache-2.0 | 静态库 |
| **libxml2** | 同上 `libxml2.a` | 同上 | MIT | 静态库 |
| **zlib** | 链接系统/`z` | 由工具链提供 | Zlib | 链接 |
| **sherpa-onnx** | `ohpm` 依赖 `sherpa_onnx@1.13.3`（端侧 ASR，当前功能已停用，代码保留） | 1.13.0 | Apache-2.0 | ohpm 包 |

获取上述组件的完整源码：

- MPV：<https://github.com/mpv-player/mpv>（构建配方见 `libmpv/AGENTS.md` §4）
- FFmpeg：<https://ffmpeg.org/download.html>（对应 `n8.0` 发布标签）
- dav1d：<https://code.videolan.org/videolan/dav1d>
- mbedTLS：<https://github.com/Mbed-TLS/mbedtls>
- libxml2：<https://gitlab.gnome.org/GNOME/libxml2>
- zlib：<https://zlib.net>
- sherpa-onnx：<https://github.com/k2-fsa/sherpa-onnx>

## 2. 结构上派生的项目

| 项目 | 关系 | 许可 |
|---|---|---|
| **libmdk-napi**（<https://github.com/wang-bin/libmdk-napi>） | `libmpv_napi` 的 NAPI 桥接结构由此派生（历史 `mdk` 命名即来自它；产品运行时是 MPV，不含 MDK） | 该仓库的 `LICENSE` 是**未填写的 MIT 模板**（正文仍是 `Copyright (c) [year] [fullname]`），未声明可识别的 SPDX 许可。本仓库把 `libmpv_napi/LICENSE` 的占位模板改为指向本清单，并随整体项目按 GPL-3.0 分发；如需另行使用该桥接层，请直接参考上游仓库。 |
| **YourPipe**（<https://github.com/Ember5843/YourPipe>） | 本仓库的父项目，ArkTS 侧绝大部分实现与全部播放/抽取/鉴权链路的出处 | GPL-3.0 |

## 3. LGPL 静态链接的说明（重要）

FFmpeg 与 dav1d/mbedTLS/libxml2 以 **`.a` 静态库**链入本项目的 `libmpv_napi.so`，
这在 LGPL-2.1 下构成 "Combined Work"。合规要求：

1. 随包提供 LGPL 源码获取途径（见第 1 节链接）；**本仓库做到了**。
2. 让用户能**重新链接**修改后的库 —— 标准做法是同时提供本项目自己那部分的目标文件（`.o`）
   或可重编译源码。本项目的 NAPI 桥接层（`libmpv_napi/src/main/cpp/*.cpp`）**全部是源码**，
   因此用户可以用仓库内源码 + 公开的 FFmpeg 源码重放出可替换的库；
   唯一的缺口是 `libmpv.so` / FFmpeg 的**交叉编译配方**未随仓库发布（上游把它放在作者本人的
   WSL 环境里，见 `libmpv_napi/AGENTS.md` §4）。
3. 不禁止为运行修改后的版本而反向工程。本项目的 GPL-3.0 许可本身不施加任何此类限制。

> 关于许可版本：仓库内的 `ffmpeg-sdk` 头文件是 LGPL-2.1+ 的文件。我们在 vendored 的
> `libavcodec.a` / `libavformat.a` 中未探测到 x264/x265 等 GPL 组件符号，**据此判断该构建是
> LGPL 配置**；这是经验性探测，不等于原始 `configure` 命令行。若要严格确认，请查看
> `av_config` / 构建日志。

## 4. 仅作行为参考、未包含其代码的项目

这些项目的实现思路被参考或对齐（源码里以 `PipePipe …` / `NewPipe …` 形式的注释标明），
但**没有从它们复制代码**；许可不传染，列出仅为致谢与溯源。

| 项目 | 用途 | 许可 |
|---|---|---|
| [NewPipe](https://github.com/TeamNewPipe/NewPipe) | 客户端交互与浏览行为语义 | GPL-3.0 |
| [NewPipe Extractor](https://github.com/TeamNewPipe/NewPipeExtractor) | 抽取行为、流模型、解析 | GPL-3.0 |
| [PipePipe](https://github.com/InfinityLoop1308/PipePipe) | 请求行为、播放器端点选择、兼容性取舍 | GPL-3.0 |
| [SmartTube](https://github.com/yuliskov/SmartTube) | 播放失败恢复 / 队列语义 | MIT（GitHub 元数据） |
| [yt-dlp](https://github.com/yt-dlp/yt-dlp) | 流分类与地址处理思路 | Unlicense（公有域） |
| [iPlay](https://github.com/saltpi/iPlay) | 鸿蒙播放器 UI 参考 | GPL-3.0 |
| [FinVideo](https://github.com/OHPG/FinVideo) | 鸿蒙视频应用结构参考 | GPL-3.0 |
| [ClashBox](https://github.com/xiaobaigroup/ClashBox) | 鸿蒙代理配置 UI 参考 | GPL-3.0 |
| [tpc_c_cplusplus](https://gitcode.com/CPF-ApplicationTPC/tpc_c_cplusplus) | SOCKS5/HTTP 代理桥接思路参考 | 见其仓库 |
| [VLC](https://www.videolan.org/) | 硬件解码与播放策略参考 | GPL-2.0+ / LGPL-2.1+ |

应用内「关于 → 开源项目」列出的部分厂商图标仅用于致谢标识，不代表任何关联或背书。

## 5. 平台示例代码

仓库内有 **19 个 ArkTS 文件**仍带 DevEco / OpenHarmony 示例的样板头：

```
Copyright (c) 2024 Huawei Device Co., Ltd.
Licensed under the Apache License, Version 2.0 ...
```

这些声明按 GPLv3 §5 **原样保留**（Apache-2.0 与 GPL-3.0 兼容，合并作品的分发许可为 GPL-3.0）。
完整 Apache-2.0 文本：<https://www.apache.org/licenses/LICENSE-2.0>。

## 6. 图标与素材

`entry/src/main/resources/{base,dark}/media/app_icon.png` 与 `AppScope/resources/base/media/app_icon.png`
是 fork 自用的图标，与上游 YourPipe 的图标不同，用以区分两个可并存安装的应用；
其中不含任何 YouTube / Google 的商标素材。应用内的 `about_logo_*.png` 是各上游项目的官方标识，
仅用于致谢。

---

## 7. 本清单未包含什么

- **GPL-3.0 全文**在仓库根目录 [LICENSE](../LICENSE)，未做修改。
- 上游 YourPipe 的版权行（应用内「© 2025 Talon」）原样保留；fork 的改动另起一行标注。
- 本清单不构成对任何组件的再许可，也不改变任何组件原有的许可条款。
