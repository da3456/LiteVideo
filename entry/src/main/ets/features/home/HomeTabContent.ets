import { AppLog } from '../../common/AppLog';
import { AuthSessionManager } from 'youtube_core';
import { AuthAccountStatus, AuthStage } from 'youtube_core';
import { VideoItem } from 'youtube_core';
import { VideoCard } from '../../common/components/VideoCard';
import { VideoCardGrid } from '../../common/components/VideoCardGrid';
import { HomeRecommendSwiper } from './components/HomeRecommendSwiper';
import { MediaFeedItemSlot, MediaVideoFeed } from '../../common/components/MediaVideoFeed';
import { FeedDataSource } from '../../common/model/FeedDataSource';
import { getFeedContentWidthVp, getVideoGridColumnCount } from '../../common/utils/ListLayoutUtils';
import { ErrorPage } from '../../common/components/ErrorPage';
import { customAnimationUtil } from '../../common/AnimationUtil';
import { FeedServiceProvider } from '../../common/FeedServiceProvider';
import { FeedFeedbackStore } from '../../common/FeedFeedbackStore';
import { KioskPageResult } from './HomeFeedService';
import { UIConfig } from '../../common/AppState';
import { SubscriptionUser } from '../../common/SubscriptionModel';
import { WatchHistoryStore } from '../../common/WatchHistoryStore';
import { COLOR_PRESETS } from '../../common/ThemeManager';

const logger = AppLog.getInstance('HomeTabContent');

/** 首页静默空白看门狗超时（ms）：这期间既没内容也没报错就判定为卡住。 */
const HOME_BLANK_WATCHDOG_MS: number = 20000;

/** 短视频列表少于该条数时，继续翻首页 feed 去收短视频（短视频就在这份混合 feed 里）。 */
const HOME_SHORTS_TOPUP_THRESHOLD: number = 12;
/** 单次补收最多额外翻几页首页 feed。 */
const HOME_SHORTS_HARVEST_PAGES: number = 5;
/** 短视频攒够这个数就停手（首页 feed 的 Shorts 货架位置不固定，多翻几页才碰得到）。 */
const HOME_SHORTS_HARVEST_TARGET: number = 24;
/** feed 到顶后，最多取多少个"我的频道"的 /shorts 标签页。 */
const HOME_SHORTS_MAX_CHANNELS: number = 20;
/**
 * 一轮补货同时查多少个频道。
 * 频道池整体查一遍（串行 await）要十几秒，首屏会被拖死；这里改成
 * **并发查 N 个**、频道池按游标轮转，每轮只花一两秒。
 */
const HOME_SHORTS_CHANNEL_FETCH_PER_ROUND: number = 6;
/** 一轮频道补货最多并入多少条短视频。 */
const HOME_SHORTS_CHANNEL_BATCH: number = 60;
/**
 * 一批长视频取几页（约 3 页 ≈ 60 条）。取满后下滑不再请求，提示"下一批"由
 * 下拉刷新 / 再点一次底部首页触发 —— 短视频维度不受这个上限约束。
 */
const HOME_BATCH_MAX_PAGES: number = 3;

/** 短视频补收用的频道游标（每个频道独立分页）。 */
interface ShortsChannelState {
  channelId: string;
  token: string;
  visitor: string;
  exhausted: boolean;
}

/** 一页 feed 按 isShort 拆分的结果。 */
interface HomeFeedSplit {
  long: VideoItem[];
  short: VideoItem[];
}

/**
 * 首页 tab 与 Index 之间的控制句柄：feed 重置（启动 / 登录态变化 / 搜索地区
 * 语言切换共用）与滚动容器（HdsNavigation.bindToScrollable 共用同一实例）。
 * 实现由 HomeTabContent 挂载时注册；注册前的 reset 调用排队一次，挂载后立即补放。
 */
export class HomeTabController {
  gridScroller: Scroller = new Scroller();
  listScroller: Scroller = new Scroller();
  private resetImpl: ((clearList: boolean, reload: boolean) => void) | null = null;
  private queuedClearList: boolean = false;
  private queuedReload: boolean = false;
  private hasQueuedReset: boolean = false;
  private modeSwitchImpl: ((mode: string) => void) | null = null;
  private batchAdvanceImpl: (() => void) | null = null;
  private removeFeedbackImpl: ((videoId: string, channelId: string) => void) | null = null;

  registerReset(impl: (clearList: boolean, reload: boolean) => void): void {
    this.resetImpl = impl;
    if (this.hasQueuedReset) {
      this.hasQueuedReset = false;
      impl(this.queuedClearList, this.queuedReload);
    }
  }

  resetFeed(clearList: boolean, reload: boolean): void {
    if (this.resetImpl) {
      this.resetImpl(clearList, reload);
      return;
    }
    this.queuedClearList = clearList;
    this.queuedReload = reload;
    this.hasQueuedReset = true;
  }

  /**
   * 首页维度切换（长视频 / 短视频）：数据源要换一份（两个列表是分开的），
   * 由首页内容侧同步 + 回到顶部。
   */
  registerModeSwitch(impl: (mode: string) => void): void {
    this.modeSwitchImpl = impl;
  }

  switchMode(mode: string): void {
    if (this.modeSwitchImpl) {
      this.modeSwitchImpl(mode);
    }
  }

  /**
   * 开启下一批首页内容（回到顶部 + 取新的一批）。
   * 由 Index 在"已经停在首页时再点一次底部首页页签"时触发 —— 官方
   * BottomTabBarStyle 没有点击事件，Tabs.onChange 同索引也不回调，
   * 所以走 HdsTabs.onTabBarClick 回到内容侧。
   */
  registerBatchAdvance(impl: () => void): void {
    this.batchAdvanceImpl = impl;
  }

  advanceBatch(): void {
    if (this.batchAdvanceImpl) {
      this.batchAdvanceImpl();
    }
  }

  /** 服务端反馈成功后，把这条视频 / 这个频道的卡片从当前首页列表即时摘掉。 */
  registerRemoveFeedbackCards(impl: (videoId: string, channelId: string) => void): void {
    this.removeFeedbackImpl = impl;
  }

