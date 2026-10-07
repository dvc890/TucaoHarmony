/**
 * 排行榜 HTML 解析器（rank.php 已被站点废弃，改走 hot.html 网页体系）
 * - 8 榜：排行榜/追番榜/弹幕榜/在线/神评论/无人区/u榜/热搜榜（全部无分页，单页全量）
 * - 共性骨架：.subnav（8 榜导航）→ .title → 主内容区；
 *   视频类条目 .time_item > .time_title + .list > .item > .b
 * - 封面：a.p.vp > img 的 style background-image:url(...)（img.src 为全站占位图，忽略）；
 *   data-img 为悬停预览帧列表（逗号切分，容忍前导逗号，空值给空数组）
 * - 前三名标记：角标元素带 class="n123"
 * - 弹幕榜保持服务器原始顺序（后端按综合热度排序），严禁按数值重排
 * - DOM 访问一律经由 HtmlParseUtil（唯一合法入口），对齐 ShowtimeVM 解析风格
 */
import { Document, Element } from 'domhandler';
import { HtmlParseUtil } from './HtmlParseUtil';
import { Host } from '../../common/Constants';

/** 榜单种类（解析行为分支；chip 文案与端点映射见 viewmodel/RankVM.ets RankKindMeta） */
export enum RankKind {
  /** 排行榜（主榜，支持 ?p= 分类过滤） */
  HOT = 0,
  /** 追番榜（次指标=追番数） */
  FAV = 1,
  /** 弹幕榜（角标=弹幕数，千分位逗号） */
  DANMU = 2,
  /** 在线（角标=实时在线人数，无区块单列表） */
  ONLINE = 3,
  /** 神评论（角标=评论点赞数，条目附带热门评论） */
  DIGG = 4,
  /** 无人区（角标=尘封N天，分类区块，无名次序号） */
  ZERO = 5,
  /** u榜（用户榜，5 栏目：失足/存活/中出/观点/话唠） */
  USER = 6,
  /** 热搜榜（关键词） */
  KEYWORD = 7
}

/** 视频类榜单条目（主榜/追番/弹幕/在线/神评论/无人区共用） */
export class RankVideoItem {
  readonly hid: string;
  readonly title: string;
  /** 封面绝对地址 */
  readonly cover: string;
  /** 角标文本：主榜/追番=名次数字；弹幕=弹幕数；在线=在线人数；神评论=点赞数；无人区=尘封N天 */
  readonly badgeText: string;
  /** 前三名标记（角标元素 n123） */
  readonly top3: boolean;
  /** 次指标原文（千分位含逗号，如 179,492 / 99.9x%人错过） */
  readonly metricText: string;
  /** 次指标含义（播放/追番；无人区文本自带「人错过」语义，为空串） */
  readonly metricLabel: string;
  readonly upName: string;
  readonly upId: string;
  /** 神评论榜：评论者昵称（含冒号，如「李小A：」） */
  readonly commentUser: string;
  /** 神评论榜：评论内容 */
  readonly commentText: string;
  /** 悬停预览帧列表（img data-img 逗号切分；多数条目为空数组，悬停轮播自然休眠） */
  readonly previewFrames: string[];

  constructor(hid: string = '', title: string = '', cover: string = '', badgeText: string = '',
    top3: boolean = false, metricText: string = '', metricLabel: string = '',
    upName: string = '', upId: string = '', commentUser: string = '', commentText: string = '',
    previewFrames: string[] = []) {
    this.hid = hid;
    this.title = title;
    this.cover = cover;
    this.badgeText = badgeText;
    this.top3 = top3;
    this.metricText = metricText;
    this.metricLabel = metricLabel;
    this.upName = upName;
    this.upId = upId;
    this.commentUser = commentUser;
    this.commentText = commentText;
    this.previewFrames = previewFrames;
  }
}

/** u榜用户条目 */
export class RankUserItem {
  readonly userId: string;
  readonly userName: string;
  /** 头像绝对地址（u榜头像在 img src 属性，非 style；相对路径已绝对化） */
  readonly avatar: string;
  /** 名次（p 角标文本） */
  readonly badgeText: string;
  /** 前三名标记（n123） */
  readonly top3: boolean;
  /** 趣味指标原文（如 1元9次 / 1390.5天 / 纯数字） */
  readonly metricText: string;

