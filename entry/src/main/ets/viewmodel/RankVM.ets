/**
 * 排行榜视图模型（重做：api_v2 rank.php 已被站点废弃，改走站点 hot.html 网页体系）
 * - 8 榜（RankKind）：排行榜/追番榜/弹幕榜/在线/神评论/无人区/u榜/热搜榜，全部单页全量
 * - 主榜支持分类过滤（?p=，RankCategory：全站/连载新番/完结番组/剧场版/电影/电视剧/天朝出品）
 * - 按（榜单，分类）缓存；kind 切换保留各榜缓存，category 切换只清主榜缓存（数据保鲜）
 * - 解析产出 RankSection[] 后即时平铺为 RankRow[]（分区标题行 + 条目行），
 *   页面单 List 虚拟滚动渲染；弹幕榜保持服务器原始顺序（严禁按数值重排）
 */
import { TucaoApiClient } from '../service/api/TucaoApiClient';
import { RawApi, RankCategory } from '../common/Constants';
import {
  RankKind,
  RankSection,
  RankVideoItem,
  RankUserItem,
  RankKeywordItem,
  RankHtmlParser
} from '../service/api/RankHtmlParser';

/** 榜单元数据（chip 文案 + 端点映射） */
export class RankKindMeta {
  /** 榜单顺序（chip 顺序） */
  static readonly ALL: RankKind[] = [
    RankKind.HOT,
    RankKind.FAV,
    RankKind.DANMU,
    RankKind.ONLINE,
    RankKind.DIGG,
    RankKind.ZERO,
    RankKind.USER,
    RankKind.KEYWORD
  ];

  /** chip 文案（与 ALL 一一对应） */
  static readonly KIND_LABELS: string[] = ['排行榜', '追番榜', '弹幕榜', '在线', '神评论', '无人区', 'u榜', '热搜榜'];

  /** 榜单 chip 文案 */
  static labelOf(kind: RankKind): string {
    const idx: number = RankKindMeta.ALL.indexOf(kind);
    return idx >= 0 ? RankKindMeta.KIND_LABELS[idx] : '';
  }

  /** chip 下标 → 榜单（越界回退主榜） */
  static kindAt(index: number): RankKind {
    if (index >= 0 && index < RankKindMeta.ALL.length) {
      return RankKindMeta.ALL[index];
    }
    return RankKind.HOT;
  }

  /** 榜单 → chip 下标 */
  static indexOfKind(kind: RankKind): number {
    return RankKindMeta.ALL.indexOf(kind);
  }

  /** 榜单端点（相对 BASE_RAW_API_URL） */
  static endpointOf(kind: RankKind): string {
    switch (kind) {
      case RankKind.HOT:
        return RawApi.HOT;
      case RankKind.FAV:
        return RawApi.FAV_HOT;
      case RankKind.DANMU:
        return RawApi.DANMU_HOT;
      case RankKind.ONLINE:
        return RawApi.ONLINE;
      case RankKind.DIGG:
        return RawApi.DIGG;
      case RankKind.ZERO:
        return RawApi.ZERO;
      case RankKind.USER:
        return RawApi.USER_HOT;
      case RankKind.KEYWORD:
        return RawApi.HOT_SEARCH;
      default:
        return RawApi.HOT;
    }
  }
}

/** 列表行类型（单 List 平铺渲染） */
export enum RankRowType {
  /** 分区标题行（今天/本周/本月/今年/无人区分类/u榜栏目） */
  HEADER = 0,
  /** 视频条目行 */
  VIDEO = 1,
  /** 用户条目行（u榜） */
  USER = 2,
  /** 关键词条目行（热搜榜） */
  KEYWORD = 3
}

/**
 * 平铺渲染行：分区标题行 + 条目行。
 * 载荷字段非可选（非本行类型时为空白占位实例）：build() 内 this.row.video
 * 属属性链访问、无法可靠窄化联合类型，改由 type 分发 + 占位实例保证类型非空。
 */
export class RankRow {
  readonly type: RankRowType;
  /** HEADER：分区标题 */
  readonly title: string;
  /** VIDEO 行条目（其余行类型为空白占位实例） */
  readonly video: RankVideoItem;
  /** USER 行条目（其余行类型为空白占位实例） */
  readonly user: RankUserItem;
  /** KEYWORD 行条目（其余行类型为空白占位实例） */
  readonly keyword: RankKeywordItem;
  /** 条目行名次（DOM 顺序从 1 起；热搜取解析排名；HEADER 为 0） */
  readonly rank: number;

