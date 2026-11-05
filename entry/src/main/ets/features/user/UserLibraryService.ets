import {
  addVideoToPlaylist,
  AuthSessionManager,
  ContentCountry,
  Localization,
  SearchPlaylistItem,
  VideoItem,
  fetchBrowseContinuation,
  fetchBrowsePage,
  fetchTvBrowseContinuation,
  fetchTvBrowsePage,
  postFeedFeedback,
  subscribeChannels,
  unsubscribeChannels
} from 'youtube_core';
import { util } from '@kit.ArkTS';
import { AppLog } from '../../common/AppLog';
import { SubscriptionUser } from '../../common/SubscriptionModel';
import { WatchHistoryItem } from '../../common/WatchHistoryStore';
import { ThumbnailPlaceholder } from '../../common/ThumbnailPlaceholder';
import {
  buildHomeKioskVideoItems,
  getHomeFeedItemsFromTabContent
} from '../home/utils/HomeFeedUtils';
import { buildTvBrowseVideoItems, getTvVisitorData } from '../home/utils/TvBrowseUtils';
import { getTextFromRuns } from '../home/utils/TextUtils';
import { getPlaylistContinuationToken } from '../home/utils/ContinuationUtils';
import {
  getLockupPlaylistCoverUrl,
  getLockupPlaylistId,
  getLockupTitle,
  getLockupUploaderName
} from '../home/utils/LockupViewModelParser';
import { getRendererThumbnailUrl } from '../home/utils/ThumbnailUtils';

const logger = AppLog.getInstance('UserLibraryService');

export interface UserVideoPageResult {
  items: Array<VideoItem>;
  nextPageToken: string | null;
  visitorData: string;
}

export interface UserPlaylistPageResult {
  items: Array<SearchPlaylistItem>;
  nextPageToken: string | null;
  visitorData: string;
}

export interface SubscribedChannelsSnapshot {
  channels: Array<SubscriptionUser>;
  /**
   * false = 这份云端名单不可当作全集（翻页没跑完、或只是兜底扫描）。
   * 调用方只有 complete 为真时才允许据此删除本地订阅。
   */
  complete: boolean;
}

interface ChannelScanResult {
  tokens: Array<string>;
  truncated: boolean;
}

/** FEchannels 续页抓取上限：再多就不是「差一页」而是账号异常，宁可标 incomplete。 */
const CHANNELS_MAX_PAGES: number = 6;

export class UserLibraryService {
  private localization: Localization;
  private contentCountry: ContentCountry;
  private readonly HISTORY_BROWSE_ID: string = 'FEhistory';
  private readonly SUBSCRIPTIONS_BROWSE_ID: string = 'FEsubscriptions';
  private readonly CHANNELS_BROWSE_ID: string = 'FEchannels';
  private readonly LIBRARY_BROWSE_ID: string = 'FElibrary';
  private readonly PLAYLISTS_BROWSE_ID: string = 'FEplaylist_aggregation';

  constructor(localization: Localization, contentCountry: ContentCountry) {
    this.localization = localization;
    this.contentCountry = contentCountry;
  }

  private requireSignedIn(): void {
    const session = AuthSessionManager.getInstance();
    if (!session || !session.hasAuthForUserData()) {
      throw new Error('Sign-in required');
    }
  }

  /** Prefer WEB cookie rail; OAuth-only uses TV browse. */
  private useTvRail(): boolean {
    const session = AuthSessionManager.getInstance();
    return session?.preferredUserDataRail() === 'tv';
  }

  async fetchWatchHistory(startId: number = 1): Promise<UserVideoPageResult> {
    this.requireSignedIn();
    return this.fetchAuthBrowse(this.HISTORY_BROWSE_ID, startId);
  }

  async fetchWatchHistoryNext(
    nextPageToken: string,
    visitorData: string,
    startId: number
  ): Promise<UserVideoPageResult> {
    this.requireSignedIn();
    return this.fetchAuthBrowseContinuation(nextPageToken, visitorData, startId);
  }

  async fetchSubscriptionsFeed(startId: number = 1): Promise<UserVideoPageResult> {
    this.requireSignedIn();
    return this.fetchAuthBrowse(this.SUBSCRIPTIONS_BROWSE_ID, startId);
  }

  async fetchSubscriptionsFeedNext(
    nextPageToken: string,
    visitorData: string,
    startId: number
  ): Promise<UserVideoPageResult> {
    this.requireSignedIn();
    return this.fetchAuthBrowseContinuation(nextPageToken, visitorData, startId);
  }

  async fetchLibrary(startId: number = 1): Promise<UserVideoPageResult> {
    this.requireSignedIn();
    return this.fetchAuthBrowse(this.LIBRARY_BROWSE_ID, startId);
  }