  constructor(userId: string = '', userName: string = '', avatar: string = '',
    badgeText: string = '', top3: boolean = false, metricText: string = '') {
    this.userId = userId;
    this.userName = userName;
    this.avatar = avatar;
    this.badgeText = badgeText;
    this.top3 = top3;
    this.metricText = metricText;
  }
}

/** 热搜关键词条目 */
export class RankKeywordItem {
  /** 排名（a > b 文本，缺省回退 DOM 顺序） */
  readonly rank: number;
  /** 前三名标记（a 元素 n123） */
  readonly top3: boolean;
  /** 关键词（href 的 info[title]= 参数解码，比文本节点可靠） */
  readonly keyword: string;
  /** 热度文本（如 129次） */
  readonly heatText: string;

  constructor(rank: number = 0, top3: boolean = false, keyword: string = '', heatText: string = '') {
    this.rank = rank;
    this.top3 = top3;
    this.keyword = keyword;
    this.heatText = heatText;
  }
}

/** 排行榜区块（今天/本周/本月/今年等；在线榜为无标题单区块） */
export class RankSection<T> {
  readonly title: string;
  readonly items: T[];

  constructor(title: string, items: T[]) {
    this.title = title;
    this.items = items;
  }
}

/** 纯函数解析器（无状态） */
export class RankHtmlParser {
  /** 视频类榜单（主榜/追番/弹幕/在线/神评论/无人区）→ 区块列表 */
  static parseVideoRank(html: string, kind: RankKind): RankSection<RankVideoItem>[] {
    const doc: Document = HtmlParseUtil.parse(html);
    if (kind === RankKind.ONLINE) {
      // 在线榜无区块：.main 下直接 .list（50 条），DOM 顺序即名次
      const list: Element | undefined = RankHtmlParser.findOnlineList(doc);
      const items: RankVideoItem[] = list !== undefined
        ? RankHtmlParser.parseVideoItems(list, kind)
        : [];
      return [new RankSection<RankVideoItem>('', items)];
    }
    const sections: RankSection<RankVideoItem>[] = [];
    const timeItems: Element[] = HtmlParseUtil.findAllByClass(doc, 'time_item');
    for (let i = 0; i < timeItems.length; i++) {
      const title: string = RankHtmlParser.sectionTitleOf(timeItems[i]);
      const list: Element | undefined = RankHtmlParser.findFirstList(timeItems[i]);
      const items: RankVideoItem[] = list !== undefined
        ? RankHtmlParser.parseVideoItems(list, kind)
        : [];
      sections.push(new RankSection<RankVideoItem>(title, items));
    }
    return sections;
  }

  /** u榜 → 区块列表（失足/存活/中出/观点/话唠五栏目） */
  static parseUserRank(html: string): RankSection<RankUserItem>[] {
    const doc: Document = HtmlParseUtil.parse(html);
    const sections: RankSection<RankUserItem>[] = [];
    const timeItems: Element[] = HtmlParseUtil.findAllByClass(doc, 'time_item');
    for (let i = 0; i < timeItems.length; i++) {
      const title: string = RankHtmlParser.sectionTitleOf(timeItems[i]);
      const list: Element | undefined = RankHtmlParser.findFirstList(timeItems[i]);
      const items: RankUserItem[] = list !== undefined
        ? RankHtmlParser.parseUserItems(list)
        : [];
      sections.push(new RankSection<RankUserItem>(title, items));
    }
    return sections;
  }

  /** 热搜榜 → 区块列表（今天/本周/本月/今年；区块容器为 .hot_search_list，区别于视频榜的 .list） */
  static parseKeywordRank(html: string): RankSection<RankKeywordItem>[] {
    const doc: Document = HtmlParseUtil.parse(html);
    const sections: RankSection<RankKeywordItem>[] = [];
    const timeItems: Element[] = HtmlParseUtil.findAllByClass(doc, 'time_item');
    for (let i = 0; i < timeItems.length; i++) {
      const title: string = RankHtmlParser.sectionTitleOf(timeItems[i]);
      const container: Element | undefined = RankHtmlParser.findFirstByClass(timeItems[i], 'hot_search_list');
      const items: RankKeywordItem[] = container !== undefined
        ? RankHtmlParser.parseKeywordItems(container)
        : [];
      sections.push(new RankSection<RankKeywordItem>(title, items));
    }
    if (sections.length === 0) {
      // 容错：无区块结构时按首个 hot_search_list 单区块解析
      const container: Element | undefined = RankHtmlParser.findFirstByClass(doc, 'hot_search_list');
      if (container !== undefined) {
        const items: RankKeywordItem[] = RankHtmlParser.parseKeywordItems(container);
        sections.push(new RankSection<RankKeywordItem>('', items));
      }
    }
    return sections;
  }

