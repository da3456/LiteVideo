import { VideoItem } from 'youtube_core';
import { SearchChannelItem, SearchPlaylistItem } from 'youtube_core';
import { PlayQueueSourceHint } from '../features/player/PlayQueueManager';

export type CallbackFunc = Function;

export enum ActionHubEvent {
  EXIT_FULLSCREEN = 'exitFullScreen',
  EXIT_COMMENT_REPLIES = 'exitCommentReplies',
  IS_REPLIES_OPEN_CHANGE = 'isRepliesOpenChange',
}

export class ActionHub {
  openSearch: (initialQuery?: string) => void = () => {};
  /** 主页 Shorts 悬浮球入口：push 全屏 Shorts 页。 */
  openShorts: () => void = () => {};
  openVideo: (video: VideoItem, sourceHint?: PlayQueueSourceHint, audioOnly?: boolean) => void = () => {};
  openChannel: (channel: SearchChannelItem) => void = () => {};
  openChannelById: (channelId: string, channelName: string, channelAvatarUrl: string, channelHandle: string) => void = () => {};
  openPlaylist: (playlist: SearchPlaylistItem) => void = () => {};
  openSubscriptionFeed: () => void = () => {};
  closePage: () => void = () => {};
  addSubscription: (channel: SearchChannelItem) => void = () => {};
  removeSubscription: (channelId: string) => void = () => {};
  shareVideo: (video: VideoItem) => void = () => {};
  shareChannel: (channel: SearchChannelItem) => void = () => {};
  sharePlaylist: (playlist: SearchPlaylistItem) => void = () => {};

  /**
   * 卡片长按菜单「下载」入口：提取该视频的可下载流（extractChain 串行），
   * 成功且可下载时弹 DownloadDialog；直播/无流/提取失败走 toast。
   * 由 Index 实现（根组件托管弹窗 UIContext）。
   */
  downloadVideo: (video: VideoItem) => void = () => {};

  /**
   * 卡片长按菜单「保存到稍后观看」：写回账号的 Watch later（需登录，未登录提示）。
   * 由 Index 实现（弹窗/toast 与 FeedServiceProvider 都在根组件）。
   */
  saveToWatchLater: (video: VideoItem) => void = () => {};

  /**
   * 长按菜单里的服务端反馈项（网页的「不感兴趣 / 不推荐该频道」这一类）：
   * 把该条 feed 响应自带的 `feedbackEndpoint.token` 原样回传 Innertube `feedback`，
   * 成功后服务端不再推这条内容。token 由 `FeedFeedbackStore` 在解析 feed 时记下。
   */
  sendFeedFeedback: (video: VideoItem, token: string) => void = () => {};

  /** Save the current play queue as a local playlist. */
  saveCurrentQueueAsLocal: (name: string) => void = () => {};

  /** Delete a locally saved queue by id. */
  deleteLocalQueue: (id: string) => void = () => {};

  /** Create a new local playlist seeded with a single video. */
  createLocalQueueWithVideo: (name: string, video: VideoItem) => void = () => {};

  /** Add a single video to an existing local playlist (deduplicated by videoId). */
  addVideoToLocalQueue: (queueId: string, video: VideoItem) => void = () => {};

  /** Remove a single video from a local playlist by videoId. */
  removeVideoFromLocalQueue: (queueId: string, videoId: string) => void = () => {};

  /** Load a local queue into the play queue and start playing from the given video. */
  loadLocalQueue: (queueId: string, startVideoId?: string) => void = () => {};

  // 事件监听和触发方法
  private events: Map<string, Array<CallbackFunc>> = new Map();

  on(event: ActionHubEvent, callback: CallbackFunc): void {
    if (!this.events.has(event)) {
      this.events.set(event, []);
    }
    this.events.get(event)?.push(callback);
  }

  off(event: ActionHubEvent, callback?: CallbackFunc): void {
    if (!callback) {
      this.events.delete(event);
      return;
    }
    const callbacks = this.events.get(event);
    if (callbacks) {
      const index = callbacks.indexOf(callback);
      if (index !== -1) {
        callbacks.splice(index, 1);
      }
    }
  }

  emit(event: ActionHubEvent, ...args: Object[]): void {
    const callbacks = this.events.get(event);
    if (callbacks) {
      callbacks.forEach(callback => {
        callback(...args);
      });
    }
  }
}