  /**
   * Account playlists (Watch later / Liked videos / created / saved).
   * FEplaylist_aggregation is the library playlists rail; both WEB and TV
   * rail responses are flattened by the same playlist-node scan.
   */
  async fetchSavedPlaylists(startId: number = 1): Promise<UserPlaylistPageResult> {
    this.requireSignedIn();
    const tv = this.useTvRail();
    logger.info(`[UserLibrary] stage=playlists rail=${tv ? 'tv' : 'web'} browseId=${this.PLAYLISTS_BROWSE_ID}`);
    const response = tv
      ? await fetchTvBrowsePage(
        this.localization,
        this.contentCountry,
        this.PLAYLISTS_BROWSE_ID,
        '',
        undefined,
        true
      )
      : await fetchBrowsePage(
        this.localization,
        this.contentCountry,
        this.PLAYLISTS_BROWSE_ID,
        '',
        undefined,
        true
      );
    if (!response) {
      throw new Error('Empty playlists browse response');
    }
    return this.parsePlaylistsBrowse(response as Record<string, Object>, startId, '');
  }

  async fetchSavedPlaylistsNext(
    nextPageToken: string,
    visitorData: string,
    startId: number
  ): Promise<UserPlaylistPageResult> {
    this.requireSignedIn();
    const trimmed = (nextPageToken || '').trim();
    if (!trimmed) {
      return { items: [], nextPageToken: null, visitorData };
    }
    const tv = this.useTvRail();
    const response = tv
      ? await fetchTvBrowseContinuation(
        this.localization,
        this.contentCountry,
        trimmed,
        visitorData,
        true
      )
      : await fetchBrowseContinuation(
        this.localization,
        this.contentCountry,
        trimmed,
        visitorData,
        true
      );
    if (!response) {
      throw new Error('Empty playlists continuation response');
    }
    return this.parsePlaylistsBrowse(response as Record<string, Object>, startId, visitorData);
  }

  private parsePlaylistsBrowse(
    root: Record<string, Object>,
    startId: number,
    fallbackVisitor: string
  ): UserPlaylistPageResult {
    const items: Array<SearchPlaylistItem> = [];
    const seen: Record<string, boolean> = {};
    let nextPageToken: string | null = null;
    let visitorData = fallbackVisitor;

    const responseContext = root['responseContext'] as Record<string, Object>;
    if (responseContext) {
      const fresh = (responseContext['visitorData'] as string) || '';
      if (fresh.length > 0) {
        visitorData = fresh;
      }
    }

    const maxNodes = 8000;
    const queue: Array<Object> = [root];
    let visited = 0;
    while (queue.length > 0 && visited < maxNodes) {
      const node = queue.shift();
      if (!node) {
        continue;
      }
      visited += 1;
      if (node instanceof Array) {
        const arr = node as Object[];
        for (let i = 0; i < arr.length; i++) {
          const child = arr[i];
          if (child) {
            queue.push(child);
          }
        }
        continue;
      }
      const obj = node as Record<string, Object>;

      const token = this.extractPlaylistContinuationToken(obj);
      if (token) {
        nextPageToken = token;
      }

      const built = this.buildPlaylistFromNode(obj, startId + items.length);
      if (built) {
        if (!seen[built.playlistId]) {
          seen[built.playlistId] = true;
          items.push(built);
        }
        continue;
      }

      const keys = Object.keys(obj);
      for (let i = 0; i < keys.length; i++) {
        const child = obj[keys[i]];
        if (!child) {
          continue;
        }
        if (child instanceof Array || child instanceof Object) {
          queue.push(child);
        }
      }
    }

    logger.info(`[UserLibrary] playlists parsed count=${items.length} hasNext=${!!nextPageToken} nodes=${visited}`);
    return { items, nextPageToken, visitorData };
  }

  private extractPlaylistContinuationToken(node: Record<string, Object>): string | null {
    const cont = node['continuationItemRenderer'] as Record<string, Object>;
    if (cont) {
      const token = getPlaylistContinuationToken(cont);
      if (token) {
        return token;
      }
    }
    return getPlaylistContinuationToken(node);
  }

  private buildPlaylistFromNode(node: Record<string, Object>, id: number): SearchPlaylistItem | null {
    const grid = node['gridPlaylistRenderer'] as Record<string, Object>;
    if (grid) {
      return this.buildPlaylistFromRenderer(grid, id);
    }
    const renderer = node['playlistRenderer'] as Record<string, Object>;
    if (renderer) {
      return this.buildPlaylistFromRenderer(renderer, id);
    }
    const lockup = node['lockupViewModel'] as Record<string, Object>;
    if (lockup) {
      return this.buildPlaylistFromLockup(lockup, id);
    }
    return null;
  }

