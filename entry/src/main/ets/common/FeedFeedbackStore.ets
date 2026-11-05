import { AppLog } from './AppLog';

const logger = AppLog.getInstance('FeedFeedback');

/** 服务端反馈项：网页三点菜单里「不感兴趣 / 不推荐该频道」这类条目，标签和 token 都来自服务端。 */
export interface FeedFeedbackEntry {
  /** 服务端自带的条目文案（跟随请求 hl，已本地化）；缺失时为空串，由调用方兜底。 */
  label: string;
  /** 服务端下发的不透明 feedback token，只能原样提交给 Innertube `feedback`。 */
  token: string;
}

/** DFS 祖先链上的一跳：靠哪个键走进来的、以及那个父节点。找条目文案时往上回溯用。 */
interface AncestorHop {
  node: Record<string, Object>;
  key: string;
}

/** 单条视频最多保留几个反馈项（网页一般 2～4 条）。 */
const MAX_ENTRIES_PER_VIDEO: number = 6;
/** 内存里最多记多少条视频（首页一批 ≈60 条，留足余量；不落地，重启即清）。 */
const MAX_TRACKED_VIDEOS: number = 400;
/** 结构探测：每个 feed 批次最多探几条（一条完整结构就够判断）。 */
const MAX_PROBE_PER_BATCH: number = 1;
/**
 * 结构探测深度。
 *
 * 网页实测：单个卡片的「不感兴趣」token 落在
 * `lockupViewModel → metadata → lockupMetadataViewModel → menuButton → buttonViewModel
 *  → onTap → innertubeCommand → showSheetCommand → panelLoadingStrategy → inlineContent
 *  → sheetViewModel → content → listViewModel → listItems[] → listItemViewModel
 *  → rendererContext → commandContext → onTap → innertubeCommand → feedbackEndpoint → feedbackToken`
 * ——从条目节点起算 21 层。旧的 12 层限制会**在这条链的中途就停下**，于是
 * 「feed 里有 token 但扫不到」，长按菜单永远不显示这两项。深度必须容得下整条链。
 */
const MAX_WALK_DEPTH: number = 28;
const PROBE_MAX_DEPTH: number = MAX_WALK_DEPTH;
const PROBE_MAX_PATHS: number = 600;
/** 结构探测：每条日志最多带多少条路径、最多打多少行。 */
const PROBE_PATHS_PER_LINE: number = 8;
const PROBE_MAX_LINES: number = 14;

/** 条目文案可能藏身的直接子键。 */
const LABEL_KEYS: string[] = ['text', 'title', 'label', 'headline', 'content', 'simpleText'];
/**
 * 往祖先方向找条目文案最多回溯几层。
 * 网页结构里 `feedbackEndpoint` 到带 `title.content` 的 `listItemViewModel` 隔了 5 层，
 * 只查 parent/grandparent 会拿到空标签，两项菜单就只能显示本地兜底文案、分不清谁是谁。
 */
const LABEL_ANCESTOR_HOPS: number = 6;

/**
 * 首页 / 信息流条目的「服务端反馈项」缓存。
 *
 * 为什么要有这个：网页端「不感兴趣」「不推荐该频道」提交的是服务端在 feed 响应里
 * 一起下发的 `feedbackEndpoint.feedbackToken`（不透明 protobuf base64），客户端**无法自己构造**，
 * 只能原样回传。所以解析每页 feed 时把 token 连同它自己的条目文案记下来，
 * 长按菜单直接渲染服务端给的那几项，用户点哪条就提交哪条的 token —— 不做任何
 * 「按位置猜哪个是不感兴趣」的推断，也不落地本地屏蔽名单。
 *
 * 只存内存：token 只对当次 feed 有效，重启或重新拉取后自然作废。
 */
export class FeedFeedbackStore {
  private static entries: Map<string, FeedFeedbackEntry[]> = new Map();
  private static probeBudget: number = MAX_PROBE_PER_BATCH;

