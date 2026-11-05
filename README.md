<!-- prettier-ignore -->
<div align="center">

<img src="./AppScope/resources/base/media/app_icon.png" alt="LiteVideo" height="96" />

# LiteVideo

**YourPipe 的自用改进 fork · YouTube client for HarmonyOS / OpenHarmony**

[![Fork of](https://img.shields.io/badge/fork%20of-Ember5843%2FYourPipe-blue?style=flat-square)](https://github.com/Ember5843/YourPipe)
[![License](https://img.shields.io/badge/license-GPL--3.0-yellow?style=flat-square)](LICENSE)
[![Player](https://img.shields.io/badge/player-MPV-brightgreen?style=flat-square)](https://github.com/mpv-player/mpv)

> Unofficial client. **Not affiliated with YouTube or Google.**
> 个人自用版本，不提供上架、不支持、不承诺更新。

</div>

---

## 这个仓库是什么

**LiteVideo** 是 [**YourPipe**](https://github.com/Ember5843/YourPipe)（作者 Talon，`Ember5843/YourPipe`）的
**fork**，从上游 `v0.7.0`（commit `c3d985bb`，2026-10-22）分出来，在此之上做了**自己每天用**的改动。

- 上游是原始作品，绝大部分功能（播放器、抽取器、鉴权、下载、实验性功能等）都来自上游。
- 本仓库只包含**自用改进**，改动清单见下面第二节。
- 许可证不变：**GNU GPL v3.0**，全文见 [LICENSE](LICENSE)。上游授予你的权利同样直接适用于你，
  包括复制、修改、再分发、以及商用。
- 本 fork 的修改自 **2026-11-05** 起记录在此仓库的提交历史里。

| | |
|---|---|
| **Package** | `com.github.da3456.litevideo` |
| **App label** | `LiteVideo` |
| **Version** | `1.0.23`（`versionCode 1000223`，版本号与上游 0.x 线**脱钩**） |
| **Upstream** | `com.talon.yourpipe` / `Ember5843/YourPipe` |
| **Target SDK** | `26.0.0`（min `6.1.0(23)`）· HarmonyOS · stage model |
| **Devices** | phone · tablet · 2in1 · tv · car |

包名与上游刻意不同 → 两个 APK/HAP 是**互不干扰的独立沙箱**，可以和原版 YourPipe 同时安装、同时登录不同账号。

---

## 相比上游改了什么

以下**是本 fork 的增量**，其余一切行为请以上游为准。

1. **独立身份**：包名 `com.github.da3456.litevideo`、应用名 `LiteVideo`、独立图标与图标配色（浅色白底 / 深色黑底），
   版本号从 `1.0.x` 起独立编号；「关于 / 检查更新 / 源码链接」全部指向本仓库。
2. **订阅两端同步**：关注 / 取消关注会**写回 YouTube 账号**（Innertube `subscription/subscribe`、`unsubscribe`），
   失败回滚本地并提示；登录后的订阅名单与云端**双向核对**（以云端为准裁剪本地，带 30s 宽限与 `fromCloud` 标记，
   离线订阅不会被误删）。上游原本只有本地订阅。
3. **取消订阅先确认**：30vp 的灰色小按钮一点就退订太容易误触，现在所有入口（卡片 / 频道页 / 播放详情页 /
   频道长按菜单）都会先弹确认框，按「确定」才真正移除并写回云端。
4. **首页卡片长按 = 底部半模态菜单**：上游的 220vp 浮层会把卡片顶得往上跳，改成满宽底部面板
   （内容多高面板多高、背景遮罩、下滑把手或点空白关闭）。顶部拖拽把手是**自绘**的 ——
   这个 SDK 的 `SheetType.BOTTOM` + 单个 `FIT_CONTENT` detent 下系统 `dragBar` 不渲染。
5. **信息流反馈走服务端**：「不感兴趣」「不推荐该频道」提交服务端下发的 `feedbackToken`，
   「保存到稍后观看」写账号的 `WL` 列表。顺带修了请求体形状：`FeedbackRequest` 的 token 是
   **repeated 字段 `feedbackTokens`**，上游用的**单数 `feedbackToken` 会被 proto3 静默丢掉** ——
   服务端回 200 但什么都不记。这里还做了 token 深度解析（网页端每张卡要穿 21 层才拿到 token）。
6. **收藏 UI 全删**：卡片右下角收藏按钮、长按菜单收藏项、播放列表卡片心形按钮都去掉，
   底部第 3 个页签改成 **Playlists**（`favorites` 存储、备份、清除数据接线保留）。
7. **首页按批供给**：一批 3 页 ≈ 60 条，取满后不再自动翻页，下拉刷新或**再点一次首页页签**开下一批；
   feed 内容**不做去重**（服务端推什么显示什么）。
8. **卡片显示向 YouTube 网页看齐**：相对时间压缩成「4h ago」样式、订阅按钮统一成圆形 pill、
   卡片信息行等高对齐等。
9. **去掉上游的社群与商店入口**：「关于」页原版的 QQ 群 / Telegram 群、更新页的 AppGallery 测试渠道
   都移除 —— 那些是原作者的渠道，留在这个 fork 里只会把用户引到别处。改成保留一行
   **「上游项目 YourPipe」**链接（署名与溯源）。

**没有改的**：播放内核（MPV + FFmpeg）、抽取器与鉴权、SABR/PoToken、代理链路、下载引擎、
DeArrow / SponsorBlock / AiSList、直播聊天、翻译服务 —— 全部是上游的实现，致谢见
[LICENSES/THIRD-PARTY-NOTICES.md](LICENSES/THIRD-PARTY-NOTICES.md) 与应用内「关于 → 开源项目」。

---

## 构建

需要 [DevEco Studio](https://developer.huawei.com/consumer/en/deveco-studio/) / HarmonyOS SDK **6.1.0(23)** 及以上的命令行工具链。

```bash
cp build-profile.template.json5 build-profile.json5   # 本机配置，仓库里刻意不提交
ohpm install --all
devecocli build                                      # 默认 debug 全产品构建
```

- `build-profile.json5` 是 git-ignored 的**本机文件**，签名材料不要提交进任何仓库
  （根目录 `.githooks/pre-commit` 会拦）。没有签名配置时产物是
  `entry/build/default/outputs/default/entry-default-unsigned.hap`，需要自行签名后侧载。
- 真实视频播放只在 **arm64-v8a** 设备上工作；`x86_64`（模拟器）走 `libmpv_napi` 的 UI stub。
- `libmpv.so.2` 与 FFmpeg 静态库是**外部构建好带进来的**，不由 Hvigor 生成，见
  [libmpv_napi/AGENTS.md](libmpv_napi/AGENTS.md) §4。

## 隐私与账号

- 没有任何遥测 / 统计上报；日志只在应用内本地留存（可在「设置 → 网络 → 应用日志」开关）。
- 登录完全走应用内的 WebView Cookie / 设备码 OAuth，凭证只存本机沙箱。
- 本 fork 不收集、不上传任何内容，也**不接管别人的账号凭证**。

## 风险说明（自用版）

- 非官方客户端、逆向 InnerTube 提取音视频流，这与 YouTube 服务条款冲突，账号有被风控的现实可能
  （表现为「我是机器人」验证、登录态失效）。这是所有第三方 YouTube 客户端的共有风险。
- 本仓库**不发布 Release、不上应用市场、不提供捐赠或收款入口**。如果你愿意支持这类工作，
  请直接支持上游 **YourPipe**，以及底层项目的维护者：**MPV**、**FFmpeg**、**NewPipe** / **PipePipe**。

## License

GPL-3.0。见 [LICENSE](LICENSE)。
第三方组件的许可与出处清单见 [LICENSES/THIRD-PARTY-NOTICES.md](LICENSES/THIRD-PARTY-NOTICES.md)。
上游与既有版权声明（含各文件里的 `© Huawei Device Co., Ltd.` 样板头）均**原样保留**。