  private buildPlaylistFromRenderer(renderer: Record<string, Object>, id: number): SearchPlaylistItem | null {
    let playlistId = (renderer['playlistId'] as string) || '';
    if (playlistId.length === 0) {
      playlistId = this.extractBrowseId(renderer);
    }
    if (playlistId.startsWith('VL')) {
      playlistId = playlistId.substring(2);
    }
    if (playlistId.length === 0) {
      return null;
    }
    const name = getTextFromRuns(renderer['title']) || 'Untitled';
    const uploader = getTextFromRuns(renderer['longBylineText'])
      || getTextFromRuns(renderer['shortBylineText']);
    const countText = getTextFromRuns(renderer['videoCountText'])
      || ((renderer['videoCount'] as string) || '');
    const coverUrl = getRendererThumbnailUrl(renderer);
    return new SearchPlaylistItem(
      id,
      playlistId,
      name,
      uploader,
      countText,
      coverUrl,
      '',
      ThumbnailPlaceholder.pickColor(playlistId || name, id)
    );
  }

  private buildPlaylistFromLockup(lockup: Record<string, Object>, id: number): SearchPlaylistItem | null {
    const contentType = (lockup['contentType'] as string) || '';
    if (contentType !== 'LOCKUP_CONTENT_TYPE_PLAYLIST'
      && contentType !== 'LOCKUP_CONTENT_TYPE_PODCAST') {
      return null;
    }
    const playlistId = getLockupPlaylistId(lockup);
    if (playlistId.length === 0) {
      return null;
    }
    const name = getLockupTitle(lockup) || 'Untitled';
    const uploader = getLockupUploaderName(lockup) || '';
    const coverUrl = getLockupPlaylistCoverUrl(lockup);
    return new SearchPlaylistItem(
      id,
      playlistId,
      name,
      uploader,
      '',
      coverUrl,
      '',
      ThumbnailPlaceholder.pickColor(playlistId || name, id)
    );
  }

  async fetchSubscribedChannels(): Promise<Array<SubscriptionUser>> {
    const snapshot = await this.fetchSubscribedChannelsSnapshot();
    return snapshot.channels;
  }

  /**
   * 云端订阅名单快照。WEB 走 FEchannels 并把续页翻完（≤ CHANNELS_MAX_PAGES），
   * 翻不完就 complete=false —— 订阅核对靠这个标志决定能不能删本地条目。
   */
  async fetchSubscribedChannelsSnapshot(): Promise<SubscribedChannelsSnapshot> {
    this.requireSignedIn();
    if (this.useTvRail()) {
      // TV has no clean FEchannels WEB tree; channel list lives on FEsubscriptions nav tabs.
      logger.info('[UserLibrary] stage=channels rail=tv browseId=FEsubscriptions');
      const response = await fetchTvBrowsePage(
        this.localization,
        this.contentCountry,
        this.SUBSCRIPTIONS_BROWSE_ID,
        '',
        undefined,
        true
      );
      if (!response) {
        throw new Error('Empty TV channels browse response');
      }
      const tvChannels = this.parseTvSubscribedChannels(response as Record<string, Object>);
      if (tvChannels.length > 0) {
        // 导航标签页就是这条频道的全集（无分页概念）。
        return { channels: tvChannels, complete: true };
      }
      // Fallback: generic UC scan (may be empty for pure TV payloads)
      return { channels: this.parseSubscribedChannels(response as Record<string, Object>), complete: false };
    }
    const startedAt = Date.now();
    const response = await fetchBrowsePage(
      this.localization,
      this.contentCountry,
      this.CHANNELS_BROWSE_ID,
      '',
      undefined,
      true
    );
    if (!response) {
      throw new Error('Empty channels browse response');
    }
    const root = response as Record<string, Object>;
    const responseContext = root['responseContext'] as Record<string, Object>;
    const visitorData = (responseContext ? (responseContext['visitorData'] as string) : '') || '';
    const channels: Array<SubscriptionUser> = [];
    const seen: Record<string, boolean> = {};
    const pushChannel = (
      channelId: string,
      displayName: string,
      avatarUrl: string,
      subscriberText: string
    ): void => {
      const id = (channelId || '').trim();
      if (!id || !id.startsWith('UC') || seen[id]) {
        return;
      }
      seen[id] = true;
      channels.push(new SubscriptionUser(
        id,
        displayName || id,
        avatarUrl || '',
        subscriberText || '',
        '',
        '',
        ThumbnailPlaceholder.pickColor(id, channels.length + 1),
        true
      ));
    };

    const firstScan = this.scanChannelsIterative(root, pushChannel);
    let tokens = firstScan.tokens;
    let pages = 1;
    let complete = !firstScan.truncated;
    while (tokens.length > 0 && pages < CHANNELS_MAX_PAGES) {
      const token = tokens[tokens.length - 1];
      const nextPage = await fetchBrowseContinuation(
        this.localization,
        this.contentCountry,
        token,
        visitorData,
        true
      );
      if (!nextPage) {
        complete = false;
        break;
      }
      const items = this.extractContinuationItems(nextPage as Record<string, Object>);
      if (items.length === 0) {
        break;
      }
      const pageScan = this.scanChannelsIterative(items, pushChannel);
      pages += 1;
      tokens = pageScan.tokens;
      if (pageScan.truncated) {
        complete = false;
        break;
      }
    }
    if (tokens.length > 0) {
      // 页数用尽仍有续页 → 名单不全，禁止删除本地条目。
      complete = false;
    }
    logger.info(`[SubSync] stage=cloud_snapshot channels=${channels.length} pages=${pages} complete=${complete} elapsed=${Date.now() - startedAt}ms`);
    return { channels, complete };
  }

