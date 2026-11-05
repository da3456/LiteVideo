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

以下逐条列出本 fork 相对上游基点 `c3d985bb` 的全部改动。

- **独立应用身份**：包名改为 `com.github.da3456.litevideo`，厂商改为 `da3456`，应用名 `LiteVideo`
  覆盖全部 14 个语言资源，图标改为浅色 / 深色两套配色；可与原版 YourPipe 共存安装、数据互不影响。
- **仓库与更新指向本 fork**：「关于」页、检查更新、源码链接均指向 `da3456/LiteVideo`；
  `UpdateChecker` 继续走 `releases.atom`，不引入匿名 REST 限流问题。
- **保留上游署名**：「关于」页新增「上游项目 YourPipe」入口与 fork 说明段落，页脚保留上游版权行并追加
  `Fork © 2026 da3456`；应用内更新日志第一条为 fork 自己的改动，上游历史条目原样保留。
- **版本号与上游脱钩**：自 `1.0.x` 独立编号，且 `versionCode` 始终高于上游 GitHub Release，
  避免启动时的静默检查把用户指向原版仓库。
- **订阅状态写回服务端**：关注 / 取消关注在更新本地列表的同时提交 Innertube
  `subscription/subscribe` 与 `subscription/unsubscribe`，写入失败回滚本地状态并提示
  （`yt_sub_write_failed`）；未登录时仅本地生效，登录时不做批量补传。
- **订阅名单双向核对**（`common/SubscriptionStateSync`）：以云端频道名单为准裁剪本地条目，由持久化的
  `SubscriptionUser.fromCloud` 标记控制；本地刚写入的条目在 30 秒宽限期（`LOCAL_MUTATION_GRACE_MS`）
  内不参与裁剪，离线订阅不会被误删。触发点为订阅页显示与下拉刷新、播放详情页、我的页、登录完成。
- **取消订阅增加确认**：卡片、频道页、播放详情页、频道长按菜单等全部入口都先弹确认对话框，
  确认后才执行移除并写回云端，避免灰色小按钮一键退订。
- **订阅按钮样式统一**：改为圆形 pill 形态，覆盖播放页、频道页与订阅管理页。
- **首页卡片长按改为底部半模态面板**：替换上游 220vp 浮层（会把卡片顶得位移），面板满宽、高度随内容确定、
  背景虚化遮罩，下滑把手或点击空白处收起；顶部拖拽条为自绘控件，因为在当前 SDK 下
  `SheetType.BOTTOM` 搭配单个 `FIT_CONTENT` detent 时系统 `dragBar` 不渲染。
- **频道条目独立长按菜单**（`common/components/ChannelContextMenu`）：只显示频道级操作
  （订阅 / 退订 / 不推荐该频道），不与视频卡片菜单混用。
- **信息流反馈改为服务端提交**（`common/FeedFeedbackStore`）：「不感兴趣」「不推荐该频道」提交服务端下发的
  `feedbackToken`，「保存到稍后观看」写入账号的 Watch Later 列表；不做任何客户端本地屏蔽。
  token 通过深度遍历卡片 JSON 获取（上限 28 层），结果按 videoId 缓存并限额。
- **修复反馈请求体形状**：Innertube `FeedbackRequest` 的 token 字段是 `repeated`，上游按单数
  `feedbackToken` 构造时 proto3 会静默丢弃该字段（服务端返回 200 但不记录）；改为 `feedbackTokens`
  数组提交，并以响应 `feedbackResponses[].isProcessed` 判定是否真正落库。
- **修复缩略图长按无响应**：卡片缩略图层的拖拽手势会吞掉长按事件，关闭该层 `draggable` 后图片区域
  同样可以呼出菜单。
- **首页信息流按批供给**：一批 3 页（约 60 条），取满后停止自动翻页；下拉刷新或在首页再次点击首页页签
  开启下一批。列表内容不做去重、不做过滤，服务端返回什么就显示什么。
- **卡片显示对齐 YouTube 网页端**：相对发布时间压缩为 `4h ago` 一类短格式（`common/utils/PublishTimeFormat`）、
  卡片信息行等高对齐等。
- **移除收藏界面**：视频卡片收藏按钮、卡片长按菜单收藏项、播放列表卡片心形按钮及「收藏的视频」分区全部去除，
  底部第三个页签改为 Playlists（`yt_tab_playlists`）；`favorites` 存储、备份 / 恢复与清除全部数据的接线保留。
- **移除上游社区与商店入口**：「关于」页的 QQ 群与 Telegram 群条目、更新页的 AppGallery 测试渠道按钮。
  这些渠道由原作者运营，保留会把本 fork 的用户引到原版。
- **许可证与文档整理**：新增 `LICENSES/THIRD-PARTY-NOTICES.md`（vendored MPV / FFmpeg / dav1d / mbedTLS /
  libxml2 的版本、出处与静态链接分析，以及被参考项目的许可清单）；`libmpv_napi/LICENSE` 的空 MIT 模板
  占位符替换为 GPL-3.0 与第三方声明；本 README 重写为 fork 说明。
- **文案覆盖 14 份语言资源**：新增与修改的用户可见文案同步到全部语言，未使用的历史 key
  （`yt_action_favorite`、`yt_tab_favorites`、`yt_about_qq_group`、`yt_about_tg_group`、
  `yt_update_open_appgallery`、`yt_home_no_new_videos`）保留在资源中，仅为减少与上游的合并冲突。

未改动的部分：播放内核（MPV + vendored FFmpeg）、抽取器与鉴权、SABR / PoToken 链路、HLS、网络与代理、
下载引擎、SponsorBlock / DeArrow / AiSList、直播聊天、翻译服务、端侧 ASR —— 全部为上游实现。
第三方组件的许可与出处见 [LICENSES/THIRD-PARTY-NOTICES.md](LICENSES/THIRD-PARTY-NOTICES.md)，
应用内「关于」页亦保留上游版权与开源组件声明。

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
