import { OptionItem } from '../../common/components/OptionItem';
import { PlaybackSectionTitle } from '../../common/components/PlaybackSectionTitle';
import { SECTION_CARD_RADIUS } from '../../common/components/MediaCardTokens';
import { openExternalUrl } from '../../common/utils/ExternalLinkUtil';
import { AppLog } from '../../common/AppLog';

/** fork 作者（da3456）的爱发电主页。 */
const AFDIAN_MINE_URL = 'https://afdian.com/a/da3456';
/** 原版 YourPipe 作者（ember5843）的爱发电主页。 */
const AFDIAN_UPSTREAM_URL = 'https://ifdian.net/a/ember5843';

const logger = AppLog.getInstance('OptionsAfdianPage');

/**
 * 设置 → 通用 → 爱发电：两个赞助入口（本 fork 作者 / 原版作者），
 * 都只跳外部浏览器，App 内不做任何支付与账号关联。
 */
@Component
export struct OptionsAfdianPage {
  @StorageProp('themePrimaryColor') themePrimary: string = '#E53935';

  private openLink(url: string, name: string): void {
    logger.info(`afdian link requested name=${name}`);
    openExternalUrl(
      this.getUIContext(),
      url,
      name,
      $r('app.string.yt_about_link_unavailable'),
      $r('app.string.yt_about_link_failed')
    );
  }

  build() {
    List({ space: 6 }) {
      ListItem() {
        PlaybackSectionTitle({ title: $r('app.string.yt_option_afdian') })
      }
      .padding({ left: 0, right: 0 })

      ListItem() {
        Column({ space: 0 }) {
          OptionItem({
            icon: $r('sys.symbol.heart_fill'),
            iconColor: this.themePrimary,
            title: $r('app.string.yt_afdian_mine_title'),
            subtitle: $r('app.string.yt_afdian_mine_desc'),
            subtitleMaxLines: 3,
            transparentBackground: true,
            onClickAction: () => this.openLink(AFDIAN_MINE_URL, 'afdian')
          })
          this.LinkUrl(AFDIAN_MINE_URL)

          Divider().color($r('app.color.yourtube_divider')).margin({ left: 16, right: 16 })

          OptionItem({
            icon: $r('sys.symbol.star_fill'),
            iconColor: this.themePrimary,
            title: $r('app.string.yt_afdian_upstream_title'),
            subtitle: $r('app.string.yt_afdian_upstream_desc'),
            subtitleMaxLines: 3,
            transparentBackground: true,
            onClickAction: () => this.openLink(AFDIAN_UPSTREAM_URL, 'ifdian')
          })
          this.LinkUrl(AFDIAN_UPSTREAM_URL)
        }
        .width('100%')
        .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
        .borderRadius(SECTION_CARD_RADIUS)
        .clip(true)
      }
      .padding({ left: 0, right: 0 })

      ListItem() {
        Text($r('app.string.yt_afdian_note'))
          .fontSize(12)
          .fontColor($r('app.color.yourtube_text_hint'))
          .lineHeight(18)
          .width('100%')
          .padding({ left: 4, right: 4 })
      }
      .padding({ left: 16, right: 16, top: 6 })
      ListItem() {
        Column().height(24)
      }
    }
    .width('100%')
    .height('100%')
    .padding({ top: 4 })
  }

  @Builder
  LinkUrl(url: string) {
    Text(url)
      .fontSize(11)
      .fontColor($r('app.color.yourtube_text_quaternary'))
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 12 })
  }
}
