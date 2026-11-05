import { Callback } from '@ohos.base';
import { LengthMetrics, SymbolGlyphModifier } from '@kit.ArkUI';
import { VideoItem } from 'youtube_core';
import { ActionHub } from '../ActionHub';
import { AppLog } from '../AppLog';
import { FeedFeedbackEntry, FeedFeedbackStore } from '../FeedFeedbackStore';
import { customAnimationUtil } from '../AnimationUtil';
import { UIConfig } from '../AppState';
import { MEDIA_CARD_RADIUS } from './MediaCardTokens';

const SYMBOL_FONT_SIZE: number = 16;
const logger = AppLog.getInstance('VideoMenu');
/** 菜单宽度统一 220vp（VideoMediaCard 确立的标准；原 180vp 的自定义菜单均已废弃）。 */
const MENU_WIDTH_VP: number = 220;
/** 底部半模态的行高：比浮层 MenuItem 略高，保证满宽下仍可单手点准。 */
const SHEET_ROW_HEIGHT_VP: number = 48;
/** 自绘拖拽把手：36x5vp 的圆角胶囊，压在面板顶部留白里。 */
const SHEET_HANDLE_WIDTH_VP: number = 36;
const SHEET_HANDLE_HEIGHT_VP: number = 5;
const SHEET_HANDLE_OPACITY: number = 0.55;
/** 把手往下拽多少 vp 判定为「关闭面板」。 */
const SHEET_HANDLE_DISMISS_VP: number = 40;

/** 表面特有菜单项（删除记录 / 从队列移除等），追加在标准项之后。 */
export interface VideoMenuExtraItem {
  symbolStartIcon?: SymbolGlyphModifier;
  /** 底部半模态用裸 Resource 画图标（SymbolGlyphModifier 只能喂 MenuItem）。 */
  sheetIcon?: Resource;
  content: ResourceStr;
  contentColor?: ResourceColor;
  callback: Callback<void>;
}

/**
 * 视频条目长按上下文菜单的统一实现：信息区 + 标准项（查看作者 /
 * 纯音频播放 / 下载 / 分享）+ 表面特有项（extraItems）。
 * 统一的是容器与范式（220vp、信息区、divider、preview 动画由宿主的
 * bindContextMenu 选项给）；项集合按表面语义用 show* 开关裁剪——例如
 * 播放队列关 showAudioOnly（点击即队列内切换，纯音频会丢队列上下文），
 * 历史页的播放列表条目整组关闭视频项。
 */
@Component
export struct VideoItemContextMenu {
  @Prop video: VideoItem;
  @Prop showAudioOnly: boolean = true;
  @Prop showDownload: boolean = true;
  @Prop showShare: boolean = true;
  /** 「保存到稍后观看」：本地导入/下载物没有联机列表语义，宿主传 false。 */
  @Prop showWatchLater: boolean = true;
  /** 服务端反馈项（不感兴趣 / 不推荐该频道）：只有推荐性质的信息流（首页）开，默认关。 */
  @Prop showFeedbackActions: boolean = false;
  /** 信息区开关（无视频语义的条目，如历史页的播放列表记录，可关闭）。 */
  @Prop showInfo: boolean = true;
  /**
   * 呈现方式：false = bindContextMenu 浮层（220vp），true = bindSheet 底部半模态
   * （满宽、由宿主给 dragBar/模糊背景）。首页卡片长按用后者——浮层会把卡片顶得往上跳。
   */
  @Prop asSheet: boolean = false;
  /** 半模态下点选项后收起面板；浮层由系统自动关闭，宿主不传即可。 */
  onClose?: Callback<void>;
  /** bindContextMenu 的菜单内容树与宿主同树，@Consume 可正常解析。 */
  @Consume('actionHub') actionHub: ActionHub = new ActionHub();
  extraItems: VideoMenuExtraItem[] = [];
  /** 同一条视频只记一次「菜单里能拿到几个服务端反馈项」，避免 ForEach 重算刷屏。 */
  private lastFeedbackLoggedCount: number = -1;
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig();
  @StorageProp('themePrimaryColor') themePrimary: string = '#E53935';