  removeFeedbackCards(videoId: string, channelId: string): void {
    if (this.removeFeedbackImpl) {
      this.removeFeedbackImpl(videoId, channelId);
    }
  }
}

/**
 * 首页 tab 内容宿主：feed 加载状态机（kiosk/推荐双轨 + 分页 + 下拉刷新）、
 * 错误格式化、推荐位 banner、错误页 / 信息流 / 初始加载遮罩三档视图。
 * 原 Index.TabContentSection(0) 分支纯迁移；Index 经 HomeTabController 触发 reset。
 */
@Component
export struct HomeTabContent {
  controller: HomeTabController = new HomeTabController();
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig();
  @StorageLink('deviceWidth') deviceWidth: number = 0;
  @StorageProp('themePrimaryColor') themePrimary: string = COLOR_PRESETS[0].primary;
  /** 登录态：登录后这条游客提示要立刻消失，所以走 AppStorage 而不是每次查 session。 */
  @StorageProp('authStatus') authStatus: AuthAccountStatus = new AuthAccountStatus();
  /** 游客提示里的「去登录」：由 Index 打开设置面板（登录入口在 数据与账号）。 */
  onOpenLoginClick: () => void = () => {};
  @Consume('safeAreaTop') safeAreaTop: number = 0;
  @Consume('safeAreaBottom') safeAreaBottom: number = 0;
  @State longList: VideoItem[] = [];
  @State shortList: VideoItem[] = [];
  /** 正在进行的 feed 拉取（"多翻几页收短视频"要串行等它）。 */
  private feedLoadInFlight: Promise<void> = Promise.resolve();
  /** 短视频补收（多翻 feed 页）的 in-flight 标记。 */
  private shortsHarvestInFlight: boolean = false;
  /** 频道补货（feed 到顶后接"我的频道"）的状态与 in-flight 标记。 */
  private shortsChannels: ShortsChannelState[] = [];
  private shortsChannelTopUpInFlight: boolean = false;
  /** 频道池轮转游标：每轮从这里开始挑频道。 */
  private shortsChannelCursor: number = 0;
  private shortsIdCursor: number = 1000000;
  @State isLoadingMore: boolean = false;
  @State isInitialLoading: boolean = false;
  @State isHomeRefreshing: boolean = false;
  @State homeErrorMessage: string = '';
  @State homeModeNoticeMessage: string = '';
  /** 每次首页 reset 成功后 +1：仅驱动推荐位 banner 重建；列表刷新由 DataChangeListener 全量通知负责 */
  @State homeFeedEpoch: number = 0;
  /**
   * 分页游标：只给请求用，不进 build()，所以是普通字段 ——
   * 每页都写 @State 会让整个 tab 组件多挨一次脏标记。
   */
  private kioskNextPageToken: string | null = null;
  private kioskVisitorData: string = '';
  @State homeFeedSource: string = 'kiosk';
  @State homeMode: string = 'kiosk';
  /** 首页信息流 LazyForEach 数据源：当前维度的列表变更后由 syncHomeFeedDataSource 同步 */
  private homeFeedDataSource: FeedDataSource = new FeedDataSource();
  private homeBannerMax: number = 6;
  /** 当前批已取页数（长视频维度据此判定批尾）。 */
  private batchPages: number = 0;
  /** 批尾提示每批只弹一次（下滑触底会被反复触发）。 */
  private batchEndAnnounced: boolean = false;
  /**
   * 首页 feed 请求代次：每次 reset/刷新递增。旧请求晚返回时不得覆盖新结果
   * （登录态/内容源切换与启动加载并发时，旧的 kiosk 响应会把推荐列表顶掉）。
   */
  private homeLoadGeneration: number = 0;
  /** 静默空白看门狗的定时器 id（-1 = 未挂或已触发）。 */
  private homeBlankWatchdog: number = -1;

  aboutToAppear() {
    this.controller.registerReset((clearList: boolean, reload: boolean) => {
      this.resetHomeFeed(clearList, reload);
    });
    this.controller.registerModeSwitch((mode: string) => {
      this.onHomeModeSwitched(mode);
    });
    this.controller.registerBatchAdvance(() => {
      this.scrollHomeFeedToTop();
      this.refreshHomeFeed().catch(() => undefined);
    });
    this.controller.registerRemoveFeedbackCards((videoId: string, channelId: string) => {
      this.removeFeedbackCards(videoId, channelId);
    });
    // 静默空白看门狗：首页首个加载由 Index 挂在代理就绪之后，那一步卡住（或请求
    // 长时间不返回）时列表和错误文案都是空的，用户只会看到一片白。超时就把它变成可重试的错误页。
    this.homeBlankWatchdog = setTimeout(() => {
      this.homeBlankWatchdog = -1;
      if (this.longList.length === 0 && this.shortList.length === 0
        && !this.isInitialLoading && this.homeErrorMessage.length === 0) {
        logger.warn('[HomeFeed] stage=blank_watchdog no items and no error after startup window');
        this.homeErrorMessage = getContext().resourceManager.getStringSync(
          $r('app.string.yt_home_load_error').id);
      }
    }, HOME_BLANK_WATCHDOG_MS);
  }

  aboutToDisappear() {
    if (this.homeBlankWatchdog >= 0) {
      clearTimeout(this.homeBlankWatchdog);
      this.homeBlankWatchdog = -1;
    }
  }

  /**
   * 首页维度切换（长视频 ↔ 短视频）：两个列表是分开维护的，切换只换显示的
   * 那一份（数据源换 key 序列 → 整列重建），不回顶部、不重新请求。
   */
  private onHomeModeSwitched(mode: string): void {
    logger.info(`[HomeFeed] stage=mode_switch mode=${mode} `
      + `long=${this.longList.length} short=${this.shortList.length}`);
    this.syncHomeFeedDataSource();
    this.scrollHomeFeedToTop();
    if (mode === 'short') {
      if (this.shortList.length < HOME_SHORTS_TOPUP_THRESHOLD) {
        this.harvestShortsFromFeed().catch(() => undefined);
      } else if (!this.kioskNextPageToken) {
        this.topUpShortsFromChannels().catch(() => undefined);
      }
    }
  }