  private extractContinuationItems(response: Record<string, Object>): Array<Record<string, Object>> {
    const items: Array<Record<string, Object>> = [];
    const actions = response['onResponseReceivedActions'] as Array<Record<string, Object>>;
    if (!actions) {
      return items;
    }
    actions.forEach((action) => {
      const append = action['appendContinuationItemsAction'] as Record<string, Object>;
      const continuationItems = append ? (append['continuationItems'] as Array<Record<string, Object>>) : undefined;
      if (continuationItems) {
        continuationItems.forEach((entry) => {
          if (entry) {
            items.push(entry);
          }
        });
      }
    });
    return items;
  }

  /**
   * 订阅写回服务端（Innertube subscription/subscribe）。
   * 调用方负责本地状态：这里只在失败时抛错，由 UI 回滚。
   */
  async subscribeChannel(channelId: string): Promise<void> {
    this.requireSignedIn();
    const tv = this.useTvRail();
    logger.info(`[SubSync] stage=subscribe_cloud rail=${tv ? 'tv' : 'web'} channelId=${channelId}`);
    await subscribeChannels(this.localization, this.contentCountry, [channelId], tv);
  }

  async unsubscribeChannel(channelId: string): Promise<void> {
    this.requireSignedIn();
    const tv = this.useTvRail();
    logger.info(`[SubSync] stage=unsubscribe_cloud rail=${tv ? 'tv' : 'web'} channelId=${channelId}`);
    await unsubscribeChannels(this.localization, this.contentCountry, [channelId], tv);
  }

  /**
   * 卡片长按菜单「保存到稍后观看」：写回账号的 Watch later 系统列表（Innertube 列表 id 就是 `WL`）。
   * 未登录直接抛错，由调用方提示；这里不动本地状态。
   */
  async saveToWatchLater(videoId: string): Promise<void> {
    this.requireSignedIn();
    const tv = this.useTvRail();
    logger.info(`[PlaylistWrite] stage=watch_later rail=${tv ? 'tv' : 'web'} videoId=${videoId}`);
    await addVideoToPlaylist('WL', videoId, this.localization, this.contentCountry, tv);
  }

  /**
   * 卡片长按菜单「不感兴趣 / 不推荐该频道」：把 feed 响应自带的 `feedbackEndpoint.token`
   * 原样回传给 Innertube `feedback`（服务端记录推荐反馈），和网页同一接口。
   * token 只在登录态的 feed 响应里出现，因此同样要求登录。
   */
  async sendFeedFeedback(feedbackToken: string): Promise<void> {
    this.requireSignedIn();
    const tv = this.useTvRail();
    await postFeedFeedback(feedbackToken, this.localization, this.contentCountry, tv);
  }

  async syncSubscribeChannels(channelIds: string[]): Promise<number> {
    this.requireSignedIn();
    const tv = this.useTvRail();
    const ids: string[] = [];
    channelIds.forEach((id) => {
      const trimmed = (id || '').trim();
      if (trimmed.length > 0 && ids.indexOf(trimmed) < 0) {
        ids.push(trimmed);
      }
    });
    if (ids.length === 0) {
      return 0;
    }
    logger.info(`[SubSync] stage=push_subscribe rail=${tv ? 'tv' : 'web'} count=${ids.length}`);
    await subscribeChannels(this.localization, this.contentCountry, ids, tv);
    return ids.length;
  }

