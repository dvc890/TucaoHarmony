/**
 * 首页视图模型
 * - 单例：三形态（手机/中屏/大屏）共享同一份六频道状态
 * - 推荐频道：HTML 抓取 → 轮播 + 分组
 * - 四内容频道（新番24/影剧23/游戏21/动画19）：api_v2 list.php 分页 + 排序切换
 * - 下拉刷新 / 加载更多 / 错误态由各 Feed 状态承载，视图仅做状态映射
 * - 未读数联动：UNREAD_CHANGED 事件 → SessionState（侧边栏角标）
 */
import { Video, } from '../model/entity/BaseEntities';
import { ChannelListPage, IndexPage, RecommendGroup, VideoRepository } from '../model/repository/VideoRepository';
import { HomeTab, SortOrder } from '../common/Constants';
import { GlobalState, SessionState } from '../common/GlobalState';
import { EventBus } from '../common/EventBus';
import { PreferenceStore } from '../data/PreferenceStore';

/** 推荐频道状态 */
@ObservedV2
export class RecommendState {
  @Trace banners: Video[] = [];
  @Trace groups: RecommendGroup[] = [];
  /** 初始须为 false：loadRecommend 有 loading 防重入守卫，置 true 会导致首屏永不加载 */
  @Trace loading: boolean = false;
  @Trace refreshing: boolean = false;
  @Trace error: string = '';
  @Trace loadedOnce: boolean = false;
}

/** 内容频道流状态 */
@ObservedV2
export class ChannelFeedState {
  @Trace videos: Video[] = [];
  @Trace total: number = 0;
  @Trace page: number = 0;
  @Trace order: SortOrder = SortOrder.DATE;
  /** 首屏加载（初始须为 false，理由同 RecommendState.loading） */
  @Trace loading: boolean = false;
  /** 下拉刷新中 */
  @Trace refreshing: boolean = false;
  /** 加载更多中 */
  @Trace loadingMore: boolean = false;
  @Trace error: string = '';
  @Trace loadedOnce: boolean = false;

  get hasMore(): boolean {
    return this.videos.length < this.total;
  }
}

@ObservedV2
export class HomeVM {
  private static instance: HomeVM | undefined;

  readonly recommend: RecommendState = new RecommendState();
  readonly bangumi: ChannelFeedState = new ChannelFeedState();
  readonly movie: ChannelFeedState = new ChannelFeedState();
  readonly game: ChannelFeedState = new ChannelFeedState();
  readonly animation: ChannelFeedState = new ChannelFeedState();

  /** 当前频道（六频道共享选中态，三形态联动）。
   *  手机形态 TabContent 由 ForEach 预建且 itemGenerator 不随状态重跑，
   *  builder 表达式传入的 active 会被冻结，选中/激活态必须经共享 VM 传播 */
  @Trace currentChannel: number = HomeTab.RECOMMEND;

  /** 每频道分页大小 */
  private static readonly PAGESIZE: number = 20;

  static shared(): HomeVM {
    if (HomeVM.instance === undefined) {
      HomeVM.instance = new HomeVM();
    }
    return HomeVM.instance;
  }

  /** tid → 对应频道流状态 */
  feedOf(tid: number): ChannelFeedState {
    if (tid === HomeTab.LIST_TIDS['1']) {
      return this.bangumi;
    }
    if (tid === HomeTab.LIST_TIDS['2']) {
      return this.movie;
    }
    if (tid === HomeTab.LIST_TIDS['3']) {
      return this.game;
    }
    return this.animation;
  }

  /** 推荐频道：首次/强制加载 */
  async loadRecommend(force: boolean): Promise<void> {
    const state: RecommendState = this.recommend;
    if (state.loadedOnce && !force) {
      return;
    }
    if (state.loading || state.refreshing) {
      return;
    }
    state.loading = !state.loadedOnce;
    state.error = '';
    try {
      const page: IndexPage = await VideoRepository.getInstance().fetchIndex();
      state.banners = page.banners;
      state.groups = page.groups;
      state.loadedOnce = true;
    } catch (err) {
      state.error = err instanceof Error ? err.message : '加载失败';
    } finally {
      state.loading = false;
      state.refreshing = false;
    }
  }