  /**
   * 扫一个 feed 条目节点（richItemRenderer / lockupViewModel / videoRenderer 这一层），
   * 找出它自己的 videoId 和它携带的反馈项。
   */
  static scanItemNode(node: Record<string, Object> | undefined): void {
    if (!node) {
      return;
    }
    const videoId = FeedFeedbackStore.findVideoId(node);
    if (videoId.length === 0) {
      // 只有一个键的容器节点（`{ richItemRenderer: … }` 这层套壳）本身不是条目，
      // 不需要探测结构，否则会把它刷进预算里。
      if (Object.keys(node).length > 1) {
        FeedFeedbackStore.probe(node, 'no_video_id');
      }
      return;
    }
    const found: FeedFeedbackEntry[] = [];
    const rootAncestors: AncestorHop[] = [];
    FeedFeedbackStore.walk(node, rootAncestors, found, 0);
    if (found.length === 0) {
      FeedFeedbackStore.probe(node, 'no_token');
      return;
    }
    const unique: FeedFeedbackEntry[] = [];
    for (let i = 0; i < found.length && unique.length < MAX_ENTRIES_PER_VIDEO; i++) {
      const candidate = found[i];
      let duplicated = false;
      for (let j = 0; j < unique.length; j++) {
        if (unique[j].token === candidate.token) {
          duplicated = true;
          break;
        }
      }
      if (!duplicated) {
        unique.push(candidate);
      }
    }
    if (FeedFeedbackStore.entries.size >= MAX_TRACKED_VIDEOS && !FeedFeedbackStore.entries.has(videoId)) {
      // 只当缓存用，超限时整表重建比逐个淘汰简单，也不会影响正确性。
      FeedFeedbackStore.entries.clear();
    }
    FeedFeedbackStore.entries.set(videoId, unique);
    logger.debug(`[FeedFeedback] stage=record videoId=${videoId} count=${unique.length} `
      + `labels=${unique.map((e: FeedFeedbackEntry): string => e.label.length > 0 ? e.label : '(none)').join('|')}`);
  }

  static entriesFor(videoId: string): FeedFeedbackEntry[] {
    const trimmed = (videoId || '').trim();
    if (trimmed.length === 0) {
      return [];
    }
    const hit = FeedFeedbackStore.entries.get(trimmed);
    return hit ? hit : [];
  }

  static clear(): void {
    FeedFeedbackStore.entries.clear();
    FeedFeedbackStore.probeBudget = MAX_PROBE_PER_BATCH;
    logger.info('[FeedFeedback] stage=cleared');
  }

  /** 新一轮 feed（刷新/开下一批）时重置探测预算，保证每批都能给出结构线索。 */
  static resetProbe(): void {
    FeedFeedbackStore.probeBudget = MAX_PROBE_PER_BATCH;
  }

  /** 诊断用：这一页有多少条目带反馈项、总 token 数（真机验证时看这一行就知道结构对不对）。 */
  static summary(): string {
    let tokens = 0;
    FeedFeedbackStore.entries.forEach((list: FeedFeedbackEntry[]) => {
      tokens += list.length;
    });
    return `videos=${FeedFeedbackStore.entries.size} tokens=${tokens}`;
  }

  /** videoId 可能是 `videoId`、lockup 的 `contentId`，或 watchEndpoint 里的 videoId。 */
  private static findVideoId(node: Record<string, Object>): string {
    const direct = node['videoId'];
    if (typeof direct === 'string' && FeedFeedbackStore.isVideoId(direct)) {
      return direct;
    }
    const contentId = node['contentId'];
    if (typeof contentId === 'string' && FeedFeedbackStore.isVideoId(contentId)) {
      return contentId;
    }
    const watch = node['watchEndpoint'] as Record<string, Object> | undefined;
    if (watch) {
      const fromEndpoint = watch['videoId'];
      if (typeof fromEndpoint === 'string' && FeedFeedbackStore.isVideoId(fromEndpoint)) {
        return fromEndpoint;
      }
    }
    // 套壳层（`{ richItemRenderer: { content: { lockupViewModel: … } } }`）：往里找第一
    // 个 11 位 ID，这样一次 scanItemNode(整条) 就能覆盖 renderer 和 viewmodel 两种结构。
    return FeedFeedbackStore.findVideoIdDeep(node, 0);
  }

  private static findVideoIdDeep(node: Record<string, Object>, depth: number): string {
    if (depth > 5) {
      return '';
    }
    const keys = Object.keys(node);
    for (let i = 0; i < keys.length; i++) {
      const key = keys[i];
      const value = node[key];
      if ((key === 'videoId' || key === 'contentId' || key === 'entityId') && typeof value === 'string') {
        if (FeedFeedbackStore.isVideoId(value)) {
          return value;
        }
        continue;
      }
      if (!value || typeof value !== 'object') {
        continue;
      }
      if (Array.isArray(value)) {
        const list = value as Object[];
        for (let j = 0; j < list.length; j++) {
          const element = list[j];
          if (element && typeof element === 'object' && !Array.isArray(element)) {
            const found = FeedFeedbackStore.findVideoIdDeep(element as Record<string, Object>, depth + 1);
            if (found.length > 0) {
              return found;
            }
          }
        }
        continue;
      }
      const found = FeedFeedbackStore.findVideoIdDeep(value as Record<string, Object>, depth + 1);
      if (found.length > 0) {
        return found;
      }
    }
    return '';
  }