  /**
   * 云端历史没有可靠时间戳；这里只填元数据，时间由 WatchHistoryStore.mergeRemoteHistory 处理。
   */
  toWatchHistoryItems(videos: Array<VideoItem>): Array<WatchHistoryItem> {
    return videos
      .filter((v) => !!(v.videoId && v.videoId.trim().length > 0))
      .map((v) => {
        const item: WatchHistoryItem = {
          videoId: v.videoId.trim(),
          title: v.title || v.videoId,
          author: v.author || '',
          thumbnailUrl: v.thumbnailUrl || '',
          durationSec: 0,
          progressSec: 0,
          lastWatchedAt: 0,
          channelId: v.channelId || '',
          channelAvatarUrl: v.channelAvatarUrl || '',
          channelHandle: v.channelHandle || ''
        };
        return item;
      });
  }

  private async fetchAuthBrowse(browseId: string, startId: number): Promise<UserVideoPageResult> {
    if (this.useTvRail()) {
      logger.info(`[UserLibrary] stage=browse rail=tv browseId=${browseId}`);
      const response = await fetchTvBrowsePage(
        this.localization,
        this.contentCountry,
        browseId,
        '',
        undefined,
        true
      );
      if (!response) {
        throw new Error(`Empty TV browse response: ${browseId}`);
      }
      return this.parseTvVideoBrowse(response as Record<string, Object>, startId);
    }
    logger.info(`[UserLibrary] stage=browse rail=web browseId=${browseId}`);
    const response = await fetchBrowsePage(
      this.localization,
      this.contentCountry,
      browseId,
      '',
      undefined,
      true
    );
    if (!response) {
      throw new Error(`Empty browse response: ${browseId}`);
    }
    return this.parseVideoBrowseInitial(response as Record<string, Object>, startId);
  }

  private async fetchAuthBrowseContinuation(
    nextPageToken: string,
    visitorData: string,
    startId: number
  ): Promise<UserVideoPageResult> {
    if (this.useTvRail()) {
      const response = await fetchTvBrowseContinuation(
        this.localization,
        this.contentCountry,
        nextPageToken,
        visitorData,
        true
      );
      if (!response) {
        throw new Error('Empty TV browse continuation response');
      }
      return this.parseTvVideoBrowse(response as Record<string, Object>, startId, visitorData);
    }
    const response = await fetchBrowseContinuation(
      this.localization,
      this.contentCountry,
      nextPageToken,
      visitorData,
      true
    );
    if (!response) {
      throw new Error('Empty browse continuation response');
    }
    return this.parseVideoBrowseContinuation(response as Record<string, Object>, visitorData, startId);
  }

  private parseTvVideoBrowse(
    response: Record<string, Object>,
    startId: number,
    fallbackVisitor: string = ''
  ): UserVideoPageResult {
    const built = buildTvBrowseVideoItems(response, startId);
    return {
      items: built.items,
      nextPageToken: built.nextPageToken,
      visitorData: getTvVisitorData(response) || fallbackVisitor
    };
  }

  private parseVideoBrowseInitial(response: Record<string, Object>, startId: number): UserVideoPageResult {
    const responseContext = response['responseContext'] as Record<string, Object>;
    const visitorData = (responseContext ? (responseContext['visitorData'] as string) : '') || '';
    const tabContent = this.extractTabContent(response);
    const rawItems = getHomeFeedItemsFromTabContent(tabContent);
    const built = buildHomeKioskVideoItems(rawItems, startId, '');
    return {
      items: built.items,
      nextPageToken: built.nextPageToken,
      visitorData
    };
  }

  private parseVideoBrowseContinuation(
    response: Record<string, Object>,
    visitorData: string,
    startId: number
  ): UserVideoPageResult {
    let items: Array<VideoItem> = [];
    let nextPageToken: string | null = null;

    const actions = response['onResponseReceivedActions'] as Array<Record<string, Object>>;
    if (actions && actions.length > 0) {
      actions.forEach((action) => {
        const append = action['appendContinuationItemsAction'] as Record<string, Object>;
        const continuationItems = append
          ? (append['continuationItems'] as Array<Record<string, Object>>)
          : undefined;
        if (!continuationItems || continuationItems.length === 0) {
          return;
        }
        const built = buildHomeKioskVideoItems(continuationItems, startId + items.length, '');
        items = items.concat(built.items);
        nextPageToken = built.nextPageToken ?? nextPageToken;
      });
    }

    return { items, nextPageToken, visitorData };
  }

  private extractTabContent(response: Record<string, Object>): Record<string, Object> | undefined {
    const contents = response['contents'] as Record<string, Object>;
    if (!contents) {
      return undefined;
    }
    const twoColumn = contents['twoColumnBrowseResultsRenderer'] as Record<string, Object>;
    const tabs = twoColumn ? (twoColumn['tabs'] as Array<Record<string, Object>>) : undefined;
    const tab0 = tabs && tabs.length > 0 ? tabs[0] : undefined;
    const tabRenderer = tab0 ? (tab0['tabRenderer'] as Record<string, Object>) : undefined;
    const tabContent = tabRenderer ? (tabRenderer['content'] as Record<string, Object>) : undefined;
    return tabContent ?? contents;
  }