  private constructor(type: RankRowType, title: string, video: RankVideoItem,
    user: RankUserItem, keyword: RankKeywordItem, rank: number) {
    this.type = type;
    this.title = title;
    this.video = video;
    this.user = user;
    this.keyword = keyword;
    this.rank = rank;
  }

  /** 分区标题行 */
  static header(title: string): RankRow {
    return new RankRow(RankRowType.HEADER, title,
      new RankVideoItem(), new RankUserItem(), new RankKeywordItem(), 0);
  }

  /** 视频条目行（名次 = 区块内 DOM 顺序） */
  static videoRow(item: RankVideoItem, rank: number): RankRow {
    return new RankRow(RankRowType.VIDEO, '',
      item, new RankUserItem(), new RankKeywordItem(), rank);
  }

  /** 用户条目行（名次 = 区块内 DOM 顺序） */
  static userRow(item: RankUserItem, rank: number): RankRow {
    return new RankRow(RankRowType.USER, '',
      new RankVideoItem(), item, new RankKeywordItem(), rank);
  }

  /** 关键词条目行（名次取解析排名） */
  static keywordRow(item: RankKeywordItem): RankRow {
    return new RankRow(RankRowType.KEYWORD, '',
      new RankVideoItem(), new RankUserItem(), item, item.rank);
  }
}

/** 单榜单状态（缓存键 = 榜单 + 分类） */
@ObservedV2
export class RankFeedState {
  /** 平铺渲染行（分区标题行 + 条目行） */
  @Trace rows: RankRow[] = [];
  /** 初始须为 false：loadRank 有 loading 防重入守卫，置 true 会导致首屏永不加载 */
  @Trace loading: boolean = false;
  @Trace refreshing: boolean = false;
  @Trace error: string = '';
  @Trace loadedOnce: boolean = false;
}

@ObservedV2
export class RankVM {
  private static instance: RankVM | undefined;

  /** 主榜缓存键前缀（category 切换时按前缀清理主榜缓存） */
  private static readonly HOT_KEY_PREFIX: string = 'hot-';

  /** 当前榜单 */
  @Trace currentKind: RankKind = RankKind.HOT;
  /** 主榜当前分类（仅主榜生效） */
  @Trace currentCategory: RankCategory = RankCategory.defaultCategory();

  /** 各（榜单，分类）缓存 */
  private feeds: Record<string, RankFeedState> = {};

  static shared(): RankVM {
    if (RankVM.instance === undefined) {
      RankVM.instance = new RankVM();
    }
    return RankVM.instance;
  }

  /** （榜单，分类）→ 榜单状态（懒创建） */
  feedOf(kind: RankKind, category: RankCategory): RankFeedState {
    const key: string = RankVM.feedKey(kind, category);
    let feed: RankFeedState | undefined = this.feeds[key];
    if (feed === undefined) {
      feed = new RankFeedState();
      this.feeds[key] = feed;
    }
    return feed;
  }

  /** 首次进入懒加载（已加载过则跳过） */
  async loadRank(kind: RankKind, category: RankCategory): Promise<void> {
    const feed: RankFeedState = this.feedOf(kind, category);
    if (feed.loadedOnce || feed.loading || feed.refreshing) {
      return;
    }
    await this.fetch(kind, category, false);
  }

  /** 下拉刷新 */
  async refreshRank(kind: RankKind, category: RankCategory): Promise<void> {
    const feed: RankFeedState = this.feedOf(kind, category);
    if (feed.refreshing) {
      return;
    }
    await this.fetch(kind, category, true);
  }

  /** 切换榜单：保留各榜缓存，由页面触发新榜单加载 */
  changeKind(kind: RankKind): void {
    this.currentKind = kind;
  }