  /**
   * 首页 feed 重置单一入口（启动 / 登录态变化 / 搜索地区语言切换共用）：
   * 清空分页状态与（可选）列表后按需立即重载。
   * 下拉刷新（refreshHomeFeed）刻意不走这里——它要保留当前 rail
   * （homeFeedSource 可能是 recommended）和旧列表防白屏。
   */
  private resetHomeFeed(clearList: boolean, reload: boolean): void {
    this.homeMode = 'kiosk';
    this.kioskNextPageToken = null;
    this.kioskVisitorData = '';
    this.homeFeedSource = 'kiosk';
    this.homeErrorMessage = '';
    this.homeModeNoticeMessage = '';
    if (clearList) {
      this.longList = [];
      this.shortList = [];
      this.batchPages = 0;
      this.batchEndAnnounced = false;
      this.syncHomeFeedDataSource();
    }
    if (reload) {
      this.loadLiveVideos(true);
    }
  }

  /** 记录在飞的 feed 请求：短视频补收要串行等它结束再要下一页。 */
  private loadLiveVideos(reset: boolean = false): Promise<void> {
    const task = this.doLoadLiveVideos(reset);
    this.feedLoadInFlight = task;
    return task;
  }

  private async doLoadLiveVideos(reset: boolean = false) {
    if (reset) {
      this.homeLoadGeneration += 1;
      this.isLoadingMore = false;
      this.isInitialLoading = this.activeList().length === 0;
      this.homeErrorMessage = '';
      this.batchPages = 0;
      this.batchEndAnnounced = false;
    } else {
      if (this.isLoadingMore) {
        return;
      }
      if (!this.isShortMode() && this.batchPages >= HOME_BATCH_MAX_PAGES) {
        // 批尾：这一批取满了，下滑不再要页 —— 下一批由下拉刷新 / 再点一次首页触发。
        this.announceBatchEnd();
        return;
      }
      if (!this.kioskNextPageToken) {
        return;
      }
      this.isLoadingMore = true;
    }
    const generation = this.homeLoadGeneration;
    const loadStartedAt = Date.now();
    logger.info(`[HomeFeed] stage=load_start reset=${reset} mode=${this.homeMode} `
      + `source=${this.homeFeedSource} batchPages=${this.batchPages} `
      + `long=${this.longList.length} short=${this.shortList.length}`);
    try {
      if (this.homeMode !== 'kiosk') {
        return;
      }
      if (reset) {
        await this.startHomeBatch(generation, loadStartedAt);
        return;
      }
      const page = await this.fetchFeedPage(false, this.longList.length + this.shortList.length + 1, generation);
      if (page === null) {
        return;
      }
      const split = this.splitByType(page.items);
      // 空数组也要 concat 会白折腾一次 @State 通知（整列重渲染），有内容才写。
      if (split.long.length > 0) {
        this.longList = this.longList.concat(split.long);
      }
      if (split.short.length > 0) {
        this.shortList = this.shortList.concat(split.short);
      }
      // 短视频维度不设批上限，它翻页时顺带并入的长视频不该吃掉长视频的批次预算。
      if (!this.isShortMode()) {
        this.batchPages += 1;
      }
      this.homeErrorMessage = '';
      this.syncHomeFeedDataSource();
      logger.info(`[HomeFeed] stage=load_done reset=false batchPages=${this.batchPages} `
        + `source=${this.homeFeedSource} items=${page.items.length} `
        + `long=${this.longList.length} short=${this.shortList.length} `
        + `elapsed=${Date.now() - loadStartedAt}ms`);
      this.maybeTopUpShorts();
      return;
    } catch (err) {
      if (generation !== this.homeLoadGeneration) {
        logger.info(`[HomeFeed] stage=stale_error_drop reset=${reset} generation=${generation} `
          + `current=${this.homeLoadGeneration}`);
        return;
      }
      // Never JSON.stringify(Error) alone — enumerable fields are empty → "{}" in user logs.
      logger.error(`[HomeFeed] stage=failed reset=${reset} mode=${this.homeMode} `
        + `source=${this.homeFeedSource} ${this.describeThrowable(err)}`);
      if (reset && this.homeMode === 'kiosk') {
        const wantedRecommended = UIConfig.normalizeHomeFeedStyle(this.uiConfig.homeFeedStyle) === 'recommended'
          && AuthSessionManager.getInstance()?.hasAuthForUserData() === true;
        const fallbackRes = wantedRecommended
          ? $r('app.string.yt_home_recommended_error')
          : $r('app.string.yt_home_kiosk_error');
        this.homeErrorMessage = this.formatHomeRequestError(
          err as Object,
          getContext().resourceManager.getStringSync(fallbackRes.id)
        );
        if (wantedRecommended) {
          // Keep dual-rail prefix so banner gating (indexOf recommended) still works after error.
          this.homeFeedSource = 'recommended';
        }
      } else {
        this.homeErrorMessage = this.formatHomeRequestError(err as Object, getContext().resourceManager.getStringSync($r('app.string.yt_home_load_error').id));
      }
      // 保留已有列表，避免加载失败时清空
    } finally {
      // 旧代次的收尾不得清掉新请求的 loading 状态。
      if (generation === this.homeLoadGeneration) {
        this.isLoadingMore = false;
        if (reset) {
          this.isInitialLoading = false;
        }
      }
    }
  }

