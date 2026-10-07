/**
 * UP 主空间视图模型
 * - 数据源：站点空间页 HTML（index.php?m=member&c=space&uid={userId}&page=N，
 *   对齐安卓 rawApiService.space）
 * - 头部（div.sheader）：banner 背景图 + 头像 + 昵称 + 统计（正义值/守护天数等）+ 签名
 * - 计数（div.title > a.m「共N条」）与条目（div.list > div.item）结构与历史新番页一致
 * - 换 uid 进入时整体重置（单例 VM 复用）
 * - 安卓旧解析（div.v/a.tt）对现行站点结构已失效，本类按现行结构解析
 */
import { Element } from 'domhandler';
import { Video, JsonCoerce } from '../model/entity/BaseEntities';
import { TucaoApiClient } from '../service/api/TucaoApiClient';
import { HtmlParseUtil } from '../service/api/HtmlParseUtil';
import { Host, RawApi } from '../common/Constants';

/** UP 主头部信息 */
@ObservedV2
export class UploaderHeader {
  @Trace nickname: string = '';
  @Trace avatar: string = '';
  @Trace banner: string = '';
  /** 统计行（正义值/守护天数/居住年限等） */
  @Trace stats: string = '';
  @Trace signature: string = '';
  @Trace loaded: boolean = false;
}

/** 投稿流状态 */
@ObservedV2
export class UploaderFeedState {
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

/** 空间页解析结果 */
export class SpaceParseResult {
  readonly header: UploaderHeader;
  readonly videos: Video[];
  readonly total: number;

  constructor(header: UploaderHeader, videos: Video[], total: number) {
    this.header = header;
    this.videos = videos;
    this.total = total;
  }
}

@ObservedV2
export class UploaderVM {
  private static instance: UploaderVM | undefined;

  /** 当前展示的 UP 主 uid（换人时重置） */
  @Trace userId: string = '';

  readonly header: UploaderHeader = new UploaderHeader();
  readonly feed: UploaderFeedState = new UploaderFeedState();

  static shared(): UploaderVM {
    if (UploaderVM.instance === undefined) {
      UploaderVM.instance = new UploaderVM();
    }
    return UploaderVM.instance;
  }

  /** 首次/换人加载 */
  async load(userId: string): Promise<void> {
    if (this.userId !== userId) {
      this.reset(userId);
    }
    if (this.feed.loadedOnce || this.feed.loading || this.feed.refreshing) {
      return;
    }
    await this.fetchPage(1, false, false);
  }

  /** 下拉刷新（头部一并刷新） */
  async refresh(): Promise<void> {
    if (this.feed.refreshing) {
      return;
    }
    await this.fetchPage(1, false, true);
  }

  /** 加载更多 */
  async loadMore(): Promise<void> {
    if (!this.feed.loadedOnce || this.feed.loadingMore || this.feed.refreshing || !this.feed.hasMore) {
      return;
    }
    await this.fetchPage(this.feed.page + 1, true, false);
  }

  /** 换 uid：清空头部与列表 */
  private reset(userId: string): void {
    this.userId = userId;
    this.header.nickname = '';
    this.header.avatar = '';
    this.header.banner = '';
    this.header.stats = '';
    this.header.signature = '';
    this.header.loaded = false;
    this.feed.videos = [];
    this.feed.total = 0;
    this.feed.page = 0;
    this.feed.loadedOnce = false;
    // 不在此处置 loading=true：load() 随后的防重入守卫会将其挡回
    this.feed.loadingMore = false;
    this.feed.error = '';
  }

  private async fetchPage(page: number, append: boolean, refreshing: boolean): Promise<void> {
    if (append) {
      this.feed.loadingMore = true;
    } else if (refreshing) {
      this.feed.refreshing = true;
    } else {
      this.feed.loading = true;
    }
    this.feed.error = '';
    try {
      const params: Record<string, string> = {
        'uid': this.userId,
        'page': `${page}`
      };
      const html: string = await TucaoApiClient.getInstance().getRawText(RawApi.SPACE, params);
      const result: SpaceParseResult = UploaderVM.parseSpace(html);
      // 刷新期间可能已换人，忽略过期页
      if (append && page !== this.feed.page + 1) {
        return;
      }
      if (!append) {
        this.header.nickname = result.header.nickname;
        this.header.avatar = result.header.avatar;
        this.header.banner = result.header.banner;
        this.header.stats = result.header.stats;
        this.header.signature = result.header.signature;
        this.header.loaded = true;
      }
      if (append) {
        // 按 hid 去重追加
        const existing: Set<string> = new Set<string>();
        for (let i = 0; i < this.feed.videos.length; i++) {
          existing.add(this.feed.videos[i].hid);
        }
        for (let i = 0; i < result.videos.length; i++) {
          if (!existing.has(result.videos[i].hid)) {
            this.feed.videos.push(result.videos[i]);
          }
        }
      } else {
        this.feed.videos = result.videos;
      }
      this.feed.total = result.total;
      this.feed.page = page;
      this.feed.loadedOnce = true;
    } catch (err) {
      this.feed.error = err instanceof Error ? err.message : '加载失败';
    } finally {
      this.feed.loading = false;
      this.feed.loadingMore = false;
      this.feed.refreshing = false;
    }
  }

