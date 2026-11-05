import { AuthExpiredError, AuthSessionManager, VideoItem } from 'youtube_core';
import {
  ContentCountry,
  Localization,
  fetchBrowseContinuation,
  fetchBrowsePage,
  fetchTvBrowseContinuation,
  fetchTvBrowsePage
} from 'youtube_core';
import { AppLog } from '../../common/AppLog';
import { buildHomeKioskVideoItems, getHomeFeedItemsFromTabContent } from './utils/HomeFeedUtils';
import { buildTvBrowseVideoItems, getTvVisitorData } from './utils/TvBrowseUtils';

const logger = AppLog.getInstance('HomeFeedService');

export interface KioskPageResult {
  items: Array<VideoItem>;
  nextPageToken: string | null;
  visitorData: string;
  source: string;
}

export class HomeFeedService {
  private localization: Localization;
  private contentCountry: ContentCountry;
  private readonly KIOSK_BROWSE_ID: string = 'UC4R8DWoMoI7CAwX8_LjQHig';
  private readonly KIOSK_PARAMS: string = 'EgdsaXZldGFikgEDCKEK';
  private readonly RECOMMENDED_BROWSE_ID: string = 'FEwhat_to_watch';
  /** SmartTube TV home browseId. */
  private readonly TV_HOME_BROWSE_ID: string = 'default';

  constructor(localization: Localization, contentCountry: ContentCountry) {
    this.localization = localization;
    this.contentCountry = contentCountry;
  }

  /**
   * @param style 'recommended' | 'kiosk' — only applies when signed in.
   *              Signed-out always uses live kiosk.
   *              recommended failure falls back to the guest kiosk; an
   *              AuthExpiredError is reported via AuthSessionManager.noteAuthRejection.
   * Rails: WEB Cookie → FEwhat_to_watch; OAuth-only → TV browseId=default; else kiosk.
   */
  async fetchHomeKioskInitial(startId: number, style: string = 'recommended'): Promise<KioskPageResult> {
    const session = AuthSessionManager.getInstance();
    const rail = style !== 'kiosk' ? (session?.preferredUserDataRail() || 'none') : 'none';
    const startedAt = Date.now();
    logger.info(`[HomeFeed] stage=initial_start style=${style} rail=${rail}`);

    if (rail === 'web') {
      try {
        const recommended = await this.fetchWebBrowseSource(
          this.RECOMMENDED_BROWSE_ID,
          '',
          true,
          startId,
          'recommended-web'
        );
        if (recommended.items.length === 0) {
          throw new Error('Empty recommended feed');
        }
        logger.info(`[HomeFeed] stage=initial_done source=recommended-web items=${recommended.items.length} `
          + `elapsed=${Date.now() - startedAt}ms hasNext=${!!recommended.nextPageToken}`);
        return recommended;
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        if (e instanceof AuthExpiredError) {
          session?.noteAuthRejection('web', 'browse-rejected');
        }
        logger.warn(`[HomeFeed] stage=initial_failed source=recommended-web `
          + `elapsed=${Date.now() - startedAt}ms message=${msg} — falling back to kiosk`);
      }
    }

    if (rail === 'tv') {
      try {
        const tvHome = await this.fetchTvHomeSource(startId);
        if (tvHome.items.length === 0) {
          throw new Error('Empty TV recommended feed');
        }
        logger.info(`[HomeFeed] stage=initial_done source=recommended-tv items=${tvHome.items.length} `
          + `elapsed=${Date.now() - startedAt}ms hasNext=${!!tvHome.nextPageToken}`);
        return tvHome;
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        if (e instanceof AuthExpiredError) {
          session?.noteAuthRejection('tv', 'browse-rejected');
        }
        logger.warn(`[HomeFeed] stage=initial_failed source=recommended-tv `
          + `elapsed=${Date.now() - startedAt}ms message=${msg} — falling back to kiosk`);
      }
    }

    if (style === 'recommended' && session?.isAuthEnabledForUserData() === true) {
      logger.warn('[HomeFeed] recommended requested but no WEB/TV credential — using live kiosk');
    }

    // 游客默认拿匿名 WEB 首页（普通视频流，可能带 Shorts 货架）；
    // 直播 kiosk 只是兜底，否则首页会是一整屏直播、短视频维度直接空。
    if (rail === 'none' && style === 'recommended') {
      try {
        const guestHome = await this.fetchWebBrowseSource(
          this.RECOMMENDED_BROWSE_ID,
          '',
          false,
          startId,
          'guest-home'
        );
        if (guestHome.items.length > 0) {
          logger.info(`[HomeFeed] stage=initial_done source=guest-home items=${guestHome.items.length} `
            + `elapsed=${Date.now() - startedAt}ms hasNext=${!!guestHome.nextPageToken}`);
          return guestHome;
        }
        logger.warn(`[HomeFeed] stage=initial_empty source=guest-home `
          + `elapsed=${Date.now() - startedAt}ms — trying anonymous TV home`);
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        logger.warn(`[HomeFeed] stage=initial_failed source=guest-home `
          + `elapsed=${Date.now() - startedAt}ms message=${msg} — trying anonymous TV home`);
      }

      // ② 匿名 TV 首页：游客没有 WEB 推荐流时，SmartTube 那一套仍能给出普通视频。
      try {
        const tvGuest = await this.fetchTvHomeSource(startId, false, 'guest-tv');
        if (tvGuest.items.length > 0) {
          logger.info(`[HomeFeed] stage=initial_done source=guest-tv items=${tvGuest.items.length} `
            + `elapsed=${Date.now() - startedAt}ms hasNext=${!!tvGuest.nextPageToken}`);
          return tvGuest;
        }
        logger.warn(`[HomeFeed] stage=initial_empty source=guest-tv `
          + `elapsed=${Date.now() - startedAt}ms — falling back to live kiosk`);
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        logger.warn(`[HomeFeed] stage=initial_failed source=guest-tv `
          + `elapsed=${Date.now() - startedAt}ms message=${msg} — falling back to live kiosk`);
      }
    }

    // ③ 直播 kiosk（上游原有的游客源）。空列表必须报错：
    // 静默返回空会让首页变成一片空白，用户既不知道失败了也没法重试。
    try {
      const kiosk = await this.fetchWebBrowseSource(
        this.KIOSK_BROWSE_ID,
        this.KIOSK_PARAMS,
        false,
        startId,
        'kiosk'
      );
      if (kiosk.items.length === 0) {
        throw new Error('Empty live kiosk feed (browse returned no video items)');
      }
      logger.info(`[HomeFeed] stage=initial_done source=kiosk items=${kiosk.items.length} `
        + `elapsed=${Date.now() - startedAt}ms hasNext=${!!kiosk.nextPageToken}`);
      return kiosk;
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      logger.error(`[HomeFeed] stage=initial_failed source=kiosk `
        + `elapsed=${Date.now() - startedAt}ms message=${msg}`);
      throw e instanceof Error ? e : new Error(msg);
    }
  }