  /**
   * 取一页首页 feed 并推进分页状态（token / visitorData / source）。返回 null
   * 表示这次请求已经作废（代次被后来的刷新顶掉），调用方直接放弃本轮。
   * 列表内容不在这里改 —— 批首是整页替换、追加页是 concat，所以并入时机由
   * `startHomeBatch` / 追加路径各自决定。
   */
  private async fetchFeedPage(useInitial: boolean, startId: number,
    generation: number): Promise<KioskPageResult | null> {
    const homeService = FeedServiceProvider.getInstance().getHomeFeedService();
    const feedStyle = UIConfig.normalizeHomeFeedStyle(this.uiConfig.homeFeedStyle);
    const useAuthContinuation = this.homeFeedSource.indexOf('recommended') === 0;
    const result = useInitial
      ? await homeService.fetchHomeKioskInitial(startId, feedStyle)
      : await homeService.fetchHomeKioskNext(
        this.kioskNextPageToken ?? '',
        this.kioskVisitorData,
        startId,
        useAuthContinuation,
        this.homeFeedSource
      );
    if (generation !== this.homeLoadGeneration) {
      logger.info(`[HomeFeed] stage=stale_drop generation=${generation} `
        + `current=${this.homeLoadGeneration}`);
      return null;
    }
    if (useInitial) {
      this.homeFeedSource = result.source || 'kiosk';
    }
    this.kioskNextPageToken = result.nextPageToken;
    if (result.visitorData && result.visitorData.length > 0) {
      this.kioskVisitorData = result.visitorData;
    }
    return result;
  }

  /**
   * 开启新一批：只取一页当批首，后面每页仍按原来的"触底再要"节奏无感追加。
   * 推荐流返回什么就显示什么，不做跨批去重，所以这里只有一次网络请求。
   * 页空（服务端没给内容）时保留当前列表，不白屏。
   */
  private async startHomeBatch(generation: number, startedAt: number): Promise<void> {
    const page = await this.fetchFeedPage(this.kioskNextPageToken === null,
      this.longList.length + this.shortList.length + 1, generation);
    if (page === null) {
      return;
    }
    if (page.items.length === 0) {
      logger.info(`[HomeFeed] stage=batch_empty elapsed=${Date.now() - startedAt}ms `
        + `source=${this.homeFeedSource} long=${this.longList.length} short=${this.shortList.length}`);
      return;
    }
    if (!this.isShortMode()) {
      this.batchPages += 1;
    }
    const split = this.splitByType(page.items);
    this.longList = split.long;
    this.shortList = split.short;
    this.homeFeedEpoch += 1;
    this.scrollHomeFeedToTop();
    this.syncHomeFeedDataSource();
    this.homeErrorMessage = '';
    this.homeModeNoticeMessage = '';
    if ((page.source || this.homeFeedSource) === 'kiosk'
      && UIConfig.normalizeHomeFeedStyle(this.uiConfig.homeFeedStyle) === 'recommended') {
      const authRejected = AuthSessionManager.getInstance()?.consumeAuthRejectionNotice() === true;
      if (authRejected) {
        // 登录态被拒后已回落到游客 kiosk，提示用户重新登录。
        this.homeModeNoticeMessage = getContext().resourceManager.getStringSync(
          $r('app.string.yt_home_auth_expired_notice').id);
      } else if (AuthSessionManager.getInstance()?.hasAuthForUserData() === true) {
        // 有用户数据权限但推荐源失败/为空时已回退 kiosk：明确提示，
        // 否则用户会以为「推荐/直播」设置没有生效。
        this.homeModeNoticeMessage = getContext().resourceManager.getStringSync(
          $r('app.string.yt_home_recommended_error').id);
      }
    }
    logger.info(`[HomeFeed] stage=load_done reset=true mode=kiosk source=${this.homeFeedSource} `
      + `batchPages=${this.batchPages} long=${this.longList.length} `
      + `short=${this.shortList.length} elapsed=${Date.now() - startedAt}ms`);
    this.maybeTopUpShorts();
  }

  /**
   * 短视频维度补收：
   * - 短视频还不够 → 往后再翻几页混合 feed，把 Shorts 货架收进来；
   * - feed 已经翻到头（continuation 有限）→ 换「我的频道」的 /shorts 续上。
   */
  private maybeTopUpShorts(): void {
    if (!this.isShortMode()) {
      return;
    }
    if (this.shortList.length < HOME_SHORTS_TOPUP_THRESHOLD) {
      this.harvestShortsFromFeed().catch(() => undefined);
    } else if (!this.kioskNextPageToken) {
      this.topUpShortsFromChannels().catch(() => undefined);
    }
  }

  /** 这一批取满了：提示一次"下一批"怎么拿（每批只弹一次，触底会反复回调）。 */
  private announceBatchEnd(): void {
    if (this.batchEndAnnounced) {
      return;
    }
    this.batchEndAnnounced = true;
    logger.info(`[HomeFeed] stage=batch_end pages=${this.batchPages} `
      + `long=${this.longList.length} short=${this.shortList.length}`);
    this.getUIContext()?.getPromptAction().showToast({
      message: $r('app.string.yt_home_batch_end'),
      duration: 2500
    });
  }

  /**
   * 开启下一批（下拉刷新 / 停在首页再点底栏首页页签都会走这里）。
   * 刻意不清分页状态：有 token 就顺着链条往后要，链条到头才重新起链。
   */
  private async refreshHomeFeed(): Promise<void> {
    // Refresh sets the two-way bound value before invoking onRefreshing.
    // Always perform the work and clear it in finally.
    logger.info(`[HomeRefresh] stage=start mode=${this.homeMode} source=${this.homeFeedSource} `
      + `batchPages=${this.batchPages} token=${this.kioskNextPageToken ? 'yes' : 'no'}`);
    const startedAt = Date.now();
    const prevHead = this.activeList().length > 0
      ? (this.activeList()[0].videoId || this.activeList()[0].id.toString())
      : '';
    try {
      await this.loadLiveVideos(true);
      const nextHead = this.activeList().length > 0
        ? (this.activeList()[0].videoId || this.activeList()[0].id.toString())
        : '';
      logger.info(`[HomeRefresh] stage=complete mode=${this.homeMode} source=${this.homeFeedSource} `
        + `elapsed=${Date.now() - startedAt}ms items=${this.activeList().length} head=${nextHead} `
        + `changed=${prevHead !== nextHead} error=${this.homeErrorMessage.length > 0 ? 'yes' : 'no'}`);
    } catch (e) {
      logger.error(`[HomeRefresh] stage=failed elapsed=${Date.now() - startedAt}ms ${this.describeThrowable(e)}`);
    } finally {
      this.isHomeRefreshing = false;
    }
  }