  private static isVideoId(value: string): boolean {
    return value.length === 11;
  }

  /**
   * 深度优先找反馈 token。
   *
   * 网页的 token 挂在卡片菜单深层（见 `MAX_WALK_DEPTH` 注释），所以深度要给足；
   * 命中点是**直接挂着 token 字段的那个对象**，文案从祖先链往上回溯找
   * （`listItemViewModel.title` 和 `feedbackEndpoint` 中间隔着 4～5 层容器）。
   *
   * `ancestors` 是 DFS 共享栈（尾部 = 最近的父），进出各一次 push/pop，
   * 每页 60 张卡 × 深层节点如果每次复制数组，光分配就够拖慢解析。
   */
  private static walk(node: Record<string, Object>, ancestors: AncestorHop[],
    out: FeedFeedbackEntry[], depth: number): void {
    if (depth > MAX_WALK_DEPTH || out.length >= MAX_ENTRIES_PER_VIDEO) {
      return;
    }
    const parentKey = ancestors.length > 0 ? ancestors[ancestors.length - 1].key : '';
    const token = FeedFeedbackStore.readOwnToken(node, parentKey);
    if (token.length > 0) {
      out.push({ label: FeedFeedbackStore.pickLabelNear(node, ancestors), token: token });
      return;
    }
    const keys = Object.keys(node);
    for (let i = 0; i < keys.length; i++) {
      const key = keys[i];
      const value = node[key];
      if (!value || typeof value !== 'object') {
        continue;
      }
      if (Array.isArray(value)) {
        const list = value as Object[];
        for (let j = 0; j < list.length; j++) {
          const element = list[j];
          if (element && typeof element === 'object' && !Array.isArray(element)) {
            ancestors.push({ node: node, key: key });
            FeedFeedbackStore.walk(element as Record<string, Object>, ancestors, out, depth + 1);
            ancestors.pop();
          }
        }
        continue;
      }
      ancestors.push({ node: node, key: key });
      FeedFeedbackStore.walk(value as Record<string, Object>, ancestors, out, depth + 1);
      ancestors.pop();
      if (out.length >= MAX_ENTRIES_PER_VIDEO) {
        return;
      }
    }
  }

  /**
   * 先在本节点找文案，找不到就沿祖先栈往上回溯（网页的 `title.content` 在 5 层之外），
   * 只回溯 `LABEL_ANCESTOR_HOPS` 层——再往上就是卡片自己的标题，会把视频标题当成菜单文案。
   */
  private static pickLabelNear(node: Record<string, Object>, ancestors: AncestorHop[]): string {
    const self = FeedFeedbackStore.pickLabel(node);
    if (self.length > 0) {
      return self;
    }
    const floor = Math.max(0, ancestors.length - LABEL_ANCESTOR_HOPS);
    for (let i = ancestors.length - 1; i >= floor; i--) {
      const fromAncestor = FeedFeedbackStore.pickLabel(ancestors[i].node);
      if (fromAncestor.length > 0) {
        return fromAncestor;
      }
    }
    return '';
  }

  /**
   * 这个对象自己是不是「带 token 的 feedback 端点」。
   *
   * `feedbackToken` 是 Innertube 里唯一表示反馈 token 的字段名，任何父键下都成立；
   * 裸 `token` 只在 `feedbackEndpoint` 里算数 —— 否则会误抓 `continuationCommand.token`
   * 这类分页游标，把游标当反馈 token 提交上去。
   */
  private static readOwnToken(node: Record<string, Object>, parentKey: string): string {
    const feedbackToken = node['feedbackToken'];
    if (typeof feedbackToken === 'string' && feedbackToken.length > 0) {
      return feedbackToken;
    }
    if (parentKey === 'feedbackEndpoint' || parentKey === 'feedCommandWrapper') {
      const token = node['token'];
      if (typeof token === 'string' && token.length > 0) {
        return token;
      }
    }
    return '';
  }