  private getVideoId(): string {
    return (this.video.videoId || '').trim();
  }

  /** 播放数展示：精确文本（accessibilityLabel / RSS）优先，其次缩写文本。 */
  private getDisplayViewCount(): string {
    if (this.video.viewCountExact && this.video.viewCountExact.length > 0) {
      return this.video.viewCountExact;
    }
    return this.video.viewCount || '';
  }

  /** 发布时间（有则非空）。仅在长按菜单信息区展示。 */
  private getPublishTimeText(): string {
    return this.video.publishedTimeText || '';
  }

  /** 信息区是否有可显示内容。 */
  private hasContextMenuInfo(): boolean {
    return (!!this.video.title && this.video.title.length > 0)
      || (!!this.video.author && this.video.author.length > 0)
      || this.getDisplayViewCount().length > 0
      || this.getPublishTimeText().length > 0
      || (!!this.video.durationText && this.video.durationText.length > 0)
      || this.getVideoId().length > 0;
  }

  private hasTypeBadges(): boolean {
    return this.video.isLive || this.video.isPremium || this.video.requiresMembership;
  }

  private logFeedbackAvailability(count: number): void {
    if (this.lastFeedbackLoggedCount === count) {
      return;
    }
    this.lastFeedbackLoggedCount = count;
    logger.info(`[FeedFeedback] stage=menu_open videoId=${this.getVideoId()} entries=${count}`);
  }

  /** 标准菜单项：浮层用 SymbolGlyphModifier，半模态用同一个 Resource 自己画 SymbolGlyph。 */
  private menuItem(icon: Resource, label: ResourceStr, callback: Callback<void>): VideoMenuExtraItem {
    const item: VideoMenuExtraItem = {
      symbolStartIcon: new SymbolGlyphModifier(icon)
        .fontSize(SYMBOL_FONT_SIZE)
        .fontColor([$r('sys.color.font_primary')]),
      sheetIcon: icon,
      content: label,
      callback: callback
    };
    return item;
  }

  private getMenuItems(): VideoMenuExtraItem[] {
    const items: VideoMenuExtraItem[] = [];
    const channelId = (this.video.channelId || '').trim();
    if (channelId.length > 0) {
      items.push(this.menuItem($r('sys.symbol.person_crop_circle_fill'),
        $r('app.string.yt_action_view_author'), () => {
          this.actionHub.openChannelById(
            channelId,
            this.video.author || '',
            this.video.channelAvatarUrl || '',
            this.video.channelHandle || ''
          );
        }));
    }
    if (this.showAudioOnly) {
      items.push(this.menuItem($r('sys.symbol.earphone'),
        $r('app.string.yt_action_audio_only_play'), () => {
          this.actionHub.openVideo(this.video, undefined, true);
        }));
    }
    if (this.showDownload) {
      items.push(this.menuItem($r('sys.symbol.arrowshape_down_to_line_fill'),
        $r('app.string.yt_action_download'), () => {
          this.actionHub.downloadVideo(this.video);
        }));
    }
    if (this.showShare) {
      items.push(this.menuItem($r('sys.symbol.share'),
        $r('app.string.yt_action_share'), () => {
          this.actionHub.shareVideo(this.video);
        }));
    }
    // 稍后观看只对联机视频有意义：本地导入/下载物没有 videoId（或不该写账号列表）。
    if (this.showWatchLater && this.getVideoId().length > 0
      && (this.video.localMediaPath || '').length === 0) {
      items.push(this.menuItem($r('sys.symbol.clock'),
        $r('app.string.yt_action_save_to_watch_later'), () => {
          this.actionHub.saveToWatchLater(this.video);
        }));
    }
    // 服务端反馈项：文案和 token 都来自这条内容在 feed 响应里自带的菜单
    // （`FeedFeedbackStore` 解析时记下）。没有 token 就不显示——本地屏蔽不算。
    if (this.showFeedbackActions) {
      const entries: FeedFeedbackEntry[] = FeedFeedbackStore.entriesFor(this.getVideoId());
      this.logFeedbackAvailability(entries.length);
      for (let i = 0; i < entries.length; i++) {
        const entry: FeedFeedbackEntry = entries[i];
        if (entry.token.length === 0) {
          continue;
        }
        // 服务端没带文案时（结构异常）才用固定兜底标签，顺序不能保证语义，仅避免整项空白。
        const label: ResourceStr = entry.label.length > 0
          ? entry.label
          : (i === 0 ? $r('app.string.yt_action_not_interested') : $r('app.string.yt_action_dont_recommend_channel'));
        items.push(this.menuItem(i === 0 ? $r('sys.symbol.eye_slash') : $r('sys.symbol.hand_thumbsdown'),
          label, () => {
            this.actionHub.sendFeedFeedback(this.video, entry.token);
          }));
      }
    }
    for (const extra of this.extraItems) {
      items.push(extra);
    }
    return items;
  }