  private scrollHomeFeedToTop(): void {
    try {
      if (this.uiConfig.homeLayoutMode === 'grid') {
        this.controller.gridScroller.scrollTo({ xOffset: 0, yOffset: 0, animation: false });
      } else {
        this.controller.listScroller.scrollTo({ xOffset: 0, yOffset: 0, animation: false });
      }
    } catch (e) {
      logger.warn(`[HomeRefresh] scrollToTop failed: ${JSON.stringify(e)}`);
    }
  }

  /** LazyForEach 稳定 key：videoId 即身份；下拉刷新的整列重建由数据源 onDataReloaded 负责 */
  private homeListItemKey(item: VideoItem): string {
    const videoId = (item.videoId || '').trim();
    return videoId.length > 0 ? videoId : item.id.toString();
  }

  /**
   * feed 到顶后的续供：取「我的频道」的 /shorts 标签页。
   *
   * 频道池 = 订阅频道 → 观看历史里的频道（去重，最多 20 个）。这些频道跟账号
   * 相关，不是泛搜索那种批量内容；每个频道的 Shorts 标签独立分页，能一直翻。
   *
   * **每轮只并发查 N 个频道**（`HOME_SHORTS_CHANNEL_FETCH_PER_ROUND`），
   * 频道池按游标轮转 —— 把整个池子串行查一遍要十几秒，滑动会被拖死。
   *
   * 多频道的条目**轮转交织**后再并入列表 —— 否则一个频道的几十条会把
   * 列表前半段刷成"同一个作者"（这正是全屏 Shorts 页当初的问题）。
   */
  private async topUpShortsFromChannels(): Promise<void> {
    if (this.shortsChannelTopUpInFlight) {
      return;
    }
    this.shortsChannelTopUpInFlight = true;
    const startedAt = Date.now();
    try {
      if (this.shortsChannels.length === 0) {
        this.shortsChannels = this.buildAccountChannelStates();
        logger.info(`[HomeFeed] stage=shorts_channels pool=${this.shortsChannels.length}`);
      }
      if (this.shortsChannels.length === 0) {
        return;
      }
      const picked = this.pickChannelsForRound();
      if (picked.length === 0) {
        logger.info(`[HomeFeed] stage=shorts_channel_topup skipped=all_exhausted`);
        return;
      }
      const service = FeedServiceProvider.getInstance().getChannelService();
      // 并发查本轮选中的频道（browse 请求彼此独立，可以并发）。
      const pages: Array<Array<VideoItem>> = await Promise.all(
        picked.map(async (state: ShortsChannelState): Promise<Array<VideoItem>> => {
          try {
            const result = state.token.length > 0
              ? await service.fetchChannelShortsNext(state.token, state.visitor, this.shortsIdCursor)
              : await service.fetchChannelShortsInitial(state.channelId, this.shortsIdCursor);
            state.token = result.nextPageToken ?? '';
            state.visitor = result.visitorData || state.visitor;
            if (state.token.length === 0) {
              state.exhausted = true;
            }
            // /shorts 标签页里的东西按定义就是短视频。
            const shorts: Array<VideoItem> = [];
            for (let k = 0; k < result.items.length; k++) {
              result.items[k].isShort = true;
              shorts.push(result.items[k]);
            }
            return shorts;
          } catch (e) {
            logger.warn(`[HomeFeed] stage=shorts_channel_failed channel=${state.channelId} `
              + `${this.describeThrowable(e)}`);
            state.exhausted = true;
            return [];
          }
        })
      );
      const nonEmpty: Array<Array<VideoItem>> = [];
      for (let i = 0; i < pages.length; i++) {
        if (pages[i].length > 0) {
          nonEmpty.push(pages[i]);
        }
      }
      const merged = this.interleaveByChannel(nonEmpty, HOME_SHORTS_CHANNEL_BATCH);
      // 只在短视频列表内部防重复条目（重复 videoId = 重复 LazyForEach key）。
      const seen = new Set<string>();
      for (let i = 0; i < this.shortList.length; i++) {
        const existing = (this.shortList[i].videoId || '').trim();
        if (existing.length > 0) {
          seen.add(existing);
        }
      }
      const added: Array<VideoItem> = [];
      for (let i = 0; i < merged.length; i++) {
        const videoId = (merged[i].videoId || '').trim();
        if (videoId.length === 0 || seen.has(videoId)) {
          continue;
        }
        seen.add(videoId);
        added.push(merged[i]);
      }
      if (added.length > 0) {
        this.shortList = this.shortList.concat(added);
        if (this.isShortMode()) {
          this.syncHomeFeedDataSource();
        }
      }
      logger.info(`[HomeFeed] stage=shorts_channel_topup added=${added.length} `
        + `total=${this.shortList.length} channels=${nonEmpty.length}/${picked.length} `
        + `elapsed=${Date.now() - startedAt}ms`);
    } catch (e) {
      logger.warn(`[HomeFeed] stage=shorts_channel_topup_failed ${this.describeThrowable(e)}`);
    } finally {
      this.shortsChannelTopUpInFlight = false;
    }
  }

  /**
   * 本轮要查的频道：从游标开始轮转，跳过已翻完的，最多 N 个。
   * 游标推进 → 下一轮自然换一批频道（既能持续供给，作者也更多样）。
   */
  private pickChannelsForRound(): ShortsChannelState[] {
    const picked: ShortsChannelState[] = [];
    const total = this.shortsChannels.length;
    for (let i = 0; i < total && picked.length < HOME_SHORTS_CHANNEL_FETCH_PER_ROUND; i++) {
      const index = (this.shortsChannelCursor + i) % total;
      const state = this.shortsChannels[index];
      if (!state.exhausted) {
        picked.push(state);
      }
    }
    if (total > 0) {
      this.shortsChannelCursor = (this.shortsChannelCursor + picked.length) % total;
    }
    return picked;
  }

