<!-- prettier-ignore -->
<div align="center">

<img src="./AppScope/resources/base/media/app_icon.png" alt="LiteVideo" height="96" />

# LiteVideo

**An unofficial HarmonyOS / OpenHarmony YouTube client — a personal-use fork of YourPipe**

[![Fork of](https://img.shields.io/badge/fork%20of-Ember5843%2FYourPipe-blue?style=flat-square)](https://github.com/Ember5843/YourPipe)
[![License](https://img.shields.io/badge/license-GPL--3.0-yellow?style=flat-square)](LICENSE)
[![Player](https://img.shields.io/badge/player-MPV-brightgreen?style=flat-square)](https://github.com/mpv-player/mpv)

> Unofficial client. Not affiliated with YouTube or Google LLC.
> 个人自用版本：不发布 Release、不上架应用市场、不提供技术支持。

</div>

---

## 1. 概述

LiteVideo 是 [YourPipe](https://github.com/Ember5843/YourPipe)（作者 Talon）的 fork，分叉基点为上游
`v0.7.0`（commit `c3d985bb`，2026-10-22）。本仓库仅收录在该基点之上进行的自用改动；播放器内核、
YouTube 抽取器、鉴权链路、下载、代理与实验性功能等均沿用上游实现，其行为以上游为准。

许可证不变：**GNU GPL-3.0**（全文见 [LICENSE](LICENSE)）。上游授予的复制、修改、再分发及商用权利
同样适用于本仓库，本 fork 不附加任何额外限制。

| 项目 | 值 |
|---|---|
| Bundle name | `com.github.da3456.litevideo` |
| Application label | `LiteVideo` |
| Version | `1.0.23`（`versionCode 1000223`，编号独立于上游 `0.x` 线） |
| Upstream | `com.talon.yourpipe` · `Ember5843/YourPipe` |
| Target SDK | `26.0.0`（最低兼容 `6.1.0(23)`）· HarmonyOS · stage model |
| Supported devices | phone · tablet · 2-in-1 · TV · car |

包名与上游刻意不同：两个 HAP 位于相互隔离的应用沙箱，可与原版 YourPipe 共存安装、分别登录不同账号，
设置与数据互不影响。

## 2. 与上游的差异

以下逐条列出本 fork 在原版 YourPipe 之上做的应用功能改动，均为用户可感知的变化。

- **订阅会同步到 YouTube 账号**：登录后关注 / 取消关注同时写回服务端，换设备或重装后订阅列表一致；
  写入失败会回滚本地状态并给出提示。
- **订阅列表与账号核对**：以账号里的频道名单为准，在订阅页显示或下拉刷新、进入播放详情页、
  进入我的页、完成登录后自动对齐；离线时刚订阅的频道不会被误删。
- **取消订阅需要确认**：卡片、频道页、播放详情页、频道长按菜单等全部入口都会先弹确认对话框，
  确认后才退订，避免误点灰色小按钮。
- **订阅按钮样式统一**：播放页、频道页与订阅管理页改为同一种圆形按钮。
- **首页卡片长按菜单改为从底部弹出**：不再把卡片顶得位移，下滑把手或点击空白处收起。
- **频道条目有独立的长按菜单**：只提供频道级操作（订阅 / 退订 / 不推荐该频道），不与视频卡片菜单混用。
- **信息流卡片新增「不感兴趣」「不推荐该频道」「保存到稍后观看」**：点击后提交给 YouTube 服务端，
  由服务端决定后续推荐；「保存到稍后观看」写入账号的稍后观看列表。客户端不做任何本地屏蔽。
- **首页信息流按批加载**：一次取 3 页（约 60 条）后停止自动翻页，下拉刷新或在首页再次点击首页页签
  开启下一批。内容不做去重、不做过滤，服务端推什么就显示什么。
- **卡片显示对齐 YouTube 网页端**：发布时间改为「4 小时前」一类的短格式，卡片信息行等高对齐。
- **修复长按缩略图无响应**：缩略图区域同样可以呼出卡片菜单。
- **移除收藏功能**：视频卡片的收藏按钮、卡片长按菜单里的收藏项、播放列表卡片的心形按钮以及
  「收藏的视频」分区全部去掉，底部第三个页签改为歌单（Playlists）。
- **移除上游社区与商店入口**：「关于」页的 QQ 群与 Telegram 群条目、更新页的 AppGallery 测试渠道按钮。
  这些渠道由原作者运营，保留会把本 fork 的用户引到原版。

播放内核、清晰度与流获取、网络与代理、下载、搜索、字幕与翻译、直播聊天等其余功能，
以及原版的界面结构和使用方式，全部保持不变。

## 3. 版本记录

| 版本 | 日期 | 说明 |
|---|---|---|
| 1.0.23 | 2026-11-05 | 首个对外提交的整理版本：完成 fork 身份改造、README 与第三方许可清单重写、全部自用改动入库（单个提交，基点 `c3d985bb`）。 |

`1.0.6`–`1.0.22` 为本地自用迭代，仅以未签名 HAP 形式在本人设备上安装，未单独留档。应用内「更新检查」
读取本仓库 Releases；本 fork 未发布 Release，因此检查会静默返回无结果。

## 4. 构建

环境要求：DevEco Studio 或 HarmonyOS 命令行工具链，SDK `6.1.0(23)` 及以上。

```bash
cp build-profile.template.json5 build-profile.json5   # 本机配置，仓库中不提交
ohpm install --all
devecocli build                                       # 默认 debug 全产品构建
```

- `build-profile.json5` 为 git-ignored 的本机文件，签名材料不得提交（`.githooks/pre-commit` 会拦截）。
  无签名配置时产物为 `entry/build/default/outputs/default/entry-default-unsigned.hap`，需自行签名后侧载。
- 实际视频播放依赖 `arm64-v8a` 的 MPV 二进制；`x86_64`（模拟器）使用 `libmpv_napi` 的 UI stub。
- `libmpv.so.2` 与 FFmpeg 静态库为外部预先构建后随仓库提供，不由 Hvigor 生成，
  见 [libmpv_napi/AGENTS.md](libmpv_napi/AGENTS.md) §4。

## 5. 隐私

- 不含任何遥测或统计上报；运行日志仅在应用内本地留存，可在「设置 → 网络 → 应用日志」中开关。
- 登录通过应用内 WebView Cookie 或设备码 OAuth 完成，凭证仅保存在本机应用沙箱。
- 本 fork 不收集、不上传用户数据，也不代任何用户保管账号凭证。

## 6. 风险提示

本项目是非官方客户端，通过逆向 InnerTube 获取音视频流，与 YouTube 服务条款存在冲突；使用登录态时
可能触发风控（机器人校验、登录失效等）。该风险为所有第三方 YouTube 客户端共有，本仓库不承担相应后果。

## 7. License

GPL-3.0，见 [LICENSE](LICENSE)。第三方组件的许可、版本与出处清单见
[LICENSES/THIRD-PARTY-NOTICES.md](LICENSES/THIRD-PARTY-NOTICES.md)。
上游项目的版权声明，以及各源文件中既有的 `© Huawei Device Co., Ltd.` 许可样板头，均原样保留。

如需支持此类工作，建议直接支持上游 **YourPipe**，以及底层项目的维护者：**MPV**、**FFmpeg**、
**NewPipe** / **NewPipe Extractor** / **PipePipe**。本仓库不提供捐赠或收款入口。