  /** 切换主榜分类：分类仅影响主榜，只清主榜缓存（数据保鲜），由页面触发重新拉取 */
  changeCategory(category: RankCategory): void {
    if (this.currentCategory.pValue === category.pValue) {
      return;
    }
    this.currentCategory = category;
    const keys: string[] = Object.keys(this.feeds);
    for (let i = 0; i < keys.length; i++) {
      if (keys[i].startsWith(RankVM.HOT_KEY_PREFIX)) {
        const feed: RankFeedState | undefined = this.feeds[keys[i]];
        if (feed !== undefined) {
          feed.rows = [];
          feed.loadedOnce = false;
          // 不在此处置 loading=true：视图随后直调 loadRank，loading 会被防重入守卫挡回
          feed.error = '';
        }
      }
    }
  }

  private async fetch(kind: RankKind, category: RankCategory, refreshing: boolean): Promise<void> {
    const feed: RankFeedState = this.feedOf(kind, category);
    if (refreshing) {
      feed.refreshing = true;
    } else {
      feed.loading = true;
    }
    feed.error = '';
    try {
      const html: string = await TucaoApiClient.getInstance().getRawText(
        RankKindMeta.endpointOf(kind), RankVM.categoryParams(kind, category));
      feed.rows = RankVM.parseAndFlatten(html, kind);
      feed.loadedOnce = true;
    } catch (err) {
      feed.error = err instanceof Error ? err.message : '加载失败';
    } finally {
      feed.loading = false;
      feed.refreshing = false;
    }
  }

  /** 主榜分类查询参数（其余榜单无参数；全站不携带 ?p=） */
  private static categoryParams(kind: RankKind, category: RankCategory): Record<string, string> {
    if (kind === RankKind.HOT && category.pValue.length > 0) {
      const params: Record<string, string> = { 'p': category.pValue };
      return params;
    }
    const empty: Record<string, string> = {};
    return empty;
  }

  /** 抓取 → 解析（RankSection[]）→ 平铺渲染行 */
  private static parseAndFlatten(html: string, kind: RankKind): RankRow[] {
    if (kind === RankKind.USER) {
      return RankVM.flattenUser(RankHtmlParser.parseUserRank(html));
    }
    if (kind === RankKind.KEYWORD) {
      return RankVM.flattenKeyword(RankHtmlParser.parseKeywordRank(html));
    }
    return RankVM.flattenVideo(RankHtmlParser.parseVideoRank(html, kind));
  }

  /** 视频榜区块 → 平铺行（空区块跳过；名次 = 区块内 DOM 顺序，从 1 起） */
  private static flattenVideo(sections: RankSection<RankVideoItem>[]): RankRow[] {
    const rows: RankRow[] = [];
    for (let s = 0; s < sections.length; s++) {
      const section: RankSection<RankVideoItem> = sections[s];
      if (section.items.length === 0) {
        continue;
      }
      if (section.title.length > 0) {
        rows.push(RankRow.header(section.title));
      }
      for (let i = 0; i < section.items.length; i++) {
        rows.push(RankRow.videoRow(section.items[i], i + 1));
      }
    }
    return rows;
  }

  /** u榜区块 → 平铺行 */
  private static flattenUser(sections: RankSection<RankUserItem>[]): RankRow[] {
    const rows: RankRow[] = [];
    for (let s = 0; s < sections.length; s++) {
      const section: RankSection<RankUserItem> = sections[s];
      if (section.items.length === 0) {
        continue;
      }
      if (section.title.length > 0) {
        rows.push(RankRow.header(section.title));
      }
      for (let i = 0; i < section.items.length; i++) {
        rows.push(RankRow.userRow(section.items[i], i + 1));
      }
    }
    return rows;
  }

  /** 热搜榜区块 → 平铺行 */
  private static flattenKeyword(sections: RankSection<RankKeywordItem>[]): RankRow[] {
    const rows: RankRow[] = [];
    for (let s = 0; s < sections.length; s++) {
      const section: RankSection<RankKeywordItem> = sections[s];
      if (section.items.length === 0) {
        continue;
      }
      if (section.title.length > 0) {
        rows.push(RankRow.header(section.title));
      }
      for (let i = 0; i < section.items.length; i++) {
        rows.push(RankRow.keywordRow(section.items[i]));
      }
    }
    return rows;
  }

  /** 缓存键：主榜拼分类 p 值，其余按榜单 */
  private static feedKey(kind: RankKind, category: RankCategory): string {
    if (kind === RankKind.HOT) {
      return `${RankVM.HOT_KEY_PREFIX}${category.pValue}`;
    }
    return `${kind}`;
  }
}