  private runItem(item: VideoMenuExtraItem): void {
    item.callback();
    if (this.asSheet) {
      this.closeSheet();
    }
  }

  /** 信息区小标记 chip（直播/付费/会员）。 */
  @Builder
  InfoBadge(label: Resource) {
    Text(label)
      .fontSize(10)
      .fontColor(this.themePrimary)
      .padding({ left: 6, right: 6, top: 1, bottom: 1 })
      .border({ width: 1, color: this.themePrimary, radius: 4 })
  }

  /** 条目信息区（不可点击）：标题/作者(+认证)/播放数(精确优先)/发布时间/时长/视频ID/标记。 */
  @Builder
  InfoBlock() {
    if (this.showInfo && this.hasContextMenuInfo()) {
          Column() {
            Text(this.video.title)
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.yourtube_text_primary'))
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')

            if (this.video.author && this.video.author.length > 0) {
              Row({ space: 4 }) {
                Text(this.video.author)
                  .fontSize(12)
                  .fontColor($r('app.color.yourtube_text_quaternary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .flexShrink(1)
                if (this.video.uploaderVerified) {
                  SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
                    .fontSize(12)
                    .fontColor([$r('app.color.yourtube_text_quaternary')])
                }
              }
              .width('100%')
              .margin({ top: 4 })
            }

            if (this.getDisplayViewCount().length > 0) {
              Text(this.getDisplayViewCount())
                .fontSize(12)
                .fontColor($r('app.color.yourtube_text_hint'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
                .margin({ top: 2 })
            }
            if (this.getPublishTimeText().length > 0) {
              Text(this.getPublishTimeText())
                .fontSize(12)
                .fontColor($r('app.color.yourtube_text_hint'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
                .margin({ top: 2 })
            }
            if (this.video.durationText && this.video.durationText.length > 0) {
              Text(this.video.durationText)
                .fontSize(12)
                .fontColor($r('app.color.yourtube_text_hint'))
                .maxLines(1)
                .width('100%')
                .margin({ top: 2 })
            }
            if (this.getVideoId().length > 0) {
              Text(`ID: ${this.getVideoId()}`)
                .fontSize(11)
                .fontColor($r('app.color.yourtube_text_hint'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
                .margin({ top: 2 })
            }

            if (this.hasTypeBadges()) {
              Row({ space: 6 }) {
                if (this.video.isLive) {
                  this.InfoBadge($r('app.string.yt_label_live'))
                }
                if (this.video.isPremium) {
                  this.InfoBadge($r('app.string.yt_label_premium'))
                }
                if (this.video.requiresMembership) {
                  this.InfoBadge($r('app.string.yt_label_members_only'))
                }
              }
              .width('100%')
              .margin({ top: 6 })
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ left: 12, right: 12, top: 8, bottom: 8 })

          Divider()
            .strokeWidth(0.5)
            .color($r('sys.color.comp_divider'))
    }
  }

  /** 浮层菜单项（bindContextMenu 宿主）。 */
  @Builder
  PopupRows() {
    Menu() {
      ForEach(this.getMenuItems(), (item: VideoMenuExtraItem) => {
        MenuItem({
          symbolStartIcon: item.symbolStartIcon,
          content: item.content
        })
          .clickEffect(customAnimationUtil.isClickEffect(this.uiConfig))
          .contentFontColor(item.contentColor ?? $r('sys.color.font_primary'))
          .onClick(() => {
            this.runItem(item);
          });
      });
    }
    .menuItemDivider({ strokeWidth: LengthMetrics.vp(0.5), color: $r('sys.color.comp_divider') })
    .width('100%')
    .height('auto')
  }

  /** 半模态菜单项：满宽一行一项（图标 + 文案），点完先执行再收起面板。 */
  @Builder
  SheetRows() {
    Column() {
      ForEach(this.getMenuItems(), (item: VideoMenuExtraItem) => {
        Row({ space: 14 }) {
          if (item.sheetIcon !== undefined) {
            SymbolGlyph(item.sheetIcon)
              .fontSize(SYMBOL_FONT_SIZE)
              .fontColor([$r('sys.color.font_primary')])
          }
          Text(item.content)
            .fontSize(15)
            .fontColor(item.contentColor ?? $r('sys.color.font_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        }
        .width('100%')
        .height(SHEET_ROW_HEIGHT_VP)
        .padding({ left: 20, right: 20 })
        .clickEffect(customAnimationUtil.isClickEffect(this.uiConfig))
        .onClick(() => {
          this.runItem(item);
        })
      })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 4, bottom: 12 })
  }

  /**
   * 顶部拖拽条：系统 `dragBar` 在这个 SDK 的 BOTTOM 半模态上不出现，所以自己画
   * 一条（宿主已把 `dragBar` 关掉，避免出现两条）。上下留白是刻意的——紧贴内容
   * 看着像分割线，不像可以拽的把手。往下拽超过阈值就收起面板（否则这条横只是装饰）。
   */
  @Builder
  SheetHandleBar() {
    Row() {
      Column()
        .width(SHEET_HANDLE_WIDTH_VP)
        .height(SHEET_HANDLE_HEIGHT_VP)
        .borderRadius(SHEET_HANDLE_HEIGHT_VP / 2)
        .backgroundColor($r('app.color.yourtube_text_hint'))
        .opacity(SHEET_HANDLE_OPACITY)
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ top: 12, bottom: 8 })
    .gesture(PanGesture({ direction: PanDirection.Vertical, distance: 8 })
      .onActionEnd((event: GestureEvent) => {
        if (event.offsetY > SHEET_HANDLE_DISMISS_VP) {
          this.closeSheet();
        }
      }))
  }

  private closeSheet(): void {
    if (this.onClose) {
      this.onClose();
    }
  }

  build() {
    if (this.asSheet) {
      Scroll() {
        Column() {
          this.SheetHandleBar()
          this.InfoBlock()
          this.SheetRows()
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ bottom: 14 })
        // 半模态的底色由内容自己画：这个 SDK 的 SheetOptions 已经没有 backgroundColor。
        .backgroundColor($r('app.color.yourtube_bg_surface'))
      }
      .width('100%')
      .nestedScroll({ scrollForward: NestedScrollMode.SELF_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
      .edgeEffect(EdgeEffect.Spring)
    } else {
      Scroll() {
        Column() {
          this.InfoBlock()
          this.PopupRows()
        }
        .backgroundColor($r('app.color.yourtube_bg_surface'))
        .borderRadius(MEDIA_CARD_RADIUS)
        .clip(true)
        .width(MENU_WIDTH_VP)
      }
      .nestedScroll({ scrollForward: NestedScrollMode.SELF_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
      .edgeEffect(EdgeEffect.Spring)
    }
  }
}
