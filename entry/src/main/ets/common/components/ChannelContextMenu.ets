import { Callback } from '@ohos.base';
import { LengthMetrics, SymbolGlyphModifier } from '@kit.ArkUI';
import { SearchChannelItem } from 'youtube_core';
import { ActionHub } from '../ActionHub';
import { SubscriptionUser } from '../SubscriptionModel';
import { UIConfig } from '../AppState';
import { customAnimationUtil } from '../AnimationUtil';
import { MEDIA_CARD_RADIUS } from './MediaCardTokens';

interface ChannelMenuItem {
  symbolStartIcon?: SymbolGlyphModifier;
  content: ResourceStr;
  callback: Callback<void>;
}

const SYMBOL_FONT_SIZE: number = 16;
const MENU_WIDTH_VP: number = 220;

/**
 * 频道专属长按菜单（打开频道 / 订阅·取消订阅 / 分享频道）。
 *
 * 视频卡长按弹的是视频菜单，长按**频道那一条**（作者行、频道卡头像）要只看频道相关的，
 * 所以把频道菜单从 ChannelCard 里抽出来共用：作者行只有名字，频道卡还能带统计与简介
 * （metaText / description 传空即不渲染）。
 */
@Component
export struct ChannelContextMenu {
  @Prop channelId: string = '';
  @Prop channelName: string = '';
  @Prop avatarUrl: string = '';
  @Prop channelHandle: string = '';
  /** 已拼好的统计行（"1.2M subscribers · 186 videos"），空则不显示。 */
  @Prop metaText: string = '';
  /** 简介，空则不显示。 */
  @Prop description: string = '';
  @StorageLink('subscriptions') subscriptions: SubscriptionUser[] = [];
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig();
  @Consume('actionHub') actionHub: ActionHub = new ActionHub();

  private getId(): string {
    return (this.channelId || '').trim();
  }

  private isSubscribed(): boolean {
    const channelId = this.getId();
    if (channelId.length === 0) {
      return false;
    }
    return this.subscriptions.some((item: SubscriptionUser) => item.channelId === channelId);
  }

  /** 订阅/分享需要完整的 SearchChannelItem；视频卡只给了头像/句柄，这里现拼。 */
  private buildChannel(): SearchChannelItem {
    return new SearchChannelItem(0, this.getId(), this.channelName || '', '', '',
      this.avatarUrl || '', '', '#CCCCCC', this.channelHandle || '');
  }

  private getItems(): ChannelMenuItem[] {
    const items: ChannelMenuItem[] = [];
    const channelId = this.getId();
    if (channelId.length > 0) {
      items.push({
        symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.person_crop_circle_fill'))
          .fontSize(SYMBOL_FONT_SIZE)
          .fontColor([$r('sys.color.font_primary')]),
        content: $r('app.string.yt_action_open_channel'),
        callback: () => {
          this.actionHub.openChannelById(channelId, this.channelName || '', this.avatarUrl || '',
            this.channelHandle || '');
        }
      });
    }
    items.push(this.isSubscribed()
      ? {
        symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.minus_circle'))
          .fontSize(SYMBOL_FONT_SIZE)
          .fontColor([$r('sys.color.font_primary')]),
        content: $r('app.string.yt_action_unsubscribe'),
        callback: () => {
          if (channelId.length > 0) {
            this.actionHub.removeSubscription(channelId);
          }
        }
      }
      : {
        symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.plus_circle'))
          .fontSize(SYMBOL_FONT_SIZE)
          .fontColor([$r('sys.color.font_primary')]),
        content: $r('app.string.yt_action_subscribe'),
        callback: () => {
          this.actionHub.addSubscription(this.buildChannel());
        }
      });
    items.push({
      symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.share'))
        .fontSize(SYMBOL_FONT_SIZE)
        .fontColor([$r('sys.color.font_primary')]),
      content: $r('app.string.yt_action_share'),
      callback: () => {
        this.actionHub.shareChannel(this.buildChannel());
      }
    });
    return items;
  }

  build() {
    Scroll() {
      Column() {
        if (this.channelName.length > 0 || this.metaText.length > 0 || this.description.length > 0) {
          Column() {
            Text(this.channelName || $r('app.string.yt_label_unknown'))
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.yourtube_text_primary'))
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')

            if (this.metaText.length > 0) {
              Text(this.metaText)
                .fontSize(12)
                .fontColor($r('app.color.yourtube_text_quaternary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
                .margin({ top: 4 })
            }

            if (this.description.length > 0) {
              Text(this.description)
                .fontSize(12)
                .fontColor($r('app.color.yourtube_text_hint'))
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
                .margin({ top: 2 })
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ left: 12, right: 12, top: 8, bottom: 8 })

          Divider()
            .strokeWidth(0.5)
            .color($r('sys.color.comp_divider'))
        }

        Menu() {
          ForEach(this.getItems(), (item: ChannelMenuItem) => {
            MenuItem({
              symbolStartIcon: item.symbolStartIcon,
              content: item.content
            })
              .clickEffect(customAnimationUtil.isClickEffect(this.uiConfig))
              .contentFontColor($r('sys.color.font_primary'))
              .onClick(() => {
                item.callback();
              });
          });
        }
        .menuItemDivider({ strokeWidth: LengthMetrics.vp(0.5), color: $r('sys.color.comp_divider') })
        .width('100%')
        .height('auto')
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
