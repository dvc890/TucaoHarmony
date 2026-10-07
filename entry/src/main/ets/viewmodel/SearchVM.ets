/**
 * 搜索视图模型
 * - 数据源：api_v2 search.php（q/page/pagesize=10/order/tid）
 *   tid='0'（全部分类）时不传参数，对齐安卓 tid=null
 * - 分页判定对齐安卓：单页返回条数 < 10 即到底
 *   （服务端 total_count 口径不可靠，安卓版同样弃用）
 * - 历史记录：search_history.json（string[]，新在前，按关键词去重，无上限）
 * - 页面级实例：每次进页重置（对齐安卓 SearchActivity 生命周期）
 */
import { Video, JsonCoerce } from '../model/entity/BaseEntities';
import { TucaoApiClient } from '../service/api/TucaoApiClient';
import { VideoRepository } from '../model/repository/VideoRepository';
import { JsonFileStore } from '../data/JsonFileStore';
import { JsonApi, SortOrder, StoreFile } from '../common/Constants';

@ObservedV2
export class SearchVM {
  /** 每页条数（对齐安卓 pageSize=10） */
  static readonly PAGESIZE: number = 10;

  /** 输入框关键词 */
  @Trace keyword: string = '';
  /** 搜索历史（新在前） */
  @Trace history: string[] = [];

  /** 频道筛选 tid（'0'=全部分类） */
  @Trace tid: string = '0';
  /** 排序（默认发布时间） */
  @Trace order: SortOrder = SortOrder.DATE;

  /** 当前搜索词（发起搜索时固定，翻页/筛选沿用） */
  @Trace lastKeyword: string = '';

  // ===== 结果态 =====
  @Trace videos: Video[] = [];
  @Trace page: number = 0;
  @Trace searching: boolean = false;
  @Trace refreshing: boolean = false;
  @Trace loadingMore: boolean = false;
  /** 单页不足 PAGESIZE 条 → 没有更多 */
  @Trace noMore: boolean = false;
  @Trace error: string = '';
  @Trace searchedOnce: boolean = false;

  /** 结果态？（否则历史态） */
  get inSearchMode(): boolean {
    return this.searchedOnce || this.searching;
  }

  /** 进页：加载本地历史 */
  loadHistory(): void {
    const items: Object[] = JsonFileStore.loadArray(StoreFile.SEARCH_HISTORY);
    const history: string[] = [];
    for (let i = 0; i < items.length; i++) {
      const keyword: string = JsonCoerce.asString(items[i]);
      if (keyword.length > 0) {
        history.push(keyword);
      }
    }
    this.history = history;
  }

  /** 发起搜索（空关键词忽略；同时写入历史） */
  async search(keyword: string): Promise<void> {
    const kw: string = keyword.trim();
    if (kw.length === 0) {
      return;
    }
    this.keyword = kw;
    this.lastKeyword = kw;
    this.saveHistory(kw);
    await this.fetchPage(1, false, false);
  }

  /** 下拉刷新 */
  async refresh(): Promise<void> {
    if (this.lastKeyword.length === 0 || this.searching || this.refreshing) {
      return;
    }
    await this.fetchPage(1, false, true);
  }

  /** 触底加载更多 */
  async loadMore(): Promise<void> {
    if (!this.searchedOnce || this.searching || this.loadingMore || this.refreshing || this.noMore) {
      return;
    }
    await this.fetchPage(this.page + 1, true, false);
  }

  /** 输入变化：清空 → 回到历史态 */
  onKeywordChange(text: string): void {
    this.keyword = text;
    if (text.length === 0) {
      this.videos = [];
      this.searchedOnce = false;
      this.searching = false;
      this.error = '';
      this.page = 0;
      this.noMore = false;
    }
  }

  /** 切换频道：结果态下重新搜索 */
  async changeTid(tid: string): Promise<void> {
    if (this.tid === tid) {
      return;
    }
    this.tid = tid;
    if (this.lastKeyword.length > 0 && this.inSearchMode) {
      await this.fetchPage(1, false, false);
    }
  }