  /**
   * Continuation for home feed. sourceRail is inferred from withAuth + credentials,
   * or callers may pass previous source via withAuth + homeFeedSource encoding:
   * Index uses withAuth when homeFeedSource starts with recommended.
   */
  async fetchHomeKioskNext(
    nextPageToken: string,
    visitorData: string,
    startId: number,
    withAuth: boolean = false,
    previousSource: string = ''
  ): Promise<KioskPageResult> {
    const session = AuthSessionManager.getInstance();
    const startedAt = Date.now();
    const sourceHint = previousSource.length > 0 ? previousSource : '';
    const useTv = sourceHint === 'recommended-tv' || sourceHint === 'guest-tv'
      || (withAuth && session?.hasTvAuthForUserData() === true
        && session?.hasCookieAuthForUserData() !== true);
    const useWebAuth = withAuth
      && session?.isAuthEnabledForUserData() === true
      && session?.hasCookieAuthForUserData() === true
      && !useTv;

    logger.info(`[HomeFeed] stage=next_start tv=${useTv} webAuth=${useWebAuth} `
      + `tokenLen=${nextPageToken.length} hint=${sourceHint}`);

    try {
      if (useTv) {
        const response = await fetchTvBrowseContinuation(
          this.localization,
          this.contentCountry,
          nextPageToken,
          visitorData,
          sourceHint !== 'guest-tv'
        );
        if (!response) {
          throw new Error('Empty TV browse continuation response');
        }
        const built = buildTvBrowseVideoItems(response as Record<string, Object>, startId);
        const result: KioskPageResult = {
          items: built.items,
          nextPageToken: built.nextPageToken,
          visitorData: getTvVisitorData(response as Record<string, Object>) || visitorData,
          source: sourceHint === 'guest-tv' ? 'guest-tv' : 'recommended-tv'
        };
        logger.info(`[HomeFeed] stage=next_done source=${result.source} items=${result.items.length} `
          + `elapsed=${Date.now() - startedAt}ms hasNext=${!!result.nextPageToken}`);
        return result;
      }

      const response = await fetchBrowseContinuation(
        this.localization,
        this.contentCountry,
        nextPageToken,
        visitorData,
        useWebAuth
      );
      if (!response) {
        throw new Error('Empty browse continuation response');
      }
      const parsed = this.parseHomeBrowseContinuationResponse(
        response as Record<string, Object>,
        visitorData,
        startId
      );
      parsed.source = useWebAuth ? 'recommended-web'
        : (sourceHint === 'guest-home' ? 'guest-home' : 'kiosk');
      logger.info(`[HomeFeed] stage=next_done source=${parsed.source} items=${parsed.items.length} `
        + `elapsed=${Date.now() - startedAt}ms hasNext=${!!parsed.nextPageToken}`);
      return parsed;
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      logger.error(`[HomeFeed] stage=next_failed `
        + `elapsed=${Date.now() - startedAt}ms message=${msg}`);
      throw e instanceof Error ? e : new Error(msg);
    }
  }