  /** 推荐频道：下拉刷新 */
  async refreshRecommend(): Promise<void> {
    const state: RecommendState = this.recommend;
    if (state.refreshing) {
      return;
    }
    state.refreshing = true;
    state.error = '';
    try {
      const page: IndexPage = await VideoRepository.getInstance().fetchIndex();
      state.banners = page.banners;
      state.groups = page.groups;
      state.loadedOnce = true;
    } catch (err) {
      state.error = err instanceof Error ? err.message : '刷新失败';
    } finally {
      state.refreshing = false;
      state.loading = false;
    }
  }

  /** 内容频道：首屏加载 */
  async loadChannel(tid: number): Promise<void> {
    const feed: ChannelFeedState = this.feedOf(tid);
    if (feed.loadedOnce || feed.loading || feed.refreshing) {
      return;
    }
    await this.fetchChannelPage(feed, tid, 1, false);
  }

  /** 内容频道：下拉刷新（重置到第一页） */
  async refreshChannel(tid: number): Promise<void> {
    const feed: ChannelFeedState = this.feedOf(tid);
    if (feed.refreshing) {
      return;
    }
    feed.refreshing = true;
    feed.error = '';
    try {
      const page: ChannelListPage = await VideoRepository.getInstance()
        .fetchChannelList(tid, feed.order, 1, HomeVM.PAGESIZE);
      feed.videos = page.videos;
      feed.total = page.total;
      feed.page = page.page;
      feed.loadedOnce = true;
    } catch (err) {
      feed.error = err instanceof Error ? err.message : '刷新失败';
    } finally {
      feed.refreshing = false;
      feed.loading = false;
    }
  }

  /** 内容频道：加载更多 */
  async loadMoreChannel(tid: number): Promise<void> {
    const feed: ChannelFeedState = this.feedOf(tid);
    if (!feed.loadedOnce || feed.loadingMore || feed.refreshing || !feed.hasMore) {
      return;
    }
    await this.fetchChannelPage(feed, tid, feed.page + 1, true);
  }

  /** 内容频道：切换排序（重置分页） */
  changeOrder(tid: number, order: SortOrder): void {
    const feed: ChannelFeedState = this.feedOf(tid);
    if (feed.order === order) {
      return;
    }
    feed.order = order;
    feed.videos = [];
    feed.total = 0;
    feed.page = 0;
    feed.loadedOnce = false;
    feed.loading = true;
    feed.error = '';
    this.fetchChannelPage(feed, tid, 1, false);
  }

  /** 分页取数（append=true 追加） */
  private async fetchChannelPage(feed: ChannelFeedState, tid: number, page: number, append: boolean): Promise<void> {
    if (append) {
      feed.loadingMore = true;
    } else {
      feed.loading = true;
    }
    feed.error = '';
    try {
      const result: ChannelListPage = await VideoRepository.getInstance()
        .fetchChannelList(tid, feed.order, page, HomeVM.PAGESIZE);
      // 排序或刷新期间可能已切换，忽略过期页
      if (append && page !== feed.page + 1) {
        return;
      }
      if (append) {
        // 按 hid 去重后追加
        const existing: Set<string> = new Set<string>();
        for (let i = 0; i < feed.videos.length; i++) {
          existing.add(feed.videos[i].hid);
        }
        for (let i = 0; i < result.videos.length; i++) {
          if (!existing.has(result.videos[i].hid)) {
            feed.videos.push(result.videos[i]);
          }
        }
      } else {
        feed.videos = result.videos;
      }
      feed.total = result.total;
      feed.page = result.page;
      feed.loadedOnce = true;
    } catch (err) {
      feed.error = err instanceof Error ? err.message : '加载失败';
    } finally {
      feed.loading = false;
      feed.loadingMore = false;
    }
  }

  /** 未读数联动：本地用户摘要同步 + 事件订阅（返回取消函数，调用方在 aboutToDisappear 执行） */
  bindUnread(): () => void {
    const session: SessionState = GlobalState.sessionState();
    session.unreadMessageCount = PreferenceStore.user().message;
    return EventBus.onUnreadChanged((event) => {
      session.unreadMessageCount = event.count;
      PreferenceStore.user().message = event.count;
      PreferenceStore.saveUser();
    });
  }
}