  /** 取菜单项自己的文案（服务端已按 hl 本地化）。 */
  private static pickLabel(node: Record<string, Object>): string {
    for (let i = 0; i < LABEL_KEYS.length; i++) {
      const fromKey = FeedFeedbackStore.readLabelValue(node[LABEL_KEYS[i]]);
      if (fromKey.length > 0) {
        return fromKey;
      }
    }
    // 常见套壳：menuItemViewModel / xxxRenderer 再往里才是 text
    const keys = Object.keys(node);
    for (let i = 0; i < keys.length; i++) {
      const child = node[keys[i]];
      if (!child || typeof child !== 'object' || Array.isArray(child)) {
        continue;
      }
      const wrapped = child as Record<string, Object>;
      const fromChild = FeedFeedbackStore.readLabelValue(wrapped['text']);
      if (fromChild.length > 0) {
        return fromChild;
      }
      const inner = wrapped['menuItemViewModel'] as Record<string, Object> | undefined;
      if (inner) {
        const fromInner = FeedFeedbackStore.readLabelValue(inner['text']);
        if (fromInner.length > 0) {
          return fromInner;
        }
      }
    }
    return '';
  }

  /** 文案字段常见形状：裸字符串 / {content} / {simpleText} / {runs:[{text}]}。 */
  private static readLabelValue(value: Object | undefined): string {
    if (!value) {
      return '';
    }
    if (typeof value === 'string') {
      return value;
    }
    if (typeof value !== 'object' || Array.isArray(value)) {
      return '';
    }
    const holder = value as Record<string, Object>;
    const content = holder['content'];
    if (typeof content === 'string' && content.length > 0) {
      return content;
    }
    const simpleText = holder['simpleText'];
    if (typeof simpleText === 'string' && simpleText.length > 0) {
      return simpleText;
    }
    const runs = holder['runs'];
    if (Array.isArray(runs)) {
      const parts: string[] = [];
      const list = runs as Object[];
      for (let i = 0; i < list.length; i++) {
        const run = list[i];
        if (run && typeof run === 'object') {
          const text = (run as Record<string, Object>)['text'];
          if (typeof text === 'string' && text.length > 0) {
            parts.push(text);
          }
        }
      }
      if (parts.length > 0) {
        return parts.join('');
      }
    }
    return '';
  }

  /**
   * 结构探测：没扫到 token 时，把这个条目的**完整键名骨架**（不含任何值）打进日志。
   * 真机抓一行就能判断反馈菜单到底在不在 feed 响应里、藏在哪条链上。
   * 只记键名，不记 value，token/URL/文案都不会进日志。
   *
   * 键名先按路径去重（同一批里几十个卡片结构相同，重复打没意义），再按
   * `PROBE_PATHS_PER_LINE` 分行，最多 `PROBE_MAX_LINES` 行后截断。
   */
  private static probe(node: Record<string, Object>, reason: string): void {
    if (FeedFeedbackStore.probeBudget <= 0) {
      return;
    }
    FeedFeedbackStore.probeBudget -= 1;
    const seen: Set<string> = new Set();
    const paths: string[] = [];
    FeedFeedbackStore.collectKeyPaths(node, '', paths, seen, 0);
    if (paths.length === 0) {
      logger.info(`[FeedProbe] stage=probe reason=${reason} paths=0 topKeys=${Object.keys(node).join(',')}`);
      return;
    }
    logger.info(`[FeedProbe] stage=probe reason=${reason} paths=${paths.length}`);
    let lines = 0;
    for (let i = 0; i < paths.length; i += PROBE_PATHS_PER_LINE) {
      if (lines >= PROBE_MAX_LINES) {
        logger.info(`[FeedProbe] ...(截断，剩余 ${paths.length - i} 条) `);
        return;
      }
      const slice = paths.slice(i, i + PROBE_PATHS_PER_LINE);
      logger.info(`[FeedProbe] ${slice.join(' | ')}`);
      lines += 1;
    }
  }

  private static collectKeyPaths(node: Record<string, Object>, prefix: string,
    out: string[], seen: Set<string>, depth: number): void {
    if (depth > PROBE_MAX_DEPTH || out.length >= PROBE_MAX_PATHS) {
      return;
    }
    const keys = Object.keys(node);
    for (let i = 0; i < keys.length; i++) {
      const key = keys[i];
      const path = prefix.length > 0 ? `${prefix}.${key}` : key;
      if (!seen.has(path)) {
        seen.add(path);
        out.push(path);
      }
      const value = node[key];
      if (!value || typeof value !== 'object') {
        continue;
      }
      if (Array.isArray(value)) {
        const list = value as Object[];
        for (let j = 0; j < list.length; j++) {
          const element = list[j];
          if (element && typeof element === 'object' && !Array.isArray(element)) {
            FeedFeedbackStore.collectKeyPaths(element as Record<string, Object>, `${path}[]`,
              out, seen, depth + 1);
          }
        }
        continue;
      }
      FeedFeedbackStore.collectKeyPaths(value as Record<string, Object>, path, out, seen, depth + 1);
    }
  }
}