  private parseSubscribedChannels(response: Record<string, Object>): Array<SubscriptionUser> {
    const result: Array<SubscriptionUser> = [];
    const seen: Record<string, boolean> = {};

    const pushChannel = (
      channelId: string,
      displayName: string,
      avatarUrl: string,
      subscriberText: string
    ): void => {
      const id = (channelId || '').trim();
      if (!id || !id.startsWith('UC') || seen[id]) {
        return;
      }
      seen[id] = true;
      result.push(new SubscriptionUser(
        id,
        displayName || id,
        avatarUrl || '',
        subscriberText || '',
        '',
        '',
        ThumbnailPlaceholder.pickColor(id, result.length + 1),
        true
      ));
    };

    // FEchannels 响应树很大；用有限深度的迭代扫描，避免递归栈溢出。
    this.scanChannelsIterative(response, pushChannel);

    logger.info(`parseSubscribedChannels count=${result.length}`);
    return result;
  }

  /**
   * TV FEsubscriptions secondary-nav tabs after "All" are per-channel entries.
   * Channel id is embedded in browseEndpoint.params (base64-ish with UC…).
   */
  private parseTvSubscribedChannels(response: Record<string, Object>): Array<SubscriptionUser> {
    const result: Array<SubscriptionUser> = [];
    const seen: Record<string, boolean> = {};
    const contents = response['contents'] as Record<string, Object>;
    const tvBrowse = contents ? (contents['tvBrowseRenderer'] as Record<string, Object>) : undefined;
    const content = tvBrowse ? (tvBrowse['content'] as Record<string, Object>) : undefined;
    const secondary = content ? (content['tvSecondaryNavRenderer'] as Record<string, Object>) : undefined;
    const sections = secondary ? (secondary['sections'] as Array<Record<string, Object>>) : undefined;
    const section0 = sections && sections.length > 0
      ? (sections[0]['tvSecondaryNavSectionRenderer'] as Record<string, Object>)
      : undefined;
    const tabs = section0 ? (section0['tabs'] as Array<Record<string, Object>>) : undefined;
    if (!tabs || tabs.length === 0) {
      logger.info('parseTvSubscribedChannels tabs=0');
      return result;
    }

    for (let i = 0; i < tabs.length; i++) {
      const tab = tabs[i];
      const tabRenderer = (tab['tabRenderer'] as Record<string, Object>)
        || (tab['expandableTabRenderer'] as Record<string, Object>);
      if (!tabRenderer) {
        continue;
      }
      const title = ((tabRenderer['title'] as string) || '').trim();
      if (!title || title.toLowerCase() === 'all') {
        continue;
      }
      const endpoint = tabRenderer['endpoint'] as Record<string, Object>;
      const browse = endpoint ? (endpoint['browseEndpoint'] as Record<string, Object>) : undefined;
      const params = browse ? ((browse['params'] as string) || '') : '';
      const channelId = this.extractChannelIdFromTvParams(params);
      if (!channelId || seen[channelId]) {
        continue;
      }
      seen[channelId] = true;
      result.push(new SubscriptionUser(
        channelId,
        title,
        '',
        '',
        '',
        '',
        ThumbnailPlaceholder.pickColor(channelId, result.length + 1),
        true
      ));
    }
    logger.info(`parseTvSubscribedChannels count=${result.length}`);
    return result;
  }

  private extractChannelIdFromTvParams(params: string): string {
    if (!params || params.length === 0) {
      return '';
    }
    // 1) plain UC… in raw/url-decoded string
    try {
      const pct = decodeURIComponent(params.replace(/\+/g, ' '));
      const mPlain = pct.match(/UC[\w-]{22}/);
      if (mPlain && mPlain[0]) {
        return mPlain[0];
      }
    } catch (_e) {
      // ignore
    }
    const m0 = params.match(/UC[\w-]{22}/);
    if (m0 && m0[0]) {
      return m0[0];
    }
    // 2) URL-safe base64 → binary; UC channel id is embedded as ASCII
    try {
      let b64 = params.replace(/%3D/gi, '=').replace(/%2B/gi, '+').replace(/%2F/gi, '/');
      try {
        b64 = decodeURIComponent(b64);
      } catch (_e) {
        // keep b64
      }
      b64 = b64.replace(/-/g, '+').replace(/_/g, '/');
      while (b64.length % 4 !== 0) {
        b64 += '=';
      }
      const ascii = this.base64ToAscii(b64);
      const m = ascii.match(/UC[\w-]{22}/);
      if (m && m[0]) {
        return m[0];
      }
    } catch (_e) {
      // ignore
    }
    return '';
  }