  // ==================== 视频类条目 ====================

  /** .list > .item > .b 视频条目解析（无 .b 时按 .item 自身解析） */
  private static parseVideoItems(list: Element, kind: RankKind): RankVideoItem[] {
    const items: RankVideoItem[] = [];
    let itemEls: Element[] = HtmlParseUtil.findAllByTagAndClass(list, 'div', 'item');
    if (itemEls.length === 0) {
      itemEls = HtmlParseUtil.findAllByClass(list, 'item');
    }
    for (let i = 0; i < itemEls.length; i++) {
      let body: Element | undefined = HtmlParseUtil.findOneByTagAndClass(itemEls[i], 'div', 'b');
      if (body === undefined) {
        body = itemEls[i];
      }
      const item: RankVideoItem | undefined = RankHtmlParser.parseVideoItem(body, kind);
      if (item !== undefined) {
        items.push(item);
      }
    }
    return items;
  }

  /** 单视频条目：a.p.vp（hid/角标/封面）+ a.t 标题 + .i UP主与次指标 + 神评论 div.comment */
  private static parseVideoItem(b: Element, kind: RankKind): RankVideoItem | undefined {
    // 封面链接（a.p.vp；追番榜可能带分P锚点如 /play/h101839/#2，hid 提取不受影响）
    const coverLink: Element | undefined = RankHtmlParser.findCoverLink(b);

    // hid：条目内 a[href^='/play/h']
    let hid: string = '';
    if (coverLink !== undefined) {
      hid = RankHtmlParser.extractHid(HtmlParseUtil.attr(coverLink, 'href'));
    }
    if (hid.length === 0) {
      const anyVideoLink: Element | undefined = RankHtmlParser.findFirstLinkByHrefPrefix(b, '/play/h');
      if (anyVideoLink !== undefined) {
        hid = RankHtmlParser.extractHid(HtmlParseUtil.attr(anyVideoLink, 'href'));
      }
    }

    // 角标（a.p.vp > p）：名次数字/弹幕数/在线人数/点赞数/尘封N天；n123=前三
    let badgeText: string = '';
    let top3: boolean = false;
    if (coverLink !== undefined) {
      const badgeEl: Element | undefined = HtmlParseUtil.findOneByTag(coverLink, 'p');
      if (badgeEl !== undefined) {
        badgeText = HtmlParseUtil.text(badgeEl).trim();
        top3 = HtmlParseUtil.hasClass(badgeEl, 'n123');
      }
    }

    // 封面：a.p.vp > img 的 style background-image:url(...)（src 为占位图，忽略）
    let cover: string = '';
    let previewFrames: string[] = [];
    if (coverLink !== undefined) {
      const img: Element | undefined = HtmlParseUtil.findOneByTag(coverLink, 'img');
      if (img !== undefined) {
        cover = RankHtmlParser.toAbsolute(
          RankHtmlParser.extractStyleUrl(HtmlParseUtil.attr(img, 'style')));
        previewFrames = RankHtmlParser.extractPreviewFrames(img);
      }
    }

    // 标题（a.t；缺省回退封面链接 title 属性）
    let title: string = '';
    const titleLink: Element | undefined = HtmlParseUtil.findOneByTagAndClass(b, 'a', 't');
    if (titleLink !== undefined) {
      title = HtmlParseUtil.text(titleLink).trim();
    }
    if (title.length === 0 && coverLink !== undefined) {
      title = HtmlParseUtil.attr(coverLink, 'title').trim();
    }
    if (title.length === 0) {
      return undefined;
    }

    // UP主 + 次指标（.i > a[href^='/play/u'] + span；.i 缺失时退化为条目内直查）
    let upName: string = '';
    let upId: string = '';
    let metricText: string = '';
    const infoDiv: Element | undefined = HtmlParseUtil.findOneByTagAndClass(b, 'div', 'i');
    const infoScope: Element = infoDiv !== undefined ? infoDiv : b;
    const upLink: Element | undefined = RankHtmlParser.findFirstLinkByHrefPrefix(infoScope, '/play/u');
    if (upLink !== undefined) {
      upName = HtmlParseUtil.text(upLink).trim();
      upId = RankHtmlParser.extractUid(HtmlParseUtil.attr(upLink, 'href'));
    }
    const metricEl: Element | undefined = RankHtmlParser.findDirectChildByTag(infoScope, 'span');
    if (metricEl !== undefined) {
      metricText = HtmlParseUtil.text(metricEl).trim();
    }

    // 神评论（div.comment：首个 span 为评论者昵称，其后为评论内容）
    let commentUser: string = '';
    let commentText: string = '';
    if (kind === RankKind.DIGG) {
      const commentDiv: Element | undefined = HtmlParseUtil.findOneByTagAndClass(b, 'div', 'comment');
      if (commentDiv !== undefined) {
        const fullText: string = HtmlParseUtil.text(commentDiv).trim();
        const nameSpan: Element | undefined = HtmlParseUtil.findOneByTag(commentDiv, 'span');
        if (nameSpan !== undefined) {
          commentUser = HtmlParseUtil.text(nameSpan).trim();
          commentText = fullText.startsWith(commentUser)
            ? fullText.substring(commentUser.length).trim()
            : fullText;
        } else {
          commentText = fullText;
        }
      }
    }

    return new RankVideoItem(hid, title, cover, badgeText, top3, metricText,
      RankHtmlParser.metricLabelOf(kind), upName, upId, commentUser, commentText, previewFrames);
  }