  /** 频道池：订阅频道优先，其次观看历史里的频道（去重、限量）。 */
  private buildAccountChannelStates(): ShortsChannelState[] {
    const ids: string[] = [];
    const push = (id: string): void => {
      const trimmed = (id || '').trim();
      if (trimmed.length > 0 && ids.indexOf(trimmed) < 0) {
        ids.push(trimmed);
      }
    };
    try {
      const subs = AppStorage.get<Array<SubscriptionUser>>('subscriptions');
      if (subs) {
        for (let i = 0; i < subs.length; i++) {
          push(subs[i].channelId);
        }
      }
    } catch (e) {
      logger.warn(`[HomeFeed] stage=shorts_channels_subs_failed ${this.describeThrowable(e)}`);
    }
    try {
      const history = WatchHistoryStore.getAll();
      for (let i = 0; i < history.length; i++) {
        push(history[i].channelId);
      }
    } catch (e) {
      logger.warn(`[HomeFeed] stage=shorts_channels_history_failed ${this.describeThrowable(e)}`);
    }
    const states: ShortsChannelState[] = [];
    for (let i = 0; i < ids.length && states.length < HOME_SHORTS_MAX_CHANNELS; i++) {
      states.push({ channelId: ids[i], token: '', visitor: '', exhausted: false });
    }
    return states;
  }

  /** 多个频道的条目轮转交织（每个频道轮流出一条），避免整屏同一个作者。 */
  private interleaveByChannel(lists: Array<Array<VideoItem>>, limit: number): Array<VideoItem> {
    const out: Array<VideoItem> = [];
    let index = 0;
    while (out.length < limit) {
      let progressed = false;
      for (let i = 0; i < lists.length; i++) {
        if (index < lists[i].length) {
          out.push(lists[i][index]);
          progressed = true;
        }
        if (out.length >= limit) {
          break;
        }
      }
      if (!progressed) {
        break;
      }
      index += 1;
    }
    return out;
  }

  /**
   * 一页 feed 按 `isShort` 拆成两份：长视频列表 + 短视频列表，**不做任何去重/过滤**
   * —— 服务端推什么就显示什么。
   *
   * 两份列表来自**同一次请求**（首页 feed 的 Shorts 货架就在里面），所以切换
   * 维度不需要重新请求；短视频那份的作者分布也跟首页一致（多作者），不会
   * 出现"整页都是同一个频道"。
   */
  private splitByType(items: VideoItem[]): HomeFeedSplit {
    const long: VideoItem[] = [];
    const short: VideoItem[] = [];
    for (let i = 0; i < items.length; i++) {
      const item = items[i];
      if (item.isShort === true) {
        short.push(item);
      } else {
        long.push(item);
      }
    }
    const session = AuthSessionManager.getInstance();
    const rail = session ? (session.preferredUserDataRail() || 'none') : 'none';
    const signedIn = !!session && session.isAuthEnabledForUserData() === true;
    logger.info(`[HomeFeed] stage=split long=${long.length} short=${short.length} `
      + `in=${items.length} auth=${signedIn ? 'on' : 'off'} rail=${rail} `
      + `feedback=${FeedFeedbackStore.summary()}`);
    return { long: long, short: short };
  }

  /**
   * 「不感兴趣 / 不推荐该频道」服务端反馈成功后，把卡片从当前首页列表即时摘掉
   * ——和网页一致（网页也是本地先消失，服务端随后不再推）。频道反馈要连同这一批里
   * 同频道的所有卡片一起摘。这里**不落地任何屏蔽名单**：服务端没记住的话，
   * 下次刷新自然会再出现，那是真实结果，不是客户端在偷偷过滤。
   */
  private removeFeedbackCards(videoId: string, channelId: string): void {
    const keep = (item: VideoItem): boolean => {
      if (videoId.length > 0 && item.videoId === videoId) {
        return false;
      }
      if (channelId.length > 0 && (item.channelId || '') === channelId) {
        return false;
      }
      return true;
    };
    const before = this.longList.length + this.shortList.length;
    const nextLong = this.longList.filter(keep);
    const nextShort = this.shortList.filter(keep);
    if (nextLong.length === this.longList.length && nextShort.length === this.shortList.length) {
      return;
    }
    this.longList = nextLong;
    this.shortList = nextShort;
    this.syncHomeFeedDataSource();
    logger.info(`[HomeFeed] stage=feedback_remove before=${before} `
      + `after=${this.longList.length + this.shortList.length} videoId=${videoId} channelId=${channelId}`);
  }

  /** 当前维度（'long' | 'short'）。 */
  private isShortMode(): boolean {
    return this.uiConfig.homeFeedMode === 'short';
  }

  /** 当前维度对应的列表。 */
  private activeList(): VideoItem[] {
    return this.isShortMode() ? this.shortList : this.longList;
  }

  /**
   * 短视频补收：**只从首页那份混合 feed 里收**（长视频 + 短视频本来就混在一页里）。
   *
   * 首页 feed 的 Shorts 货架位置不固定（有时在首屏、有时要往后翻几页才碰到），
   * 所以短视频维度下会自动多翻几页，把里面的短视频收进 `shortList`。
   *
   * 不用泛搜索（搜 "shorts" 的关键词结果）补货 —— 那些内容跟账号无关，
   * 混进来会破坏"短视频列表 = 我的 feed 里的短视频"这个语义。
   */
  private async harvestShortsFromFeed(): Promise<void> {
    if (this.shortsHarvestInFlight) {
      return;
    }
    this.shortsHarvestInFlight = true;
    const startedAt = Date.now();
    let pages = 0;
    try {
      for (let i = 0; i < HOME_SHORTS_HARVEST_PAGES; i++) {
        if (this.shortList.length >= HOME_SHORTS_HARVEST_TARGET) {
          break;
        }
        // 等当前分页请求结束再要下一页（loadLiveVideos 对并发请求会直接返回）。
        await this.feedLoadInFlight;
        if (!this.kioskNextPageToken) {
          // feed 翻到头了（YouTube 的推荐流 continuation 是有限的）→ 换成
          // 「我的频道」的 /shorts 标签页续上（见 topUpShortsFromChannels）。
          await this.topUpShortsFromChannels();
          break;
        }
        const before = this.shortList.length;
        await this.loadLiveVideos(false);
        pages += 1;
        if (this.shortList.length > before) {
          // 这一页带出了短视频（Shorts 货架找到了）→ 不用再往后翻。
          break;
        }
      }
      logger.info(`[HomeFeed] stage=shorts_harvest short=${this.shortList.length} `
        + `pages=${pages} elapsed=${Date.now() - startedAt}ms`);
    } catch (e) {
      logger.warn(`[HomeFeed] stage=shorts_harvest_failed ${this.describeThrowable(e)}`);
    } finally {
      this.shortsHarvestInFlight = false;
    }
  }

