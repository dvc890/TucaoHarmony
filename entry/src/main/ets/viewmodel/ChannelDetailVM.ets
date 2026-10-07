/**
 * 频道详情视图模型
 * - 页签：父频道 + 同父子频道（ChannelTable.findSiblingChannels(有效父 id)）
 * - 排序：date(最近发布)/views(人气最旺)/mukio(弹幕最多)——对齐安卓 ChannelDetail 现行行为。
 *   注：list.php 的 views 与 play 返回结果实测不同，安卓频道详情人气榜用 views（play 仅搜索用），
 *   故不沿用 SortOrder 枚举（无 views 值），直接请求 list.php。
 * - 数据源：api_v2 list.php（tid/order/page/pagesize=10，页大小对齐安卓 ChannelDetailFragment）
 * - 各子频道页签状态独立缓存（含各自排序选择）
 */
import { Video, JsonCoerce } from '../model/entity/BaseEntities';
import { VideoRepository } from '../model/repository/VideoRepository';
import { TucaoApiClient } from '../service/api/TucaoApiClient';
import { Channel, ChannelTable, JsonApi } from '../common/Constants';

/** 单子频道内容流状态 */
@ObservedV2
export class ChannelDetailFeedState {
  @Trace videos: Video[] = [];
  @Trace total: number = 0;
  @Trace page: number = 0;
  @Trace order: string = 'date';
  /** 初始须为 false：loadChannel 有 loading 防重入守卫，置 true 会导致首屏永不加载 */
  @Trace loading: boolean = false;
  @Trace refreshing: boolean = false;
  @Trace loadingMore: boolean = false;
  @Trace error: string = '';
  @Trace loadedOnce: boolean = false;

  get hasMore(): boolean {
    return this.videos.length < this.total;
  }
}

@ObservedV2
export class ChannelDetailVM {
  private static instance: ChannelDetailVM | undefined;

  /** 排序值（list.php order 参数） */
  static readonly ORDER_DATE: string = 'date';
  static readonly ORDER_VIEWS: string = 'views';
  static readonly ORDER_MUKIO: string = 'mukio';
  /** 排序值顺序（TagFilter 下标用） */
  static readonly ORDERS: string[] =
    [ChannelDetailVM.ORDER_DATE, ChannelDetailVM.ORDER_VIEWS, ChannelDetailVM.ORDER_MUKIO];
  /** 排序文案（对齐安卓频道详情） */
  static readonly ORDER_TEXTS: Record<string, string> = {
    'date': '最近发布',
    'views': '人气最旺',
    'mukio': '弹幕最多'
  };

  /** 页大小（对齐安卓 ChannelDetailFragment） */
  private static readonly PAGESIZE: number = 10;

  /** 当前选中的子频道 tid */
  @Trace currentTid: number = 0;

  private feeds: Record<string, ChannelDetailFeedState> = {};

  static shared(): ChannelDetailVM {
    if (ChannelDetailVM.instance === undefined) {
      ChannelDetailVM.instance = new ChannelDetailVM();
    }
    return ChannelDetailVM.instance;
  }

  static orderText(order: string): string {
    const text: string | undefined = ChannelDetailVM.ORDER_TEXTS[order];
    return text ?? '最近发布';
  }

  /** tid（父或子）→ 页签列表（父频道 + 同父子频道） */
  static tabsOf(tid: number): Channel[] {
    const channel: Channel | undefined = ChannelTable.find(tid);
    const parentTid: number = channel !== undefined ? channel.getValidParentId() : tid;
    return ChannelTable.findSiblingChannels(parentTid);
  }

  /** 页面进入：设置当前子频道 */
  setup(tid: number): void {
    this.currentTid = tid;
  }

  /** tid → 内容流状态（懒创建） */
  stateOf(tid: number): ChannelDetailFeedState {
    const key: string = `${tid}`;
    let feed: ChannelDetailFeedState | undefined = this.feeds[key];
    if (feed === undefined) {
      feed = new ChannelDetailFeedState();
      this.feeds[key] = feed;
    }
    return feed;
  }

