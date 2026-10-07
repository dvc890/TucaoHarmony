/**
 * 历史新番视图模型
 * - 数据源：站点 bgm 页 HTML（bgm/?year&month&page，对齐安卓 rawApiService.bgm）
 * - 筛选：年代（不限/当年..2010/2000-2009，对齐安卓下拉项）+ 季度（不限/1月/4月/7月/10月/剧场版99）
 * - 计数：div.title > a.m「共N条」；每页 50 条（站点固定），
 *   hasMore = 已加载数 < 总数（安卓 data.size < 10 的判定在 50 条/页下恒假，不采用）
 * - 条目结构：div.list > div.item > a.vp(封面+hid) / a.t(标题) / div.i(播放数+UP主)
 */
import { Element } from 'domhandler';
import { Video, JsonCoerce } from '../model/entity/BaseEntities';
import { TucaoApiClient } from '../service/api/TucaoApiClient';
import { HtmlParseUtil } from '../service/api/HtmlParseUtil';
import { Host, RawApi } from '../common/Constants';

/** 筛选项（年代/季度下拉） */
export class FilterOption {
  readonly label: string;
  readonly value: string;

  constructor(label: string, value: string) {
    this.label = label;
    this.value = value;
  }
}

/** 解析结果（条目 + 总数） */
export class AnimeTimeParseResult {
  readonly videos: Video[];
  readonly total: number;

  constructor(videos: Video[], total: number) {
    this.videos = videos;
    this.total = total;
  }
}

@ObservedV2
export class AnimeTimeState {
  @Trace videos: Video[] = [];
  @Trace total: number = 0;
  @Trace page: number = 0;
  /** 初始须为 false：load 有 loading 防重入守卫，置 true 会导致首屏永不加载 */
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
export class AnimeTimeVM {
  private static instance: AnimeTimeVM | undefined;

  readonly state: AnimeTimeState = new AnimeTimeState();

  /** 当前年代筛选值（空串=不限） */
  @Trace year: string = '';
  /** 当前季度筛选值（空串=不限，99=剧场版） */
  @Trace month: string = '';

  /** 是否已初始化默认筛选（当年 + 当季） */
  private initialized: boolean = false;

  static shared(): AnimeTimeVM {
    if (AnimeTimeVM.instance === undefined) {
      AnimeTimeVM.instance = new AnimeTimeVM();
    }
    return AnimeTimeVM.instance;
  }

  /** 默认筛选：当年 + 当季起始月（1/4/7/10，对齐安卓） */
  initDefaultFilter(): void {
    if (this.initialized) {
      return;
    }
    this.initialized = true;
    const now: Date = new Date();
    this.year = `${now.getFullYear()}`;
    this.month = `${Math.floor(now.getMonth() / 3) * 3 + 1}`;
  }

  /** 年代筛选项（不限/当年..2010/2000-2009） */
  static yearOptions(): FilterOption[] {
    const options: FilterOption[] = [new FilterOption('不限', '')];
    const currentYear: number = new Date().getFullYear();
    for (let y = currentYear; y >= 2010; y--) {
      options.push(new FilterOption(`${y}`, `${y}`));
    }
    options.push(new FilterOption('2000-2009', '2000-2009'));
    return options;
  }

  /** 季度筛选项 */
  static monthOptions(): FilterOption[] {
    const options: FilterOption[] = [
      new FilterOption('不限', ''),
      new FilterOption('1月', '1'),
      new FilterOption('4月', '4'),
      new FilterOption('7月', '7'),
      new FilterOption('10月', '10'),
      new FilterOption('剧场版', '99')
    ];
    return options;
  }

  /** 首次加载 */
  async load(): Promise<void> {
    if (this.state.loadedOnce || this.state.loading || this.state.refreshing) {
      return;
    }
    await this.fetchPage(1, false);
  }

  /** 下拉刷新 */
  async refresh(): Promise<void> {
    if (this.state.refreshing) {
      return;
    }
    await this.fetchPage(1, false, true);
  }

