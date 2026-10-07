/**
 * 放送表视图模型
 * - 数据源：站点新番频道页 HTML（list/24/，对齐安卓 rawApiService.list(24)）：
 *   div.xf_tabs li×9 = [星期天,…,星期六,剧场版,天朝出品]（li.now 标记今日组）
 *   div.xf_list 内 9 个 ul 与页签一一对应（首个 ul.now = 今日）
 * - 条目结构（2026 现行站点）：ul > div.list > div.item > div.b
 *   > a.img[/play/hXXXX/]（封面：img style background-image；div.i>b=更新状态）
 *   + a.t（标题链接）；em 为分类标签不作为标题
 *   （旧结构 li>a/em/span 已废弃，旧解析取 li 会得到空列表）
 * - 无 hid 条目（外链）：页面点击时降级为关键词搜索
 */
import { Element } from 'domhandler';
import { TucaoApiClient } from '../service/api/TucaoApiClient';
import { HtmlParseUtil } from '../service/api/HtmlParseUtil';
import { Host, RawApi } from '../common/Constants';

/** 放送表条目 */
export class ShowtimeEntry {
  readonly hid: string;
  readonly title: string;
  readonly thumb: string;
  /** 更新状态（更新N话/全1话等） */
  readonly status: string;

  constructor(hid: string, title: string, thumb: string, status: string) {
    this.hid = hid;
    this.title = title;
    this.thumb = thumb;
    this.status = status;
  }
}

/** 放送表分组（一个星期组） */
export class ShowtimeGroup {
  readonly title: string;
  readonly entries: ShowtimeEntry[];
  readonly isToday: boolean;

  constructor(title: string, entries: ShowtimeEntry[], isToday: boolean) {
    this.title = title;
    this.entries = entries;
    this.isToday = isToday;
  }
}

/** 解析结果（分组 + 默认选中组下标） */
export class ShowtimeParseResult {
  readonly groups: ShowtimeGroup[];
  readonly defaultGroupIndex: number;

  constructor(groups: ShowtimeGroup[], defaultGroupIndex: number) {
    this.groups = groups;
    this.defaultGroupIndex = defaultGroupIndex;
  }
}

@ObservedV2
export class ShowtimeState {
  @Trace groups: ShowtimeGroup[] = [];
  /** 初始须为 false：load 有 loading 防重入守卫，置 true 会导致首屏永不加载 */
  @Trace loading: boolean = false;
  @Trace refreshing: boolean = false;
  @Trace error: string = '';
  @Trace loadedOnce: boolean = false;
  /** 默认选中组（今日；解析失败按星期推算） */
  @Trace defaultGroupIndex: number = 0;
}

@ObservedV2
export class ShowtimeVM {
  private static instance: ShowtimeVM | undefined;

  readonly state: ShowtimeState = new ShowtimeState();

  static shared(): ShowtimeVM {
    if (ShowtimeVM.instance === undefined) {
      ShowtimeVM.instance = new ShowtimeVM();
    }
    return ShowtimeVM.instance;
  }

  /** 首次/进入加载 */
  async load(): Promise<void> {
    if (this.state.loadedOnce || this.state.loading || this.state.refreshing) {
      return;
    }
    await this.fetch(false);
  }

  /** 下拉刷新 */
  async refresh(): Promise<void> {
    if (this.state.refreshing) {
      return;
    }
    await this.fetch(true);
  }

  private async fetch(refreshing: boolean): Promise<void> {
    if (refreshing) {
      this.state.refreshing = true;
    } else {
      this.state.loading = true;
    }
    this.state.error = '';
    try {
      const html: string = await TucaoApiClient.getInstance()
        .getRawText(RawApi.LIST.replace('{tid}', '24'));
      const result: ShowtimeParseResult = ShowtimeVM.parseShowtime(html);
      this.state.groups = result.groups;
      this.state.defaultGroupIndex = result.defaultGroupIndex;
      this.state.loadedOnce = true;
    } catch (err) {
      this.state.error = err instanceof Error ? err.message : '加载失败';
    } finally {
      this.state.loading = false;
      this.state.refreshing = false;
    }
  }