  /** 切换排序：结果态下重新搜索 */
  async changeOrder(order: SortOrder): Promise<void> {
    if (this.order === order) {
      return;
    }
    this.order = order;
    if (this.lastKeyword.length > 0 && this.inSearchMode) {
      await this.fetchPage(1, false, false);
    }
  }

  /** 单条删除历史 */
  removeHistory(keyword: string): void {
    const next: string[] = [];
    for (let i = 0; i < this.history.length; i++) {
      if (this.history[i] !== keyword) {
        next.push(this.history[i]);
      }
    }
    this.history = next;
    this.persistHistory();
  }

  /** 保存历史：按关键词去重后插到最前 */
  private saveHistory(keyword: string): void {
    const next: string[] = [keyword];
    for (let i = 0; i < this.history.length; i++) {
      if (this.history[i] !== keyword) {
        next.push(this.history[i]);
      }
    }
    this.history = next;
    this.persistHistory();
  }

  private persistHistory(): void {
    const items: Object[] = [];
    for (let i = 0; i < this.history.length; i++) {
      items.push(this.history[i]);
    }
    JsonFileStore.saveArray(StoreFile.SEARCH_HISTORY, items).catch((err: Object): void => {
      console.error(`[SearchVM] 保存搜索历史失败: ${err}`);
    });
  }

  private async fetchPage(page: number, append: boolean, refreshing: boolean): Promise<void> {
    if (append) {
      this.loadingMore = true;
    } else if (refreshing) {
      this.refreshing = true;
    } else {
      this.searching = true;
    }
    this.error = '';
    try {
      const params: Record<string, string> = {
        'q': this.lastKeyword,
        'page': `${page}`,
        'pagesize': `${SearchVM.PAGESIZE}`,
        'order': `${this.order}`
      };
      // tid='0'（全部分类）→ 不传，对齐安卓 null
      if (this.tid !== '0') {
        params['tid'] = this.tid;
      }
      const record: Record<string, Object> = await TucaoApiClient.getInstance().getApiV2(JsonApi.SEARCH, params);
      SearchVM.assertApiCode(record);
      const resultObj: Object | undefined = record['result'];
      const list: Object[] = resultObj instanceof Array ? resultObj as Object[] : [];
      const videos: Video[] = [];
      for (let i = 0; i < list.length; i++) {
        const item: Record<string, Object> = list[i] as Record<string, Object>;
        videos.push(VideoRepository.parseVideoRecord(item));
      }
      // 刷新期间筛选已变化 → 丢弃过期页
      if (append && page !== this.page + 1) {
        return;
      }
      if (append) {
        // 按 hid 去重追加
        const existing: Set<string> = new Set<string>();
        for (let i = 0; i < this.videos.length; i++) {
          existing.add(this.videos[i].hid);
        }
        for (let i = 0; i < videos.length; i++) {
          if (!existing.has(videos[i].hid)) {
            this.videos.push(videos[i]);
          }
        }
      } else {
        this.videos = videos;
      }
      this.page = page;
      this.searchedOnce = true;
      // 对齐安卓：单页不足 PAGESIZE 条即到底（total_count 不可靠）
      this.noMore = videos.length < SearchVM.PAGESIZE;
    } catch (err) {
      this.error = err instanceof Error ? err.message : '搜索失败';
    } finally {
      this.searching = false;
      this.refreshing = false;
      this.loadingMore = false;
    }
  }

  /** 断言 api_v2 code==='200'（本文件内本地复制） */
  private static assertApiCode(record: Record<string, Object>): void {
    const codeRaw: Object | undefined = record['code'];
    const code: string = JsonCoerce.asString(codeRaw);
    if (code !== '200') {
      let msg: string = '接口返回异常';
      const messageRaw: Object | undefined = record['message'];
      if (messageRaw !== undefined) {
        msg = JsonCoerce.asString(messageRaw);
      }
      throw new Error(`[${code}] ${msg}`);
    }
  }
}