  /** 封面链接：优先 a.vp（a.p.vp）且 href 指向视频页；退化为条目内首个视频链接 */
  private static findCoverLink(b: Element): Element | undefined {
    const links: Element[] = HtmlParseUtil.findAllByTag(b, 'a');
    for (let i = 0; i < links.length; i++) {
      if (HtmlParseUtil.hasClass(links[i], 'vp')
        && HtmlParseUtil.attr(links[i], 'href').startsWith('/play/h')) {
        return links[i];
      }
    }
    return RankHtmlParser.findFirstLinkByHrefPrefix(b, '/play/h');
  }

  // ==================== u榜用户条目 ====================

  /** .list > .item > .b 用户条目解析 */
  private static parseUserItems(list: Element): RankUserItem[] {
    const items: RankUserItem[] = [];
    let itemEls: Element[] = HtmlParseUtil.findAllByTagAndClass(list, 'div', 'item');
    if (itemEls.length === 0) {
      itemEls = HtmlParseUtil.findAllByClass(list, 'item');
    }
    for (let i = 0; i < itemEls.length; i++) {
      let body: Element | undefined = HtmlParseUtil.findOneByTagAndClass(itemEls[i], 'div', 'b');
      if (body === undefined) {
        body = itemEls[i];
      }
      const item: RankUserItem | undefined = RankHtmlParser.parseUserItem(body);
      if (item !== undefined) {
        items.push(item);
      }
    }
    return items;
  }