  /** 首次进入页签懒加载 */
  async loadChannel(tid: number): Promise<void> {
    const feed: ChannelDetailFeedState = this.stateOf(tid);
    if (feed.loadedOnce || feed.loading || feed.refreshing) {
      return;
    }
    await this.fetchPage(feed, tid, 1, false);
  }

  /** 下拉刷新 */
  async refreshChannel(tid: number): Promise<void> {
    const feed: ChannelDetailFeedState = this.stateOf(tid);
    if (feed.refreshing) {
      return;
    }
    await this.fetchPage(feed, tid, 1, false, true);
  }

  /** 加载更多 */
  async loadMoreChannel(tid: number): Promise<void> {
    const feed: ChannelDetailFeedState = this.stateOf(tid);
    if (!feed.loadedOnce || feed.loadingMore || feed.refreshing || !feed.hasMore) {
      return;
    }
    await this.fetchPage(feed, tid, feed.page + 1, true);
  }

  /** 切换排序（重置分页并重新加载） */
  changeOrder(tid: number, order: string): void {
    const feed: ChannelDetailFeedState = this.stateOf(tid);
    if (feed.order === order) {
      return;
    }
    feed.order = order;
    feed.videos = [];
    feed.total = 0;
    feed.page = 0;
    feed.loadedOnce = false;
    feed.loading = true;
    feed.loadingMore = false;
    feed.error = '';
    this.fetchPage(feed, tid, 1, false);
  }

  private async fetchPage(feed: ChannelDetailFeedState, tid: number, page: number, append: boolean,
    refreshing: boolean = false): Promise<void> {
    if (append) {
      feed.loadingMore = true;
    } else if (refreshing) {
      feed.refreshing = true;
    } else {
      feed.loading = true;
    }
    feed.error = '';
    try {
      const params: Record<string, string> = {
        'tid': `${tid}`,
        'page': `${page}`,
        'pagesize': `${ChannelDetailVM.PAGESIZE}`,
        'order': feed.order
      };
      const record: Record<string, Object> = await TucaoApiClient.getInstance().getApiV2(JsonApi.LIST, params);
      ChannelDetailVM.assertApiCode(record);
      const total: number = JsonCoerce.asNumber(record['total_count']);
      const rawList: Object[] = JsonCoerce.asObjectArray(record['result']);
      const videos: Video[] = [];
      for (let i = 0; i < rawList.length; i++) {
        const item: Record<string, Object> | undefined = JsonCoerce.asRecord(rawList[i]);
        if (item !== undefined) {
          videos.push(VideoRepository.parseVideoRecord(item));
        }
      }
      // 排序切换期间可能已过期，忽略旧页
      if (append && page !== feed.page + 1) {
        return;
      }
      if (append) {
        // 按 hid 去重追加
        const existing: Set<string> = new Set<string>();
        for (let i = 0; i < feed.videos.length; i++) {
          existing.add(feed.videos[i].hid);
        }
        for (let i = 0; i < videos.length; i++) {
          if (!existing.has(videos[i].hid)) {
            feed.videos.push(videos[i]);
          }
        }
      } else {
        feed.videos = videos;
      }
      feed.total = total;
      feed.page = page;
      feed.loadedOnce = true;
    } catch (err) {
      feed.error = err instanceof Error ? err.message : '加载失败';
    } finally {
      feed.loading = false;
      feed.loadingMore = false;
      feed.refreshing = false;
    }
  }

  /** api_v2 回执校验（code:"200"，异常抛错） */
  private static assertApiCode(record: Record<string, Object>): void {
    const codeRaw: Object | undefined = record['code'];
    let code: string = '';
    if (typeof codeRaw === 'string') {
      code = codeRaw;
    } else if (typeof codeRaw === 'number') {
      code = `${codeRaw}`;
    }
    if (code !== '200') {
      const msg: string = JsonCoerce.asString(record['msg'], '接口返回异常');
      throw new Error(`[${code}] ${msg}`);
    }
  }
}