  private async fetchTvHomeSource(startId: number, withAuth: boolean = true,
    source: string = 'recommended-tv'): Promise<KioskPageResult> {
    const startedAt = Date.now();
    logger.info(`[HomeFeed] stage=browse_start source=${source} browseId=${this.TV_HOME_BROWSE_ID} `
      + `withAuth=${withAuth}`);
    const response = await fetchTvBrowsePage(
      this.localization,
      this.contentCountry,
      this.TV_HOME_BROWSE_ID,
      '',
      undefined,
      withAuth
    );
    if (!response) {
      throw new Error(`Empty TV browse response browseId=default withAuth=${withAuth}`);
    }
    const resp = response as Record<string, Object>;
    const error = resp['error'] as Record<string, Object>;
    if (error) {
      throw new Error(`TV browse error: ${JSON.stringify(error)}`);
    }
    const built = buildTvBrowseVideoItems(resp, startId);
    if (built.items.length === 0) {
      const keys = Object.keys(resp).join(',');
      const contents = resp['contents'] as Record<string, Object>;
      const contentKeys = contents ? Object.keys(contents).join(',') : '(none)';
      const tvBrowse = contents ? (contents['tvBrowseRenderer'] as Record<string, Object>) : undefined;
      const tvContent = tvBrowse ? (tvBrowse['content'] as Record<string, Object>) : undefined;
      const tvContentKeys = tvContent ? Object.keys(tvContent).join(',') : '(none)';
      const err = resp['error'] as Record<string, Object>;
      logger.warn(`[HomeFeed] stage=browse_empty source=${source} topKeys=${keys} `
        + `contentsKeys=${contentKeys} tvContentKeys=${tvContentKeys} hasError=${!!err}`);
    }
    logger.info(`[HomeFeed] stage=browse_parsed source=${source} items=${built.items.length} `
      + `elapsed=${Date.now() - startedAt}ms`);
    return {
      items: built.items,
      nextPageToken: built.nextPageToken,
      visitorData: getTvVisitorData(resp),
      source
    };
  }

  private async fetchWebBrowseSource(
    browseId: string,
    params: string,
    withAuth: boolean,
    startId: number,
    source: string
  ): Promise<KioskPageResult> {
    const startedAt = Date.now();
    logger.info(`[HomeFeed] stage=browse_start source=${source} browseId=${browseId} withAuth=${withAuth}`);
    const response = await fetchBrowsePage(
      this.localization,
      this.contentCountry,
      browseId,
      params,
      undefined,
      withAuth
    );
    if (!response) {
      throw new Error(`Empty browse response source=${source} browseId=${browseId}`);
    }
    const parsed = this.parseHomeBrowseInitialResponse(response as Record<string, Object>, startId);
    parsed.source = source;
    if (parsed.items.length === 0) {
      // 结构诊断：游客拿到 200 但解析不出条目时（登录墙 / 机器人校验 / 结构改版），
      // 只靠 items=0 无法定位，这里把响应形状打进日志。
      const resp = response as Record<string, Object>;
      const contents = resp['contents'] as Record<string, Object>;
      const alerts = resp['alerts'] as Array<Object>;
      const err = resp['error'] as Record<string, Object>;
      logger.warn(`[HomeFeed] stage=browse_empty source=${source} `
        + `topKeys=${Object.keys(resp).join(',')} contentsKeys=${contents ? Object.keys(contents).join(',') : '(none)'} `
        + `alerts=${alerts ? alerts.length : 0} hasError=${!!err} `
        + `responseKeys=${contents ? this.describeFirstContentKeys(contents) : '(none)'}`);
    }
    logger.info(`[HomeFeed] stage=browse_parsed source=${source} items=${parsed.items.length} `
      + `elapsed=${Date.now() - startedAt}ms`);
    return parsed;
  }