  /** 单用户条目：a[href^='/play/u'] userid；img[src] 头像；p 名次；a.t > span.u 用户名 / span.c 指标 */
  private static parseUserItem(b: Element): RankUserItem | undefined {
    const userLink: Element | undefined = RankHtmlParser.findFirstLinkByHrefPrefix(b, '/play/u');
    if (userLink === undefined) {
      return undefined;
    }
    const userId: string = RankHtmlParser.extractUid(HtmlParseUtil.attr(userLink, 'href'));

    // 用户名与趣味指标（a.t > span.u / span.c）
    let userName: string = '';
    let metricText: string = '';
    const tLink: Element | undefined = HtmlParseUtil.findOneByTagAndClass(b, 'a', 't');
    if (tLink !== undefined) {
      const uSpan: Element | undefined = RankHtmlParser.findDirectChildByTagAndClass(tLink, 'span', 'u');
      const cSpan: Element | undefined = RankHtmlParser.findDirectChildByTagAndClass(tLink, 'span', 'c');
      if (uSpan !== undefined) {
        userName = HtmlParseUtil.text(uSpan).trim();
      }
      if (cSpan !== undefined) {
        metricText = HtmlParseUtil.text(cSpan).trim();
      }
    }
    if (userName.length === 0) {
      userName = HtmlParseUtil.text(userLink).trim();
    }
    if (userName.length === 0) {
      return undefined;
    }

    // 头像（注意：u榜头像在 img 的 src 属性而非 style；相对路径绝对化）
    let avatar: string = '';
    const img: Element | undefined = HtmlParseUtil.findOneByTag(b, 'img');
    if (img !== undefined) {
      avatar = RankHtmlParser.toAbsolute(HtmlParseUtil.attr(img, 'src'));
    }

    // 名次（p 文本；n123=前三）
    let badgeText: string = '';
    let top3: boolean = false;
    const badgeEl: Element | undefined = HtmlParseUtil.findOneByTag(b, 'p');
    if (badgeEl !== undefined) {
      badgeText = HtmlParseUtil.text(badgeEl).trim();
      top3 = HtmlParseUtil.hasClass(badgeEl, 'n123');
    }

    return new RankUserItem(userId, userName, avatar, badgeText, top3, metricText);
  }

  // ==================== 热搜关键词条目 ====================

  /** .hot_search_list 条目解析：兼容 a 直接子元素与 .item > a 包裹两种结构（站点实际为 <div class="item"><a>…</a></div>） */
  private static parseKeywordItems(container: Element): RankKeywordItem[] {
    const items: RankKeywordItem[] = [];
    const children: Element[] = HtmlParseUtil.childElements(container);
    for (let i = 0; i < children.length; i++) {
      let link: Element | undefined = undefined;
      if (children[i].name === 'a') {
        link = children[i];
      } else {
        // a 包在 .item（div）内，取其后代首个 a
        link = HtmlParseUtil.findOneByTag(children[i], 'a');
      }
      if (link !== undefined) {
        const item: RankKeywordItem | undefined = RankHtmlParser.parseKeywordItem(link, i + 1);
        if (item !== undefined) {
          items.push(item);
        }
      }
    }
    return items;
  }

  /** 单关键词条目：排名 a > b；热度 a > span；关键词取 href info[title]= 参数解码；a.n123=前三 */
  private static parseKeywordItem(a: Element, fallbackRank: number): RankKeywordItem | undefined {
    const keyword: string = RankHtmlParser.extractKeyword(HtmlParseUtil.attr(a, 'href'));
    if (keyword.length === 0) {
      return undefined;
    }
    let rank: number = 0;
    const rankEl: Element | undefined = HtmlParseUtil.findOneByTag(a, 'b');
    if (rankEl !== undefined) {
      const parsed: number = Number(HtmlParseUtil.text(rankEl).trim());
      if (!Number.isNaN(parsed)) {
        rank = parsed;
      }
    }
    let heatText: string = '';
    const heatEl: Element | undefined = HtmlParseUtil.findOneByTag(a, 'span');
    if (heatEl !== undefined) {
      heatText = HtmlParseUtil.text(heatEl).trim();
    }
    return new RankKeywordItem(rank > 0 ? rank : fallbackRank,
      HtmlParseUtil.hasClass(a, 'n123'), keyword, heatText);
  }

  // ==================== 通用查找与提取 ====================

  /** 在线榜 .list：.main 下直接 .list；无 .main 时退化为全文档首个 .list */
  private static findOnlineList(doc: Document): Element | undefined {
    const mains: Element[] = HtmlParseUtil.findAllByClass(doc, 'main');
    if (mains.length > 0) {
      const list: Element | undefined = RankHtmlParser.findFirstByClass(mains[0], 'list');
      if (list !== undefined) {
        return list;
      }
    }
    return RankHtmlParser.findFirstByClass(doc, 'list');
  }

  /** 首个指定 class 后代元素 */
  private static findFirstByClass(root: Document | Element, className: string): Element | undefined {
    const found: Element[] = HtmlParseUtil.findAllByClass(root, className);
    return found.length > 0 ? found[0] : undefined;
  }

  /** 区块内首个 .list 容器 */
  private static findFirstList(scope: Element): Element | undefined {
    return RankHtmlParser.findFirstByClass(scope, 'list');
  }