  /** 空间页 HTML → 头部 + 条目 + 总数 */
  static parseSpace(html: string): SpaceParseResult {
    const doc = HtmlParseUtil.parse(html);
    // 头部：div.sheader
    const header: UploaderHeader = new UploaderHeader();
    const sheader: Element | undefined = HtmlParseUtil.findOneByTagAndClass(doc, 'div', 'sheader');
    if (sheader !== undefined) {
      const bannerImg: Element | undefined = HtmlParseUtil.findOneByTagAndClass(sheader, 'img', 'banner');
      if (bannerImg !== undefined) {
        header.banner = UploaderVM.extractStyleUrl(HtmlParseUtil.attr(bannerImg, 'style'));
      }
      const avatarImg: Element | undefined = HtmlParseUtil.findOneByTagAndClass(sheader, 'img', 'avatar');
      if (avatarImg !== undefined) {
        header.avatar = UploaderVM.toAbsolute(HtmlParseUtil.attr(avatarImg, 'src'));
      }
      const sinfo: Element | undefined = HtmlParseUtil.findOneByTagAndClass(sheader, 'div', 'sinfo');
      if (sinfo !== undefined) {
        const nameEl: Element | undefined = HtmlParseUtil.findOneByTag(sinfo, 'h1');
        if (nameEl !== undefined) {
          header.nickname = HtmlParseUtil.text(nameEl).trim();
        }
        const ps: Element[] = HtmlParseUtil.findAllByTag(sinfo, 'p');
        if (ps.length > 0) {
          header.stats = HtmlParseUtil.text(ps[0]).trim();
        }
        if (ps.length > 1) {
          header.signature = HtmlParseUtil.text(ps[1]).trim();
        }
      }
    }
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
        const video: Video | undefined = UploaderVM.parseItem(items[i]);
        if (video !== undefined) {
          videos.push(video);
        }
      }
    }
    return new SpaceParseResult(header, videos, total);
  }

  /** 单条目：a.vp(hid+封面) / a.t(标题) / div.i(播放数+UP主) */
  private static parseItem(item: Element): Video | undefined {
    const vpLink: Element | undefined = HtmlParseUtil.findOneByTagAndClass(item, 'a', 'vp');
    if (vpLink === undefined) {
      return undefined;
    }
    const hid: string = UploaderVM.extractHid(HtmlParseUtil.attr(vpLink, 'href'));
    if (hid.length === 0) {
      return undefined;
    }
    let thumb: string = '';
    // 悬停预览帧（data-img 逗号分隔；真封面在 style background-image）
    let previewFrames: string[] = [];
    const img: Element | undefined = HtmlParseUtil.findOneByTag(vpLink, 'img');
    if (img !== undefined) {
      thumb = UploaderVM.extractStyleUrl(HtmlParseUtil.attr(img, 'style'));
      if (thumb.length === 0) {
        thumb = UploaderVM.toAbsolute(HtmlParseUtil.attr(img, 'src'));
      }
      previewFrames = UploaderVM.extractPreviewFrames(img);
    }
    const titleLink: Element | undefined = HtmlParseUtil.findOneByTagAndClass(item, 'a', 't');
    const title: string = titleLink !== undefined ? HtmlParseUtil.text(titleLink).trim() : '';
    if (title.length === 0) {
      return undefined;
    }
    let play: number = 0;
    const infoDiv: Element | undefined = HtmlParseUtil.findOneByTagAndClass(item, 'div', 'i');
    if (infoDiv !== undefined) {
      const playSpan: Element | undefined = HtmlParseUtil.findOneByTag(infoDiv, 'span');
      if (playSpan !== undefined) {
        // 播放数带千分位（如 12,947），先去逗号
        play = JsonCoerce.asNumber(HtmlParseUtil.text(playSpan).replace(/,/g, '').trim());
      }
    }
    const record: Record<string, Object> = {
      'hid': hid,
      'title': title,
      'play': play,
      'thumb': thumb,
      'previewFrames': previewFrames
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

  /**
   *  img 的 data-img 悬停预览帧列表（对齐 VideoRepository.extractPreviewFrames 本地镜像，勿跨层 import）
   * 实测两种格式「",url1,url2" / "url1,url2"」统一处理：逗号切分→trim→滤空→绝对化；
   * gif 卡 data-img 为空 → 空数组（封面本身即动图）
   */
  private static extractPreviewFrames(img: Element): string[] {
    const dataImg: string = HtmlParseUtil.attr(img, 'data-img');
    const frames: string[] = [];
    if (dataImg.length === 0) {
      return frames;
    }
    const parts: string[] = dataImg.split(',');
    for (let i = 0; i < parts.length; i++) {
      const candidate: string = parts[i].trim();
      if (candidate.length > 0) {
        frames.push(UploaderVM.toAbsolute(candidate));
      }
    }
    return frames;
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