  private base64ToAscii(b64: string): string {
    // Platform base64 decode; the hand-rolled decoder skipped characters
    // outside the alphabet, so filter first to keep that tolerance.
    const cleaned = b64.replace(/[^A-Za-z0-9+/=]/g, '');
    const bytes = new util.Base64Helper().decodeSync(cleaned);
    let out = '';
    for (let i = 0; i < bytes.length; i++) {
      out += String.fromCharCode(bytes[i]);
    }
    return out;
  }

  private unwrapRichContent(node: Record<string, Object>, key: string): Record<string, Object> | undefined {
    const rich = node['richItemRenderer'] as Record<string, Object>;
    const content = rich ? (rich['content'] as Record<string, Object>) : undefined;
    return content ? (content[key] as Record<string, Object>) : undefined;
  }

  private extractBrowseId(renderer: Record<string, Object>): string {
    const nav = renderer['navigationEndpoint'] as Record<string, Object>;
    const browse = nav ? (nav['browseEndpoint'] as Record<string, Object>) : undefined;
    return (browse ? (browse['browseId'] as string) : '') || '';
  }

  private extractThumbnailUrl(thumbnail: Record<string, Object> | undefined): string {
    if (!thumbnail) {
      return '';
    }
    const thumbs = thumbnail['thumbnails'] as Array<Record<string, Object>>;
    if (!thumbs || thumbs.length === 0) {
      return '';
    }
    const last = thumbs[thumbs.length - 1];
    return (last['url'] as string) || '';
  }

  private extractLockupChannelId(lockup: Record<string, Object>): string {
    const contentId = (lockup['contentId'] as string) || '';
    if (contentId.startsWith('UC')) {
      return contentId;
    }
    const rendererContext = lockup['rendererContext'] as Record<string, Object>;
    const commandContext = rendererContext ? (rendererContext['commandContext'] as Record<string, Object>) : undefined;
    const onTap = commandContext ? (commandContext['onTap'] as Record<string, Object>) : undefined;
    const innertubeCommand = onTap ? (onTap['innertubeCommand'] as Record<string, Object>) : undefined;
    const browse = innertubeCommand ? (innertubeCommand['browseEndpoint'] as Record<string, Object>) : undefined;
    return (browse ? (browse['browseId'] as string) : '') || contentId;
  }

  private extractLockupTitle(lockup: Record<string, Object>): string {
    const metadata = lockup['metadata'] as Record<string, Object>;
    const title = metadata ? (metadata['title'] as Record<string, Object>) : undefined;
    if (!title) {
      return 'Untitled';
    }
    return (title['content'] as string)
      || getTextFromRuns(title)
      || 'Untitled';
  }

  private extractLockupThumbnail(lockup: Record<string, Object>): string {
    const contentImage = lockup['contentImage'] as Record<string, Object>;
    if (!contentImage) {
      return '';
    }
    const image = (contentImage['image'] as Record<string, Object>)
      || (contentImage['decoratedAvatarViewModel'] as Record<string, Object>);
    if (!image) {
      return '';
    }
    let sources = image['sources'] as Array<Record<string, Object>>;
    if (!sources || sources.length === 0) {
      const avatar = image['avatar'] as Record<string, Object>;
      const avatarImage = avatar ? (avatar['image'] as Record<string, Object>) : undefined;
      const avatarSources = avatarImage
        ? (avatarImage['sources'] as Array<Record<string, Object>>)
        : undefined;
      if (avatarSources && avatarSources.length > 0) {
        sources = avatarSources;
      }
    }
    if (sources && sources.length > 0) {
      return (sources[sources.length - 1]['url'] as string) || '';
    }
    return this.extractThumbnailUrl(image);
  }