  private describeFirstContentKeys(contents: Record<string, Object>): string {
    const twoColumn = contents['twoColumnBrowseResultsRenderer'] as Record<string, Object>;
    const tabs = twoColumn ? (twoColumn['tabs'] as Array<Record<string, Object>>) : undefined;
    const tab0 = tabs && tabs.length > 0 ? tabs[0] : undefined;
    const tabRenderer = tab0 ? (tab0['tabRenderer'] as Record<string, Object>) : undefined;
    const tabContent = tabRenderer ? (tabRenderer['content'] as Record<string, Object>) : undefined;
    return tabContent ? Object.keys(tabContent).join(',') : '(no tabRenderer)';
  }

  private parseHomeBrowseInitialResponse(response: Record<string, Object>, startId: number): KioskPageResult {
    const responseContext = response['responseContext'] as Record<string, Object>;
    const visitorData = (responseContext ? (responseContext['visitorData'] as string) : '') || '';

    const contents = response['contents'] as Record<string, Object>;
    const twoColumn = contents ? (contents['twoColumnBrowseResultsRenderer'] as Record<string, Object>) : undefined;
    const tabs = twoColumn ? (twoColumn['tabs'] as Array<Record<string, Object>>) : undefined;
    const tab0 = tabs && tabs.length > 0 ? tabs[0] : undefined;
    const tabRenderer = tab0 ? (tab0['tabRenderer'] as Record<string, Object>) : undefined;
    let tabContent = tabRenderer ? (tabRenderer['content'] as Record<string, Object>) : undefined;

    if (!tabContent && contents) {
      tabContent = contents;
    }

    const rawItems: Array<Record<string, Object>> = getHomeFeedItemsFromTabContent(tabContent);
    const built = buildHomeKioskVideoItems(rawItems, startId, 'LIVE');
    return {
      items: built.items,
      nextPageToken: built.nextPageToken,
      visitorData,
      source: 'kiosk'
    };
  }

  private parseHomeBrowseContinuationResponse(
    response: Record<string, Object>,
    visitorData: string,
    startId: number
  ): KioskPageResult {
    let items: Array<VideoItem> = [];
    let nextPageToken: string | null = null;

    const actions = response['onResponseReceivedActions'] as Array<Record<string, Object>>;
    if (actions && actions.length > 0) {
      actions.forEach((action) => {
        const append = action['appendContinuationItemsAction'] as Record<string, Object>;
        const continuationItems = append ? (append['continuationItems'] as Array<Record<string, Object>>) : undefined;
        if (!continuationItems || continuationItems.length === 0) {
          return;
        }
        const expanded = this.expandContinuationItems(continuationItems);
        const built = buildHomeKioskVideoItems(expanded, startId + items.length, 'LIVE');
        items = items.concat(built.items);
        nextPageToken = built.nextPageToken ?? nextPageToken;
      });
    }

    return { items, nextPageToken, visitorData, source: 'kiosk' };
  }

  private expandContinuationItems(items: Array<Record<string, Object>>): Array<Record<string, Object>> {
    const result: Array<Record<string, Object>> = [];
    items.forEach((item) => {
      const richSection = item['richSectionRenderer'] as Record<string, Object>;
      if (richSection) {
        const content = richSection['content'] as Record<string, Object>;
        const shelf = content ? (content['richShelfRenderer'] as Record<string, Object>) : undefined;
        const shelfContents = shelf ? (shelf['contents'] as Array<Record<string, Object>>) : undefined;
        if (shelfContents && shelfContents.length > 0) {
          shelfContents.forEach((c) => result.push(c));
          return;
        }
      }
      result.push(item);
    });
    return result;
  }
}