  /** 加载更多 */
  async loadMore(): Promise<void> {
    if (!this.state.loadedOnce || this.state.loadingMore || this.state.refreshing || !this.state.hasMore) {
      return;
    }
    await this.fetchPage(this.state.page + 1, true);
  }

  /** 切换年代：重置分页并重新加载 */
  changeYear(value: string): void {
    if (this.year === value) {
      return;
    }
    this.year = value;
    this.resetAndReload();
  }

  /** 切换季度：重置分页并重新加载 */
  changeMonth(value: string): void {
    if (this.month === value) {
      return;
    }
    this.month = value;
    this.resetAndReload();
  }

  private resetAndReload(): void {
    this.state.videos = [];
    this.state.total = 0;
    this.state.page = 0;
    this.state.loadedOnce = false;
    this.state.loading = true;
    this.state.loadingMore = false;
    this.state.error = '';
    this.fetchPage(1, false);
  }

  private async fetchPage(page: number, append: boolean, refreshing: boolean = false): Promise<void> {
    if (append) {
      this.state.loadingMore = true;
    } else if (refreshing) {
      this.state.refreshing = true;
    } else {
      this.state.loading = true;
    }
    this.state.error = '';
    try {
      const params: Record<string, string> = {
        'year': this.year,
        'month': this.month,
        'page': `${page}`
      };
      const html: string = await TucaoApiClient.getInstance().getRawText(RawApi.BGM, params);
      const result: AnimeTimeParseResult = AnimeTimeVM.parseAnimeTime(html);
      // 筛选切换期间可能已过期，忽略旧页
      if (append && page !== this.state.page + 1) {
        return;
      }
      if (append) {
        // 按 hid 去重追加
        const existing: Set<string> = new Set<string>();
        for (let i = 0; i < this.state.videos.length; i++) {
          existing.add(this.state.videos[i].hid);
        }
        for (let i = 0; i < result.videos.length; i++) {
          if (!existing.has(result.videos[i].hid)) {
            this.state.videos.push(result.videos[i]);
          }
        }
      } else {
        this.state.videos = result.videos;
      }
      this.state.total = result.total;
      this.state.page = page;
      this.state.loadedOnce = true;
    } catch (err) {
      this.state.error = err instanceof Error ? err.message : '加载失败';
    } finally {
      this.state.loading = false;
      this.state.loadingMore = false;
      this.state.refreshing = false;
    }
  }

  /** bgm 页 HTML → 条目 + 总数 */
  static parseAnimeTime(html: string): AnimeTimeParseResult {
    const doc = HtmlParseUtil.parse(html);
    // 计数：div.title > a.m「共N条 / 第N页」
    let total: number = 0;
    const titleEls: Element[] = HtmlParseUtil.findAllByTagAndClass(doc, 'div', 'title');
    for (let i = 0; i < titleEls.length; i++) {
      const countLink: Element | undefined = HtmlParseUtil.findOneByTagAndClass(titleEls[i], 'a', 'm');
      if (countLink !== undefined) {
        const match: RegExpExecArray | null = new RegExp('共(\\d+)条').exec(HtmlParseUtil.text(countLink));
        if (match !== null && match.length > 1) {
          total = Number(match[1]);
        }
        break;
      }
    }
    // 条目：div.list > div.item
    const videos: Video[] = [];
    const listEl: Element | undefined = HtmlParseUtil.findOneByTagAndClass(doc, 'div', 'list');
    if (listEl !== undefined) {
      const items: Element[] = HtmlParseUtil.findAllByTagAndClass(listEl, 'div', 'item');
      for (let i = 0; i < items.length; i++) {
        const video: Video | undefined = AnimeTimeVM.parseItem(items[i]);
        if (video !== undefined) {
          videos.push(video);
        }
      }
    }
    return new AnimeTimeParseResult(videos, total);
  }

