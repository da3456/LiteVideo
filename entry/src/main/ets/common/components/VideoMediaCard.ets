import { ActionHub } from '../../common/ActionHub';
import { VideoItem } from 'youtube_core';
import { customAnimationUtil } from '../../common/AnimationUtil';
import { customVibrator } from '../../common/VibratorUtil';
import { UIConfig } from '../AppState';
import { MediaThumb } from './MediaThumb';
import { VideoItemContextMenu } from './VideoItemContextMenu';
import { resolveResourceStr } from '../utils/ResourceStrUtil';
import { compactPublishTime } from '../utils/PublishTimeFormat';
import {
  MEDIA_CARD_RADIUS,
  MEDIA_CARD_SHADOW_OFFSET_Y,
  MEDIA_CARD_SHADOW_RADIUS,
  MEDIA_GRID_TITLE_BLOCK_HEIGHT,
  MEDIA_LIST_THUMB_GAP,
  MEDIA_LIST_THUMB_HEIGHT,
  MEDIA_LIST_THUMB_WIDTH,
  MEDIA_META_LINE_HEIGHT,
  MEDIA_META_SIZE,
  MEDIA_THUMB_RADIUS,
  MEDIA_TITLE_LINE_HEIGHT,
  MEDIA_TITLE_SIZE
} from './MediaCardTokens';

/**
 * Shared video content shell.
 * layoutMode: 'list' = horizontal row (meta stacked: title / author / viewCount),
 * 'grid' = vertical card (title + 作者行 + 统计行：播放数 · 发布时间)。
 */
@Component
export struct VideoMediaCard {
  @Prop video: VideoItem;
  /** 'list' | 'grid' */
  @Prop layoutMode: string = 'list';
  @Prop enableOpen: boolean = true;
  @Prop typeLabel: ResourceStr = '';
  @Prop showAuthor: boolean = true;
  @Prop showViewCount: boolean = true;
  @Prop showLiveTag: boolean = true;
  /** 推荐性质信息流（首页）开启「不感兴趣 / 不推荐该频道」服务端反馈项。 */
  @Prop showFeedbackActions: boolean = false;
  onOpenVideo?: (video: VideoItem) => void;
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig();
  @Consume('actionHub') actionHub: ActionHub = new ActionHub();
  /**
   * 长按整卡（含缩略图与作者行）= 底部半模态菜单。
   * 作者行**不再挂自己的长按**：曾经给它绑过频道菜单，结果和整卡的视频菜单
   * 在同一个卡片上打架（用户明确要求去掉），现在长按作者行直接冒泡到整卡。
   */
  @State isShowMenuSheet: boolean = false;

  private isGrid(): boolean {
    return this.layoutMode === 'grid';
  }

  private getVideoId(): string {
    return (this.video.videoId || '').trim();
  }

  private getTypeLabelText(): string {
    // Resource 形式的标签（如搜索页传入的 $r）需解析成字符串，否则角标为空
    return resolveResourceStr(this.typeLabel);
  }

  /** AiSList 角标：block=红，warn=橙；未命中返回空串。 */
  private aiBadgeText(): string {
    if (this.video.aiListFlag.length === 0) {
      return '';
    }
    try {
      return getContext().resourceManager.getStringSync($r('app.string.yt_exp_ai_badge').id);
    } catch (_e) {
      return 'AI';
    }
  }

  private aiBadgeColor(): string {
    return this.video.aiListFlag === 'warn' ? '#F59E0B' : '#E53935';
  }

  private handleOpen(): void {
    if (!this.enableOpen) {
      return;
    }
    if (this.onOpenVideo) {
      this.onOpenVideo(this.video);
      return;
    }
    this.actionHub.openVideo(this.video);
  }

  @Builder
  menuSheetBuilder() {
    // 同一套条目集合（信息区 + 标准项 + 服务端反馈项），只是换成底部弹层排布。
    VideoItemContextMenu({
      video: this.video,
      showFeedbackActions: this.showFeedbackActions,
      asSheet: true,
      onClose: () => {
        this.isShowMenuSheet = false;
      }
    })
  }

  /** 长按呼出弹层（震动沿用原来 bindContextMenu.aboutToAppear 的手感）。 */
  private openMenuSheet(): void {
    if (this.uiConfig.isVibrate) {
      customVibrator.vibratorTriggerOfHapticClockTimer();
    }
    this.isShowMenuSheet = true;
  }

  /**
   * 非 16:9 缩略图（直播常见竖图/方图）在 Contain 盒子里会左右露出裸底色，
   * 跟同排卡片比就是"两边排列不一样"。这里跟推荐位 banner 同款：垫一层暗化
   * cover 副本填空隙。**只对直播开**——短视频维度条条都是竖图，全开等于每张
   * 卡片多解一次位图，下滑会变沉。
   */
  private needBackdropFill(): boolean {
    return this.video.isLive === true;
  }