  /** 区块标题（.time_title 文本） */
  private static sectionTitleOf(scope: Element): string {
    const titleEl: Element | undefined = RankHtmlParser.findFirstByClass(scope, 'time_title');
    return titleEl !== undefined ? HtmlParseUtil.text(titleEl).trim() : '';
  }

  /** 首个 href 以 prefix 开头的链接（后代查找） */
  private static findFirstLinkByHrefPrefix(scope: Element, prefix: string): Element | undefined {
    const links: Element[] = HtmlParseUtil.findAllByTag(scope, 'a');
    for (let i = 0; i < links.length; i++) {
      if (HtmlParseUtil.attr(links[i], 'href').startsWith(prefix)) {
        return links[i];
      }
    }
    return undefined;
  }

  /** 直接子元素按标签名 */
  private static findDirectChildByTag(el: Element, tagName: string): Element | undefined {
    const children: Element[] = HtmlParseUtil.childElements(el);
    for (let i = 0; i < children.length; i++) {
      if (children[i].name === tagName) {
        return children[i];
      }
    }
    return undefined;
  }

  /** 直接子元素按标签名 + class */
  private static findDirectChildByTagAndClass(el: Element, tagName: string, className: string):
    Element | undefined {
    const children: Element[] = HtmlParseUtil.childElements(el);
    for (let i = 0; i < children.length; i++) {
      if (children[i].name === tagName && HtmlParseUtil.hasClass(children[i], className)) {
        return children[i];
      }
    }
    return undefined;
  }

  /** 次指标含义（追番榜=追番数；无人区 metricText 自带「人错过」语义，无前缀；其余=播放数） */
  private static metricLabelOf(kind: RankKind): string {
    if (kind === RankKind.FAV) {
      return '追番';
    }
    if (kind === RankKind.ZERO) {
      return '';
    }
    return '播放';
  }

  /** href=/play/h{hid}/（可带分P锚点）→ hid */
  private static extractHid(href: string): string {
    const match: RegExpExecArray | null = new RegExp('/play/h(\\d+)').exec(href);
    if (match !== null && match.length > 1) {
      return match[1];
    }
    return '';
  }

  /** href=/play/u{uid}/ → uid */
  private static extractUid(href: string): string {
    const match: RegExpExecArray | null = new RegExp('/play/u(\\d+)').exec(href);
    if (match !== null && match.length > 1) {
      return match[1];
    }
    return '';
  }

  /** href 中 info[title]= 参数 → 关键词（+ 视作空格后 decodeURIComponent 解码） */
  private static extractKeyword(href: string): string {
    const match: RegExpExecArray | null = new RegExp('info\\[title\\]=([^&]*)').exec(href);
    if (match !== null && match.length > 1) {
      // PHP urlencode 将空格编码为 +，解码前先还原
      const raw: string = match[1].split('+').join(' ');
      try {
        return decodeURIComponent(raw);
      } catch (err) {
        return raw;
      }
    }
    return '';
  }

  /**
   * img 的 data-img 悬停预览帧列表（hot.html 实测 ",url1,url2" 与 "url1,url2" 两种格式统一处理：
   * 逗号切分后过滤空段再绝对化；gif 卡 data-img 为空 → 空数组，封面本身即动图。
   * 逻辑与 VideoRepository.extractPreviewFrames 对齐，为避免解析器反向依赖仓库层而本地镜像）
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
        frames.push(RankHtmlParser.toAbsolute(candidate));
      }
    }
    return frames;
  }

  /** style 属性内 background-image:url(...) 提取 */
  private static extractStyleUrl(style: string): string {    const marker: string = 'url(';
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

  /** 相对路径 → 绝对地址（u榜头像等；绝对地址原样返回） */
  private static toAbsolute(src: string): string {
    if (src.length === 0) {
      return '';
    }
    if (src.startsWith('http://') || src.startsWith('https://')) {
      return src;
    }
    if (src.startsWith('//')) {
      return `https:${src}`;
    }
    if (src.startsWith('/')) {
      return `${Host.BASE_RAW_API_URL}${src.substring(1)}`;
    }
    return `${Host.BASE_RAW_API_URL}${src}`;
  }
}
