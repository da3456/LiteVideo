import { VideoItem } from 'youtube_core';
import { VideoMediaCard } from './VideoMediaCard';

/**
 * List-style video entry. Thin wrapper over VideoMediaCard.
 */
@Component
export struct VideoCard {
  @Prop video: VideoItem;
  @Prop enableOpen: boolean = true;
  @Prop typeLabel: ResourceStr = '';
  @Prop showAuthor: boolean = true;
  @Prop showViewCount: boolean = true;
  @Prop showLiveTag: boolean = true;
  /** 推荐性质信息流（首页）开启长按菜单的服务端反馈项。 */
  @Prop showFeedbackActions: boolean = false;
  onOpenVideo?: (video: VideoItem) => void;

  build() {
    VideoMediaCard({
      video: this.video,
      layoutMode: 'list',
      enableOpen: this.enableOpen,
      typeLabel: this.typeLabel,
      showAuthor: this.showAuthor,
      showViewCount: this.showViewCount,
      showLiveTag: this.showLiveTag,
      showFeedbackActions: this.showFeedbackActions,
      onOpenVideo: this.onOpenVideo
    })
  }
}