  /** 首页列表数据（过滤 banner 后）→ LazyForEach 数据源；追加=增量，reset=全量刷新 */
  private syncHomeFeedDataSource(): void {
    this.homeFeedDataSource.setData(this.getHomeListVideos(), (item: Object) => this.homeListItemKey(item as VideoItem));
  }

  /** Safe one-line error for hilog / exported app logs (Error → not "{}"). */
  private describeThrowable(err: Object | Error | string | undefined | null): string {
    if (err === undefined || err === null) {
      return 'error=null';
    }
    if (typeof err === 'string') {
      return `error=${err}`;
    }
    if (err instanceof Error) {
      const name = err.name || 'Error';
      const msg = err.message || '';
      return `name=${name} message=${msg}`;
    }
    if (typeof err === 'object') {
      const anyErr = err as Record<string, Object>;
      const parts: string[] = [];
      const name = anyErr['name'];
      const message = anyErr['message'];
      const code = anyErr['code'];
      const errorType = anyErr['errorType'];
      const url = anyErr['url'];
      const method = anyErr['method'];
      if (typeof name === 'string' && name.length > 0) {
        parts.push(`name=${name}`);
      }
      if (typeof message === 'string' && message.length > 0) {
        parts.push(`message=${message}`);
      }
      if (typeof code === 'number' || typeof code === 'string') {
        parts.push(`code=${String(code)}`);
      }
      if (typeof errorType === 'string' && errorType.length > 0) {
        parts.push(`errorType=${errorType}`);
      }
      if (typeof method === 'string' && method.length > 0) {
        parts.push(`method=${method}`);
      }
      if (typeof url === 'string' && url.length > 0) {
        // Host+path only — no query/cookies.
        const m = /^(https?:\/\/[^/?#]+)([^?#]*)/.exec(url);
        parts.push(`target=${m ? `${m[1]}${m[2] || '/'}` : '(url)'}`);
      }
      if (parts.length > 0) {
        return parts.join(' ');
      }
      try {
        const raw = JSON.stringify(err);
        if (raw && raw !== '{}' && raw !== 'null') {
          return `error=${raw}`;
        }
      } catch (_e) {
        // ignore
      }
    }
    return `error=${String(err)}`;
  }

  private formatHomeRequestError(err: Object, fallback: string): string {
    let code = '';
    let message = '';
    if (err instanceof Error) {
      message = err.message || '';
      const name = err.name || '';
      if (name.length > 0 && name !== 'Error') {
        code = name;
      }
    } else if (err && typeof err === 'object') {
      const anyErr = err as Record<string, Object>;
      const errorCode = anyErr['code'];
      const errorMessage = anyErr['message'];
      const errorType = anyErr['errorType'];
      if (typeof errorCode === 'number' || typeof errorCode === 'string') {
        code = String(errorCode);
      } else if (typeof errorType === 'string' && errorType.length > 0) {
        code = errorType;
      }
      if (typeof errorMessage === 'string') {
        message = errorMessage;
      }
    }
    if (!message || message.length === 0) {
      message = fallback;
    }
    // HomeFeedService 的空内容哨兵（"Empty live kiosk feed…" / "Empty recommended feed" /
    // "Empty browse response…"）是给日志看的英文，不该直接甩给用户。
    if (/^Empty\b/.test(message)) {
      return fallback;
    }
    return code.length > 0 ? `[${code}] ${message}` : message;
  }

  private gridColumns(): number {
    return getVideoGridColumnCount(getFeedContentWidthVp(this.getUIContext(), this.deviceWidth),
      UIConfig.gridDensityOffset(this.uiConfig.homeGridDensity));
  }

  private shouldShowHomeRecommendBanner(): boolean {
    // Dual-rail sources: recommended | recommended-web | recommended-tv
    return this.homeMode === 'kiosk'
      && this.homeFeedSource.indexOf('recommended') === 0
      && !this.isShortMode()
      && this.longList.length > 0;
  }

  private getHomeBannerVideos(): VideoItem[] {
    if (!this.shouldShowHomeRecommendBanner()) {
      return [];
    }
    const limit = Math.min(this.homeBannerMax, this.longList.length);
    return this.longList.slice(0, limit);
  }

  private getHomeListVideos(): VideoItem[] {
    const list = this.activeList();
    if (!this.shouldShowHomeRecommendBanner()) {
      return list;
    }
    const bannerIds: string[] = [];
    const banners = this.getHomeBannerVideos();
    for (let i = 0; i < banners.length; i++) {
      const id = (banners[i].videoId || banners[i].id.toString()).trim();
      if (id.length > 0) {
        bannerIds.push(id);
      }
    }
    return list.filter((item: VideoItem) => {
      const id = (item.videoId || item.id.toString()).trim();
      return bannerIds.indexOf(id) < 0;
    });
  }

  @LocalBuilder
  HomeVideoGridCard(slot: MediaFeedItemSlot) {
    VideoCardGrid({
      video: slot.item as VideoItem,
      showFeedbackActions: true
    })
  }

  /** 条式卡片：卡片左右 12vp 内边距按原行为在卡片侧（banner 不被内缩） */
  @LocalBuilder
  HomeVideoListCard(slot: MediaFeedItemSlot) {
    Column() {
      VideoCard({
        video: slot.item as VideoItem,
        showFeedbackActions: true
      })
    }
    .padding({ left: 12, right: 12 })
  }

  /**
   * 游客态：没有可用凭据，或凭据总开关被关掉（此时首页拿的就是匿名 kiosk）。
   * 浏览与播放本身不需要登录，需要登录的是个性化推荐、稍后观看、订阅云同步
   * 和「不感兴趣」反馈，所以提示只讲这几项。
   */
  private isGuestBrowse(): boolean {
    const hasCredential = this.authStatus.hasCredential
      || this.authStatus.hasCookieCredential
      || this.authStatus.hasRefreshToken
      || this.authStatus.stage === AuthStage.SIGNED_IN;
    return !hasCredential || this.authStatus.authEnabled === false;
  }

  /**
   * 短视频维度空列表时的说明：这一维度只吃「首页 feed 里的 Shorts 货架」和
   * 「订阅 / 看过频道的 /shorts」两条腿，游客或没订过频道的人两条腿都是空的，
   * 不给文案就是一片纯空白。长视频维度不显示（几乎不会空，空了也有错误页兜）。
   */
  private homeEmptyHint(): ResourceStr {
    if (this.isShortMode()) {
      return $r('app.string.yt_home_shorts_empty');
    }
    return '';
  }

  /** 推荐位 banner：grid 模式经 headerHorizontalBleed 抵消容器左右 12vp 内边距保持全宽；底部间距补齐到原 12vp */
  @LocalBuilder
  HomeBannerHeader() {
    HomeRecommendSwiper({
      videos: this.getHomeBannerVideos(),
      feedEpoch: this.homeFeedEpoch
    })
      .padding({ bottom: this.uiConfig.homeLayoutMode === 'grid' ? 4 : 8 })
      // 插入-only 转场：禁止删除方向缩放（Grid 骨架切换/hasHeader 翻转时不再播"缩小消失"幽灵）
      .transition(customAnimationUtil.isScaleTranEnter(`home_recommend_banner_${this.homeFeedEpoch}`, this.uiConfig))
  }

  @Builder LoadingBuilder() {
    LoadingProgress()
      .color(this.themePrimary)
      .width(40)
      .height(40)
      .margin({ bottom: 15 })
  }

  build() {
    Stack() {
      if (this.homeErrorMessage.length > 0 && this.activeList().length === 0) {
        // 显示完整页面的错误页面
        if (this.isGuestBrowse()) {
          // 游客：匿名内容源被服务端挡掉时报错最常见，主按钮直接给「去登录」，
          // 「重试」降成描边次按钮（错误页会整屏替换 Refresh，下拉刷新此时不可用，必须留着）。
          ErrorPage({
            errorMessage: this.homeErrorMessage,
            onRetry: () => {
              this.loadLiveVideos(true);
            },
            altActionText: $r('app.string.yt_home_guest_notice_action'),
            onAltAction: () => {
              logger.info('home error page go login tapped');
              this.onOpenLoginClick();
            }
          })
        } else {
          ErrorPage({
            errorMessage: this.homeErrorMessage,
            onRetry: () => {
              this.loadLiveVideos(true);
            }
          })
        }
      } else {
        Refresh({ refreshing: $$this.isHomeRefreshing }) {
          Column() {
          if (this.isGuestBrowse()) {
            Row({ space: 8 }) {
              Text($r('app.string.yt_home_guest_notice'))
                .fontSize(12)
                .fontColor($r('app.color.yourtube_text_hint'))
                .lineHeight(17)
                .layoutWeight(1)
              Text($r('app.string.yt_home_guest_notice_action'))
                .fontSize(12)
                .fontColor(this.themePrimary)
                .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                .onClick(() => {
                  logger.info('home guest notice open login tapped');
                  this.onOpenLoginClick();
                })
            }
            .width('100%')
            .padding({ left: 16, right: 12 })
            .margin({ top: 8 })
          }

          if (this.homeModeNoticeMessage.length > 0) {
            Text(this.homeModeNoticeMessage)
              .fontSize(12)
              .fontColor(this.themePrimary)
              .margin({ top: 8, left: 16, right: 16 })
          }

          MediaVideoFeed({
            dataSource: this.homeFeedDataSource,
            gridScroller: this.controller.gridScroller,
            listScroller: this.controller.listScroller,
            itemKey: (item: Object) => this.homeListItemKey(item as VideoItem),
            gridItemBuilder: this.HomeVideoGridCard,
            itemBuilder: this.HomeVideoListCard,
            headerBuilder: this.HomeBannerHeader,
            onReachEnd: () => {
              this.loadLiveVideos(false);
              // 短视频维度：往后再翻几页混合 feed，把里面的短视频收进来。
              if (this.isShortMode()) {
                this.harvestShortsFromFeed().catch(() => undefined);
              }
            },
            params: {
              layoutPreference: this.uiConfig.homeLayoutMode,
              gridColumns: this.gridColumns(),
              // 首页条式恒单列（无宽列分支）
              listColumns: 1,
              isLoading: false,
              // 原网格分支无加载更多 footer，保持不显示
              isLoadingMore: this.uiConfig.homeLayoutMode === 'grid' ? false : this.isLoadingMore,
              errorMessage: '',
              emptyText: this.homeEmptyHint(),
              hasHeader: this.shouldShowHomeRecommendBanner(),
              headerHorizontalBleed: 12,
              gridContentPadding: { left: 12, right: 12, bottom: this.safeAreaBottom + 72 },
              listContentEndOffset: this.safeAreaBottom + 72,
              // 空列表也保持可滚动（下拉刷新可用）
              stateScrollable: true,
              // 上方有 homeModeNoticeMessage 兄弟节点
              useLayoutWeight: true,
              // 原首页两个分支均为 clip(false) 且未显式关滚动条
              clipContent: false,
              scrollBarOff: false
            }
          })
          }
          .width('100%')
          .height('100%')
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ top: this.safeAreaTop + 56 })
        .pullToRefresh(true)
        .refreshOffset(64)
        .onRefreshing(() => {
          this.refreshHomeFeed();
        })
      }

      if (this.isInitialLoading) {
        Column() {
          this.LoadingBuilder()
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor($r('app.color.yourtube_bg_overlay'))
      }
    }
  }
}