  /** 单条目：a.vp(hid+封面) / a.t(标题) / div.i(播放数+UP主) */
  private static parseItem(item: Element): Video | undefined {
    const vpLink: Element | undefined = HtmlParseUtil.findOneByTagAndClass(item, 'a', 'vp');
    if (vpLink === undefined) {
      return undefined;
    }
    const hid: string = AnimeTimeVM.extractHid(HtmlParseUtil.attr(vpLink, 'href'));
    if (hid.length === 0) {
      return undefined;
    }
    let thumb: string = '';
    const img: Element | undefined = HtmlParseUtil.findOneByTag(vpLink, 'img');
    if (img !== undefined) {
      thumb = AnimeTimeVM.extractStyleUrl(HtmlParseUtil.attr(img, 'style'));
      if (thumb.length === 0) {
        thumb = AnimeTimeVM.toAbsolute(HtmlParseUtil.attr(img, 'src'));
      }
    }
    const titleLink: Element | undefined = HtmlParseUtil.findOneByTagAndClass(item, 'a', 't');
    const title: string = titleLink !== undefined ? HtmlParseUtil.text(titleLink).trim() : '';
    if (title.length === 0) {
      return undefined;
    }
    let play: number = 0;
    let user: string = '';
    let userid: string = '';
    const infoDiv: Element | undefined = HtmlParseUtil.findOneByTagAndClass(item, 'div', 'i');
    if (infoDiv !== undefined) {
      const playSpan: Element | undefined = HtmlParseUtil.findOneByTag(infoDiv, 'span');
      if (playSpan !== undefined) {
        // 播放数带千分位（如 12,947），先去逗号
        play = JsonCoerce.asNumber(HtmlParseUtil.text(playSpan).replace(/,/g, '').trim());
      }
      const userLink: Element | undefined = HtmlParseUtil.findOneByTag(infoDiv, 'a');
      if (userLink !== undefined) {
        user = HtmlParseUtil.text(userLink).trim();
        userid = AnimeTimeVM.extractUserid(HtmlParseUtil.attr(userLink, 'href'));
      }
    }
    const record: Record<string, Object> = {
      'hid': hid,
      'title': title,
      'play': play,
      'thumb': thumb,
      'user': user,
      'userid': userid
    };
    return Video.fromApiJson(record);
  }

  /** href=/play/h{hid}/ → hid */
  private static extractHid(href: string): string {
    const match: RegExpExecArray | null = new RegExp('/play/h(\\d+)/').exec(href);
    if (match !== null && match.length > 1) {
      return match[1];
    }
    return '';
  }

  /** href=/play/u{userid}/ → userid */
  private static extractUserid(href: string): string {
    const match: RegExpExecArray | null = new RegExp('/play/u(\\d+)/').exec(href);
    if (match !== null && match.length > 1) {
      return match[1];
    }
    return '';
  }

  /** style 属性内 background-image:url(...) 提取 */
  private static extractStyleUrl(style: string): string {
    const marker: string = 'url(';
    const idx: number = style.indexOf(marker);
    if (idx < 0) {
      return '';
    }
    let start: number = idx + marker.length;
    let quote: string = '';
    const firstChar: string = style.charAt(start);
    if (firstChar === '"' || firstChar === '\'') {
      quote = firstChar;
      start += 1;
    }
    const end: number = style.indexOf(')', start);
    if (end < 0) {
      return '';
    }
    let raw: string = style.substring(start, end).trim();
    if (quote.length > 0 && raw.endsWith(quote)) {
      raw = raw.substring(0, raw.length - 1);
    }
    return raw;
  }

  /** 相对路径 → 绝对地址 */
  private static toAbsolute(src: string): string {
    if (src.startsWith('http://') || src.startsWith('https://')) {
      return src;
    }
    if (src.startsWith('/')) {
      return `${Host.BASE_RAW_API_URL}${src.substring(1)}`;
    }
    return src;
  }
}
