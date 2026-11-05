import { ActionHub } from '../../../common/ActionHub';
import { customAnimationUtil } from '../../../common/AnimationUtil';
import { customVibrator } from '../../../common/VibratorUtil';
import { SearchChannelItem } from 'youtube_core';
import { SubscriptionUser } from '../../../common/SubscriptionModel';
import { UIConfig } from '../../../common/AppState';
import { ChannelContextMenu } from '../../../common/components/ChannelContextMenu';
import {
  MEDIA_CARD_RADIUS,
  MEDIA_CARD_SHADOW_OFFSET_Y,
  MEDIA_CARD_SHADOW_RADIUS,
  MEDIA_META_SIZE,
  MEDIA_TITLE_LINE_HEIGHT,
  MEDIA_TITLE_SIZE
} from '../../../common/components/MediaCardTokens';

@Component
export struct ChannelCard {
  @StorageProp('themePrimaryColor') themePrimary: string = '#E53935';
  @Prop channel: SearchChannelItem;
  @Prop typeLabel: ResourceStr = $r('app.string.yt_label_user');
  @Prop showDescription: boolean = true;
  @StorageLink('subscriptions') subscriptions: SubscriptionUser[] = [];
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig();
  @Consume('actionHub') actionHub: ActionHub = new ActionHub();
  @State isShowContextMenu: boolean = false;

  private getChannelId(): string {
    return (this.channel.channelId || '').trim();
  }

  private isSubscribed(): boolean {
    const channelId = this.getChannelId();
    if (!channelId) {
      return false;
    }
    return this.subscriptions.some((item: SubscriptionUser) => item.channelId === channelId);
  }

  /**
   * 统计行合成一条文本：两个 Text 并排（Row 不换行）时，后面的「77k videos」
   * 会被整段裁掉且不出省略号，合成一条才能按剩余宽度优雅截断。
   */
  private getMetaText(): string {
    const parts: string[] = [];
    if (this.channel.subscriberText && this.channel.subscriberText.length > 0) {
      parts.push(this.channel.subscriberText);
    }
    if (this.channel.videoCountText && this.channel.videoCountText.length > 0) {
      parts.push(this.channel.videoCountText);
    }
    return parts.join(' · ');
  }

  private handleAction(): void {
    const channelId = this.getChannelId();
    if (!channelId) {
      return;
    }
    if (this.isSubscribed()) {
      this.actionHub.removeSubscription(channelId);
      return;
    }
    this.actionHub.addSubscription(this.channel);
  }

  @Builder
  contextMenuBuilder() {
    // 频道菜单统一走共享组件（打开频道 / 订阅·取消订阅 / 分享频道 + 信息区）。
    ChannelContextMenu({
      channelId: this.getChannelId(),
      channelName: this.channel.name || '',
      avatarUrl: this.channel.avatarUrl || '',
      channelHandle: this.channel.handle || '',
      metaText: this.getMetaText(),
      description: this.showDescription ? (this.channel.description || '') : ''
    })
  }

  build() {
    Row() {
      Stack({ alignContent: Alignment.BottomEnd }) {
        if (this.channel.avatarUrl && this.channel.avatarUrl.length > 0) {
          Image(this.channel.avatarUrl)
            .width(56)
            .height(56)
            .objectFit(ImageFit.Cover)
            .borderRadius(28)
            .clip(true)
            // ArkUI 的 Image 默认可拖拽，长按会被系统拖拽手势吃掉 → 头像这块按不出菜单。
            .draggable(false)
            .backgroundColor(this.channel.thumbnailColor || $r('app.color.yourtube_icon_hint'));
        } else {
          Circle()
            .width(56)
            .height(56)
            .fill(this.channel.thumbnailColor || $r('app.color.yourtube_icon_hint'));
        }

        if (typeof this.typeLabel === 'string' && this.typeLabel.length > 0) {
          Text(this.typeLabel)
            .fontSize(8)
            .fontColor($r('app.color.yourtube_text_inverse'))
            .backgroundColor($r('app.color.yourtube_bg_tag'))
            .padding({ left: 4, right: 4, top: 2, bottom: 2 })
            .borderRadius(8);
        }
      }
      .width(56)
      .height(56)
      .margin({ right: 12, top: 2 });

      Column() {
        Text(this.channel.name || $r('app.string.yt_label_unknown'))
          .fontSize(MEDIA_TITLE_SIZE)
          .fontColor($r('app.color.yourtube_text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .lineHeight(MEDIA_TITLE_LINE_HEIGHT)
          .fontWeight(FontWeight.Medium)
          .margin({ bottom: 2 });

        if (this.getMetaText().length > 0) {
          Text(this.getMetaText())
            .fontSize(MEDIA_META_SIZE)
            .fontColor($r('app.color.yourtube_text_quaternary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%');
        }

        if (this.showDescription && this.channel.description && this.channel.description.length > 0) {
          Text(this.channel.description)
            .fontSize(10)
            .fontColor($r('app.color.yourtube_text_tertiary'))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .lineHeight(14)
            .margin({ top: 4 });
        }
      }
      .layoutWeight(1)
      .constraintSize({ minHeight: 56 })
      .alignItems(HorizontalAlign.Start);

      Column() {
        // 全应用统一：未订阅 = 红色笑脸加号，已订阅 = 灰色对勾。文字按钮会在窄面板
        // 里挤掉统计行，图标钮 + accessibilityText 两边都不占宽度。
        Button() {
          SymbolGlyph(this.isSubscribed() ? $r('sys.symbol.checkmark') : $r('sys.symbol.face_smiling_plus'))
            .fontSize(this.isSubscribed() ? 15 : 18)
            .fontColor([this.isSubscribed()
              ? $r('app.color.yourtube_text_secondary')
              : $r('app.color.yourtube_text_inverse')])
        }
        .width(30)
        .height(30)
        .padding(0)
        .borderRadius(15)
        .backgroundColor(this.isSubscribed() ? $r('app.color.yourtube_button_disabled') : this.themePrimary)
        .accessibilityText(this.isSubscribed()
          ? $r('app.string.yt_action_unsubscribe')
          : $r('app.string.yt_action_subscribe'))
        .clickEffect(customAnimationUtil.isClickEffect(this.uiConfig))
        .onClick(() => {
          this.handleAction();
        });
      }
      .height(56)
      .justifyContent(FlexAlign.Center)
      .margin({ left: 8 });
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
    .bindContextMenu(this.isShowContextMenu, this.contextMenuBuilder, {
      preview: MenuPreviewMode.IMAGE,
      previewAnimationOptions: { scale: [1.0, 1.1] },
      placement: Placement.BottomRight,
      aboutToAppear: () => {
        if (this.uiConfig.isVibrate) {
          customVibrator.vibratorTriggerOfHapticClockTimer();
        }
      },
      aboutToDisappear: () => {
        this.isShowContextMenu = false;
      }
    })
    .onClick(() => {
      const channelId = this.getChannelId();
      if (channelId) {
        this.actionHub.openChannelById(channelId, this.channel.name || '', this.channel.avatarUrl || '', this.channel.handle || '');
      } else {
        this.actionHub.openChannel(this.channel);
      }
    })
    .gesture(LongPressGesture()
      .onAction(() => {
        this.isShowContextMenu = true;
      }));
  }
}