  @Builder
  ThumbBlockGrid() {
    // 通栏图：自身不带圆角，由卡片根的 borderRadius+clip 裁出圆角
    MediaThumb({
      imageUrl: this.video.thumbnailUrl || '',
      placeholderColor: this.video.thumbnailColor || '',
      thumbId: 'thumb_' + this.video.id,
      fillParent: true,
      useAspectRatio: true,
      useCoverBackdrop: this.needBackdropFill(),
      borderRadiusVp: 0,
      showLive: this.showLiveTag,
      isLive: this.video.isLive,
      isPremium: this.video.isPremium,
      requiresMembership: this.video.requiresMembership,
      typeLabel: this.getTypeLabelText(),
      fallbackImageUrl: this.video.originalThumbnailUrl || '',
      cornerLabel: this.aiBadgeText(),
      cornerLabelColor: this.aiBadgeColor()
    })
  }

  @Builder
  ThumbBlockList() {
    MediaThumb({
      imageUrl: this.video.thumbnailUrl || '',
      placeholderColor: this.video.thumbnailColor || '',
      thumbId: 'thumb_' + this.video.id,
      widthVp: MEDIA_LIST_THUMB_WIDTH,
      heightVp: MEDIA_LIST_THUMB_HEIGHT,
      useCoverBackdrop: this.needBackdropFill(),
      borderRadiusVp: MEDIA_THUMB_RADIUS,
      showLive: this.showLiveTag,
      isLive: this.video.isLive,
      isPremium: this.video.isPremium,
      requiresMembership: this.video.requiresMembership,
      typeLabel: this.getTypeLabelText(),
      fallbackImageUrl: this.video.originalThumbnailUrl || '',
      cornerLabel: this.aiBadgeText(),
      cornerLabelColor: this.aiBadgeColor()
    })
      .margin({ right: MEDIA_LIST_THUMB_GAP })
  }

