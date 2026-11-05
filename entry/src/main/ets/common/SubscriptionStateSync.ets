import { AuthSessionManager } from 'youtube_core';
import { AppLog } from './AppLog';
import { FeedServiceProvider } from './FeedServiceProvider';
import { LocalStore } from './LocalStore';
import { SubscriptionUser } from './SubscriptionModel';

const logger = AppLog.getInstance('SubscriptionStateSync');

/**
 * 两次云端名单核对的最小间隔。只是防抖（进播放页→点频道名→进主页会连发三次），
 * 不是缓存 —— 用户期望每次触及这些入口都真去查一遍，所以保持很短。
 */
const SYNC_TTL_MS: number = 5000;
/** 本地刚改过订阅后服务端传播有延迟，这段时间内只做加法核对、不做删除核对。 */
const LOCAL_MUTATION_GRACE_MS: number = 30000;

export interface SubscriptionSyncResult {
  skipped: boolean;
  skipReason: string;
  removed: number;
  added: number;
  /** 本轮拉到的云端名单条数（未拉到为 0）。 */
  cloud: number;
}

function skipResult(reason: string): SubscriptionSyncResult {
  return { skipped: true, skipReason: reason, removed: 0, added: 0, cloud: 0 };
}

function mergeSubscription(local: SubscriptionUser, cloud: SubscriptionUser): SubscriptionUser {
  return new SubscriptionUser(
    cloud.channelId,
    local.displayName || cloud.displayName,
    cloud.avatarUrl || local.avatarUrl,
    cloud.subscriberText || local.subscriberText,
    local.videoCountText || cloud.videoCountText,
    local.description || cloud.description,
    local.thumbnailColor || cloud.thumbnailColor,
    true
  );
}

/**
 * 订阅状态的云端权威核对：网页端退订后，本地列表要在用户下次触及
 * 订阅页 / 播放页频道行 / 频道主页时收敛，而不是永远显示「已订阅」。
 */
export class SubscriptionStateSync {
  private static instance: SubscriptionStateSync | null = null;
  private lastSyncAt: number = 0;
  private lastLocalMutationAt: number = 0;
  private inFlight: Promise<SubscriptionSyncResult> | null = null;

  static getInstance(): SubscriptionStateSync {
    if (!SubscriptionStateSync.instance) {
      SubscriptionStateSync.instance = new SubscriptionStateSync();
    }
    return SubscriptionStateSync.instance;
  }

  /** Index 里订阅/退订写回成功后调用：刚改过的条目不参与本轮删除。 */
  markLocalMutation(): void {
    this.lastLocalMutationAt = Date.now();
  }

  /** 登录态变化 / 退出账号后重新计时，避免用旧账号的名单。 */
  reset(): void {
    this.lastSyncAt = 0;
    this.lastLocalMutationAt = 0;
    this.inFlight = null;
  }

  async sync(reason: string, force: boolean = false): Promise<SubscriptionSyncResult> {
    if (AuthSessionManager.getInstance()?.hasAuthForUserData() !== true) {
      return skipResult('signed_out');
    }
    const now = Date.now();
    if (!force && now - this.lastSyncAt < SYNC_TTL_MS) {
      return skipResult('throttled');
    }
    if (this.inFlight) {
      return this.inFlight;
    }
    const task = this.run(reason, now);
    this.inFlight = task;
    try {
      return await task;
    } finally {
      this.inFlight = null;
    }
  }

  /** 触发但不等待：UI 入口用它，核对结果通过 AppStorage('subscriptions') 回流刷新列表。 */
  syncInBackground(reason: string, force: boolean = false): void {
    this.sync(reason, force).then((result: SubscriptionSyncResult) => {
      if (result.skipped) {
        logger.info(`[SubVerify] stage=skip reason=${result.skipReason} trigger=${reason}`);
        return;
      }
      logger.info(`[SubVerify] stage=done trigger=${reason} removed=${result.removed} added=${result.added}`);
    }).catch((err: Object) => {
      logger.warn(`[SubVerify] stage=failed trigger=${reason} error=${JSON.stringify(err)}`);
    });
  }

  private async run(reason: string, startedAt: number): Promise<SubscriptionSyncResult> {
    const snapshot = await FeedServiceProvider.getInstance()
      .getUserLibraryService()
      .fetchSubscribedChannelsSnapshot();
    this.lastSyncAt = startedAt;
    if (snapshot.channels.length === 0) {
      // 空名单更可能是风控/解析失败，不能当成「云端全退光」。
      return skipResult('cloud_empty');
    }
    const pruneAllowed = snapshot.complete && (startedAt - this.lastLocalMutationAt > LOCAL_MUTATION_GRACE_MS);
    const local = AppStorage.get<SubscriptionUser[]>('subscriptions') ?? [];
    const cloudById: Record<string, SubscriptionUser> = {};
    snapshot.channels.forEach((item: SubscriptionUser) => {
      cloudById[item.channelId] = item;
    });
    const localById: Record<string, boolean> = {};
    local.forEach((item: SubscriptionUser) => {
      localById[item.channelId] = true;
    });

    const next: SubscriptionUser[] = [];
    let removed = 0;
    let changed = false;
    local.forEach((item: SubscriptionUser) => {
      const cloud: SubscriptionUser | undefined = cloudById[item.channelId];
      if (cloud) {
        const merged = mergeSubscription(item, cloud);
        if (!item.fromCloud || merged.avatarUrl !== item.avatarUrl || merged.subscriberText !== item.subscriberText) {
          changed = true;
        }
        next.push(merged);
        return;
      }
      if (pruneAllowed && item.fromCloud) {
        removed += 1;
        return;
      }
      next.push(item);
    });

    let added = 0;
    snapshot.channels.forEach((item: SubscriptionUser) => {
      if (!localById[item.channelId]) {
        added += 1;
        next.push(item);
      }
    });

    if (removed > 0 || added > 0 || changed) {
      AppStorage.setOrCreate('subscriptions', next);
      LocalStore.persistSubscriptions();
    }
    logger.info(`[SubVerify] stage=reconcile trigger=${reason} cloud=${snapshot.channels.length} local=${local.length} removed=${removed} added=${added} complete=${snapshot.complete} prune=${pruneAllowed} result=${next.length}`);
    return { skipped: false, skipReason: '', removed, added, cloud: snapshot.channels.length };
  }
}