  /** 新番频道页 HTML → 分组列表 + 默认选中组 */
  static parseShowtime(html: string): ShowtimeParseResult {
    const doc = HtmlParseUtil.parse(html);
    const labels: string[] = [];
    let nowIndex: number = -1;
    const tabsEl: Element | undefined = HtmlParseUtil.findOneByTagAndClass(doc, 'div', 'xf_tabs');
    if (tabsEl !== undefined) {
      const lis: Element[] = HtmlParseUtil.findAllByTag(tabsEl, 'li');
      for (let i = 0; i < lis.length; i++) {
        labels.push(HtmlParseUtil.text(lis[i]).trim());
        if (HtmlParseUtil.hasClass(lis[i], 'now')) {
          nowIndex = i;
        }
      }
    }

    const groups: ShowtimeGroup[] = [];
    const listEl: Element | undefined = HtmlParseUtil.findOneByTagAndClass(doc, 'div', 'xf_list');
    const uls: Element[] = listEl !== undefined ? HtmlParseUtil.findAllByTag(listEl, 'ul') : [];
    for (let i = 0; i < uls.length && i < labels.length; i++) {
      if (labels[i].length > 0) {
        groups.push(new ShowtimeGroup(labels[i], ShowtimeVM.parseUl(uls[i]), i === nowIndex));
      }
    }

    let defaultIndex: number = ShowtimeVM.weekdayGroupIndex();
    if (nowIndex >= 0 && nowIndex < groups.length) {
      defaultIndex = nowIndex;
    }
    return new ShowtimeParseResult(groups, defaultIndex);
  }

  /** 单日 ul（现行结构 div.item）→ 条目列表 */
  private static parseUl(ul: Element): ShowtimeEntry[] {
    const entries: ShowtimeEntry[] = [];
    const items: Element[] = HtmlParseUtil.findAllByTagAndClass(ul, 'div', 'item');
    for (let i = 0; i < items.length; i++) {
      const body: Element | undefined = HtmlParseUtil.findOneByTagAndClass(items[i], 'div', 'b');
      if (body === undefined) {
        continue;
      }
      // 封面链接（a.img，携带 hid 与 background-image 封面）
      const cover: Element | undefined = HtmlParseUtil.findOneByTagAndClass(body, 'a', 'img');
      // 标题链接（a.t，纯文本标题）
      const titleLink: Element | undefined = HtmlParseUtil.findOneByTagAndClass(body, 'a', 't');
      const link: Element | undefined = cover !== undefined ? cover : titleLink;
      if (link === undefined) {
        continue;
      }
      const hid: string = ShowtimeVM.extractHid(HtmlParseUtil.attr(link, 'href'));
      let thumb: string = '';
      const img: Element | undefined = HtmlParseUtil.findOneByTag(link, 'img');
      if (img !== undefined) {
        thumb = ShowtimeVM.extractStyleUrl(HtmlParseUtil.attr(img, 'style'));
        if (thumb.length === 0) {
          thumb = ShowtimeVM.extractStyleUrl(HtmlParseUtil.attr(link, 'style'));
        }
        if (thumb.length === 0) {
          thumb = ShowtimeVM.toAbsolute(HtmlParseUtil.attr(img, 'src'));
        }
      }
      let title: string = titleLink !== undefined ? HtmlParseUtil.text(titleLink).trim() : '';
      if (title.length === 0) {
        title = HtmlParseUtil.text(link).trim();
      }
      if (title.length === 0) {
        continue;
      }
      // 更新状态（div.i > b：「更新N话/全N话」）
      let status: string = '';
      const infoDiv: Element | undefined = HtmlParseUtil.findOneByTagAndClass(link, 'div', 'i');
      if (infoDiv !== undefined) {
        const statusEl: Element | undefined = HtmlParseUtil.findOneByTag(infoDiv, 'b');
        if (statusEl !== undefined) {
          status = HtmlParseUtil.text(statusEl).trim();
        }
      }
      entries.push(new ShowtimeEntry(hid, title, thumb, status));
    }
    return entries;
  }

  /** 按星期推算默认组：周末(0/6) → 周末组 0；周一..五 → 1..5 */
  private static weekdayGroupIndex(): number {
    const day: number = new Date().getDay();
    if (day === 0 || day === 6) {
      return 0;
    }
    return day;
  }

  /** href=/play/h{hid}/ → hid */
  private static extractHid(href: string): string {
    const match: RegExpExecArray | null = new RegExp('/play/h(\\d+)/').exec(href);
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