  /**
   * Iterative BFS over the browse JSON. Caps depth/nodes so huge FEchannels
   * payloads cannot blow the ArkTS stack (previous recursive walk did).
   */
  private scanChannelsIterative(
    root: Object,
    pushChannel: (channelId: string, displayName: string, avatarUrl: string, subscriberText: string) => void
  ): ChannelScanResult {
    const scanResult: ChannelScanResult = { tokens: [], truncated: false };
    if (!root) {
      return scanResult;
    }
    const maxDepth = 24;
    const maxNodes = 8000;
    const queue: Array<Object> = [root];
    const depths: number[] = [0];
    let visited = 0;

    while (queue.length > 0 && visited < maxNodes) {
      const node = queue.shift();
      const depth = depths.shift() ?? 0;
      if (!node) {
        continue;
      }
      visited += 1;

      if (node instanceof Array) {
        const arr = node as Object[];
        if (depth >= maxDepth) {
          continue;
        }
        for (let i = 0; i < arr.length; i++) {
          const child = arr[i];
          if (child) {
            queue.push(child);
            depths.push(depth + 1);
          }
        }
        continue;
      }

      const obj = node as Record<string, Object>;
      const pendingToken = this.extractChannelScanToken(obj);
      if (pendingToken) {
        scanResult.tokens.push(pendingToken);
      }
      if (this.tryPushChannelNode(obj, pushChannel)) {
        // Channel leaf — still allow siblings via queue, but do not descend into this leaf.
        continue;
      }

      if (depth >= maxDepth) {
        continue;
      }

      // Only descend known structural keys to keep the scan cheap and relevant.
      const structuralKeys: string[] = [
        'contents', 'content', 'items', 'tabs', 'header', 'sections',
        'sectionListRenderer', 'itemSectionRenderer', 'richGridRenderer',
        'richItemRenderer', 'shelfRenderer', 'gridRenderer',
        'expandedShelfContentsRenderer', 'horizontalListRenderer',
        'twoColumnBrowseResultsRenderer', 'tabRenderer',
        'continuationItemRenderer'
      ];
      for (let i = 0; i < structuralKeys.length; i++) {
        const key = structuralKeys[i];
        const child = obj[key];
        if (child) {
          queue.push(child);
          depths.push(depth + 1);
        }
      }

      // Also enqueue any array-valued unknown keys that look like collections.
      const keys = Object.keys(obj);
      for (let i = 0; i < keys.length; i++) {
        const key = keys[i];
        if (structuralKeys.indexOf(key) >= 0) {
          continue;
        }
        const child = obj[key];
        if (child instanceof Array) {
          queue.push(child);
          depths.push(depth + 1);
        }
      }
    }
    // 队列非空却退出循环 = 撞上节点上限，这份名单不可信为全集。
    if (queue.length > 0) {
      scanResult.truncated = true;
    }
    return scanResult;
  }

  private extractChannelScanToken(obj: Record<string, Object>): string | null {
    const rawRenderer = obj['continuationItemRenderer'];
    const rawViewModel = obj['continuationItemViewModel'];
    const renderer = rawRenderer ? (rawRenderer as Record<string, Object>) : undefined;
    const viewModel = rawViewModel ? (rawViewModel as Record<string, Object>) : undefined;
    return getPlaylistContinuationToken(renderer)
      || getPlaylistContinuationToken(viewModel)
      || getPlaylistContinuationToken(obj);
  }

  private tryPushChannelNode(
    obj: Record<string, Object>,
    pushChannel: (channelId: string, displayName: string, avatarUrl: string, subscriberText: string) => void
  ): boolean {
    const channelRenderer = (obj['channelRenderer'] as Record<string, Object>)
      || this.unwrapRichContent(obj, 'channelRenderer');
    if (channelRenderer) {
      const channelId = (channelRenderer['channelId'] as string) || this.extractBrowseId(channelRenderer);
      const title = getTextFromRuns(channelRenderer['title']) || 'Untitled';
      const subscriberText = getTextFromRuns(channelRenderer['subscriberCountText']) || '';
      const avatarUrl = this.extractThumbnailUrl(channelRenderer['thumbnail'] as Record<string, Object>);
      pushChannel(channelId, title, avatarUrl, subscriberText);
      return true;
    }

    const gridChannel = (obj['gridChannelRenderer'] as Record<string, Object>)
      || this.unwrapRichContent(obj, 'gridChannelRenderer');
    if (gridChannel) {
      const channelId = (gridChannel['channelId'] as string) || this.extractBrowseId(gridChannel);
      const title = getTextFromRuns(gridChannel['title']) || 'Untitled';
      const subscriberText = getTextFromRuns(gridChannel['subscriberCountText']) || '';
      const avatarUrl = this.extractThumbnailUrl(gridChannel['thumbnail'] as Record<string, Object>);
      pushChannel(channelId, title, avatarUrl, subscriberText);
      return true;
    }

    const lockup = (obj['lockupViewModel'] as Record<string, Object>)
      || this.unwrapRichContent(obj, 'lockupViewModel');
    if (lockup) {
      const contentType = (lockup['contentType'] as string) || '';
      const channelId = this.extractLockupChannelId(lockup);
      if (channelId.startsWith('UC')
        || contentType === 'LOCKUP_CONTENT_TYPE_CHANNEL'
        || contentType.indexOf('CHANNEL') >= 0) {
        const title = this.extractLockupTitle(lockup);
        const avatarUrl = this.extractLockupThumbnail(lockup);
        pushChannel(channelId, title, avatarUrl, '');
        return true;
      }
    }
    return false;
  }
}