  /** Title / author / viewCount stacked — shared by list and grid. */
  @Builder
  MetaTextStack() {
    Column() {
      Text(this.video.title)
        .fontSize(MEDIA_TITLE_SIZE)
        .fontColor($r('app.color.yourtube_text_primary'))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .lineHeight(MEDIA_TITLE_LINE_HEIGHT)
        .fontWeight(FontWeight.Medium)
        .width('100%')
        .margin({ bottom: 2 })

      if (this.showAuthor && this.video.author && this.video.author.length > 0) {
        Text(this.video.author)
          .fontSize(MEDIA_META_SIZE)
          .fontColor($r('app.color.yourtube_text_quaternary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ bottom: 2 })
      }

      if (this.showViewCount && this.listMetaText().length > 0) {
        Text(this.listMetaText())
          .fontSize(MEDIA_META_SIZE)
          .fontColor($r('app.color.yourtube_text_hint'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  MetaBlockList() {
    // Fixed height matches thumb so the meta block aligns with the thumbnail.
    Column() {
      this.MetaTextStack()
    }
    .width('100%')
    .layoutWeight(1)
    .height(MEDIA_LIST_THUMB_HEIGHT)
    .alignItems(HorizontalAlign.Start)
    .justifyContent(FlexAlign.Start)
  }

  /** grid meta 行的作者段（showAuthor 关闭或缺失时为空）。 */
  private gridMetaAuthor(): string {
    return this.showAuthor && this.video.author ? this.video.author : '';
  }

  /** 卡片统一用网页端的紧凑相对时间（"4 hours ago" → "4h ago"）。 */
  private publishedTimeCompact(): string {
    return compactPublishTime(this.video.publishedTimeText || '');
  }

  /**
   * 列表模式第三行：播放量 · 发布时间。
   * 列表模式原先只显示播放量（网格模式才有日期兜底），这里补上发布时间。
   */
  private listMetaText(): string {
    const parts: string[] = [];
    if (this.video.viewCount && this.video.viewCount.length > 0) {
      parts.push(this.video.viewCount);
    }
    const published = this.publishedTimeCompact();
    if (published.length > 0) {
      parts.push(published);
    }
    return parts.join(' · ');
  }

  /**
   * grid 第二行统计文本：播放数 · 发布时间（缺项自动省略该段）。
   * 两者都没有时退化为时长，保证 compact 网格里不会出现空行。
   */
  private gridStatText(): string {
    const parts: string[] = [];
    if (this.showViewCount && this.video.viewCount && this.video.viewCount.length > 0) {
      parts.push(this.video.viewCount);
    }
    const published = this.publishedTimeCompact();
    if (published.length > 0) {
      parts.push(published);
    }
    if (parts.length === 0) {
      return this.video.durationText || '';
    }
    return parts.join(' · ');
  }

  @Builder
  MetaBlockGrid() {
    // 上下分布卡片的底部信息栏：标题(固定 2 行) / 作者行 / 统计行（播放数 · 发布时间）。
    //
    // **每一行都是固定高度**：Grid 按行对齐，一张卡矮一点，同一行另一张卡下面就
    // 空出一块，两列看起来高低不齐。所以短标题照样占满两行、缺作者/缺统计的行
    // 也保留高度（空文本）。行本身是否渲染仍由 `showAuthor` / `showViewCount`
    // 决定 —— 同一个信息流里这些开关是一致的，因此整屏卡片高度仍然相同。
    Column() {
      Text(this.video.title)
        .fontSize(MEDIA_TITLE_SIZE)
        .fontColor($r('app.color.yourtube_text_primary'))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .lineHeight(MEDIA_TITLE_LINE_HEIGHT)
        .fontWeight(FontWeight.Medium)
        .width('100%')
        .height(MEDIA_GRID_TITLE_BLOCK_HEIGHT)
        .margin({ bottom: 2 })

      if (this.showAuthor) {
        Text(this.gridMetaAuthor())
          .fontSize(MEDIA_META_SIZE)
          .fontColor($r('app.color.yourtube_text_quaternary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .height(MEDIA_META_LINE_HEIGHT)
          .margin({ bottom: 2 })
      }

      if (this.showViewCount) {
        Text(this.gridStatText())
          .fontSize(MEDIA_META_SIZE)
          .fontColor($r('app.color.yourtube_text_hint'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .height(MEDIA_META_LINE_HEIGHT)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 10, right: 10, top: 10, bottom: 8 })
  }

  build() {
    if (this.isGrid()) {
      Column() {
        this.ThumbBlockGrid()
        this.MetaBlockGrid()
      }
      .width('100%')
      .borderRadius(MEDIA_CARD_RADIUS)
      // clip 让顶部通栏图服从卡片圆角（ThumbBlockGrid 的图自身圆角已归零）
      .clip(true)
      .backgroundColor($r('app.color.yourtube_bg_surface'))
      .shadow({
        radius: MEDIA_CARD_SHADOW_RADIUS,
        color: $r('app.color.yourtube_shadow'),
        offsetX: 0,
        offsetY: MEDIA_CARD_SHADOW_OFFSET_Y
      })
      .clickEffect(customAnimationUtil.isClickEffect(this.uiConfig))
      .bindSheet($$this.isShowMenuSheet, this.menuSheetBuilder(), {
        detents: [SheetSize.FIT_CONTENT],
        preferType: SheetType.BOTTOM,
        // 系统 dragBar 在这个 SDK 的 BOTTOM 面板上不渲染，横条由 VideoItemContextMenu
        // 自绘（SheetHandleBar），这里显式关掉防止出现两条。
        dragBar: false,
        showClose: false,
        blurStyle: BlurStyle.COMPONENT_THICK
      })
      .onClick(() => {
        this.handleOpen();
      })
      .gesture(LongPressGesture()
        .onAction(() => {
          this.openMenuSheet();
        }))
    } else {
      Row() {
        this.ThumbBlockList()
        this.MetaBlockList()
      }
      .width('100%')
      .padding({ left: 10, right: 10, top: 8, bottom: 8 })
      .alignItems(VerticalAlign.Top)
      .borderRadius(MEDIA_CARD_RADIUS)
      .backgroundColor($r('app.color.yourtube_bg_surface'))
      .shadow({
        radius: MEDIA_CARD_SHADOW_RADIUS,
        color: $r('app.color.yourtube_shadow'),
        offsetX: 0,
        offsetY: MEDIA_CARD_SHADOW_OFFSET_Y
      })
      .clickEffect(customAnimationUtil.isClickEffect(this.uiConfig))
      .bindSheet($$this.isShowMenuSheet, this.menuSheetBuilder(), {
        detents: [SheetSize.FIT_CONTENT],
        preferType: SheetType.BOTTOM,
        // 系统 dragBar 在这个 SDK 的 BOTTOM 面板上不渲染，横条由 VideoItemContextMenu
        // 自绘（SheetHandleBar），这里显式关掉防止出现两条。
        dragBar: false,
        showClose: false,
        blurStyle: BlurStyle.COMPONENT_THICK
      })
      .onClick(() => {
        this.handleOpen();
      })
      .gesture(LongPressGesture()
        .onAction(() => {
          this.openMenuSheet();
        }))
    }
  }
}
