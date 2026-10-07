/**
 * 视频数据仓库
 * 编排 TucaoApiClient 与实体解析，产出 VM 可用数据：
 * - 首页推荐：HTML 抓取（RawApi.INDEX）→ 轮播 Banner + 「今天推荐」+ 六分组
 *   （站点结构：div.focus>div.slide 轮播；div.list.list8 今日推荐；div.list.loop_list{tid} 六分组；
 *    div.xf_list 今天番组与 div.list_hot 排行榜不属首页推荐解析范围，规避 div.list 污染）
 * - 频道列表：api_v2 list.php（tid/order/page，实测可用，干净 JSON）
 * - 视频详情：api_v2 view.php
 * - 播放地址：三分支（对齐安卓版 VideoViewModel.queryPlayUrls）：
 *    1) 已下载分集 → 直接返回本地 durls（本地优先）
 *    2) 直连分集（file 非空）→ DIRECT 单段；含 clicli 则走 clicli 解析（桌面 UA）
 *    3) 其余 → playurl XML（type/vid/r）→ 多段 durls
 * - 分集规整：order 按索引、标题空缺补「第N集」、直传合成 vid={hid}{order}（对齐 checkInit 硬约定）
 */
import { Element } from 'domhandler';
import { TucaoApiClient, TucaoApiError } from '../../service/api/TucaoApiClient';
import { HtmlParseUtil } from '../../service/api/HtmlParseUtil';
import { XmlParseUtil } from '../../service/api/XmlParseUtil';
import { JsonCoerce, Part, Durl, DownloadStatus, Video } from '../entity/BaseEntities';
import {
  Host,
  HttpConst,
  JsonApi,
  PartSourceType,
  RawApi,
  SortOrder,
  XmlApi
} from '../../common/Constants';

/** 首页推荐分组（标题 + 跳转 tid + 视频卡片列表） */
export class RecommendGroup {
  readonly title: string;
  readonly tid: number;
  readonly videos: Video[];

  constructor(title: string, tid: number, videos: Video[]) {
    this.title = title;
    this.tid = tid;
    this.videos = videos;
  }
}

/** 首页推荐解析结果 */
export class IndexPage {
  readonly banners: Video[];
  readonly groups: RecommendGroup[];

  constructor(banners: Video[], groups: RecommendGroup[]) {
    this.banners = banners;
    this.groups = groups;
  }
}

/** 频道列表分页结果 */
export class ChannelListPage {
  readonly videos: Video[];
  readonly total: number;
  readonly page: number;

  constructor(videos: Video[], total: number, page: number) {
    this.videos = videos;
    this.total = total;
    this.page = page;
  }
}

/** 首页六分组的站点标题（对齐站点 div.title 文案；tid 与 loop_list{tid} 类名一致） */
export class HomeGroupTable {
  static readonly ALL: Array<Array<Object>> = [
    ['连载新番', 11],
    ['电视剧', 39],
    ['天朝出品', 43],
    ['电影', 38],
    ['剧场版', 26],
    ['完结番组', 10]
  ];
}

export class VideoRepository {
  private static instance: VideoRepository | undefined;

  static getInstance(): VideoRepository {
    if (VideoRepository.instance === undefined) {
      VideoRepository.instance = new VideoRepository();
    }
    return VideoRepository.instance;
  }

  /** 首页 HTML → 轮播 + 分组推荐 */
  async fetchIndex(): Promise<IndexPage> {
    const client: TucaoApiClient = TucaoApiClient.getInstance();
    const html: string = await client.getRawText(RawApi.INDEX);
    return VideoRepository.parseIndex(html);
  }

  /** 频道列表（api_v2 list.php 分页） */
  async fetchChannelList(tid: number, order: SortOrder, page: number, pagesize: number): Promise<ChannelListPage> {
    const params: Record<string, string> = {
      'tid': `${tid}`,
      'page': `${page}`,
      'pagesize': `${pagesize}`,
      'order': order
    };
    const record: Record<string, Object> = await TucaoApiClient.getInstance().getApiV2(JsonApi.LIST, params);
    VideoRepository.assertApiCode(record);
    const total: number = JsonCoerce.asNumber(record['total_count']);
    const rawList: Object[] = JsonCoerce.asObjectArray(record['result']);
    const videos: Video[] = [];
    for (let i = 0; i < rawList.length; i++) {
      const item: Record<string, Object> | undefined = JsonCoerce.asRecord(rawList[i]);
      if (item !== undefined) {
        videos.push(VideoRepository.parseVideoRecord(item));
      }
    }
    return new ChannelListPage(videos, total, page);
  }

  /** 视频详情（api_v2 view.php） */
  async fetchVideoDetail(hid: string): Promise<Video> {
    const params: Record<string, string> = {
      'hid': hid
    };
    const record: Record<string, Object> = await TucaoApiClient.getInstance().getApiV2(JsonApi.VIEW, params);
    VideoRepository.assertApiCode(record);
    const result: Record<string, Object> | undefined = JsonCoerce.asRecord(record['result']);
    if (result === undefined) {
      throw new TucaoApiError('视频详情响应缺少 result 字段', -1);
    }
    return VideoRepository.parseVideoRecord(result);
  }

  /** playurl XML → 多段 durls（空结果抛错；src 指定清晰度，空串=站点默认） */
  async fetchPlayUrls(type: string, vid: string, src: string = ''): Promise<Durl[]> {
    const params: Record<string, string> = {
      'type': type,
      'vid': vid,
      'r': `${Math.floor(Date.now() / 1000)}`
    };
    if (src.length > 0) {
      params['src'] = src;
    }
    const xmlText: string =
      await TucaoApiClient.getInstance().getXmlText(XmlApi.PLAY_URL, params);
    const result = XmlParseUtil.parsePlayUrl(xmlText);
    if (!result.hasUrl) {
      throw new TucaoApiError('请求视频接口出错', -1);
    }
    return result.durls;
  }

  /** clicli 解析：file 本身即解析接口地址，返回 JSON {code:0, url} */
  async fetchClicliUrl(file: string): Promise<string> {
    const text: string =
      await TucaoApiClient.getInstance().getTextWithUA(file, HttpConst.CHROME_UA);
    const record: Record<string, Object> | undefined = JsonCoerce.parseRecord(text);
    if (record === undefined) {
      throw new TucaoApiError('clicli 响应不是合法 JSON 对象', -1);
    }
    const code: number = JsonCoerce.asNumber(record['code'], -1);
    const url: string = JsonCoerce.asString(record['url']);
    if (code !== 0 || url.length === 0) {
      throw new TucaoApiError('请求视频接口出错', -1);
    }
    return url;
  }

  /**
   * 分集播放地址解析（三分支，对齐安卓 queryPlayUrls）
   * 已下载（COMPLETED 且有本地 durls）优先直接返回，供 PlayerController 走本地播放。
   */
  async resolvePartDurls(part: Part): Promise<Durl[]> {
    if (part.flag === DownloadStatus.COMPLETED && part.durls.length > 0) {
      return part.durls;
    }
    if (part.file.length > 0) {
      if (!part.file.includes('clicli')) {
        // 直传视频：file 即播放地址；2026-09-19 起站点前置 301/302 跳转层，
        // AVPlayer 不跟随重定向（5400106），先解析最终直链再交付播放
        const resolved: string = await TucaoApiClient.getInstance().resolveEffectiveUrl(part.file);
        const direct: Durl = new Durl();
        direct.order = 0;
        direct.url = resolved;
        direct.flag = DownloadStatus.COMPLETED;
        return [direct];
      }
      // clicli 源：动态地址解析
      const url: string = await this.fetchClicliUrl(part.file);
      const durl: Durl = new Durl();
      durl.order = 0;
      durl.url = url;
      return [durl];
    }
    // 标准 playurl XML（多段）
    return await this.fetchPlayUrls(part.type, part.vid);
  }

  /** 首页 HTML 解析（独立函数便于单测与结构回归） */
  static parseIndex(html: string): IndexPage {
    const doc = HtmlParseUtil.parse(html);
    const banners: Video[] = VideoRepository.parseBanners(doc);
    const groups: RecommendGroup[] = [];
    // 今天推荐（div.list.list8）
    const todayList: Element | undefined = HtmlParseUtil.findOneByTagAndClass(doc, 'div', 'list8');
    if (todayList !== undefined) {
      const videos: Video[] = VideoRepository.parseItemList(todayList);
      if (videos.length > 0) {
        groups.push(new RecommendGroup('今天推荐', 0, videos));
      }
    }
    // 六分组（div.list.loop_list{tid}）
    for (let i = 0; i < HomeGroupTable.ALL.length; i++) {
      const entry: Array<Object> = HomeGroupTable.ALL[i];
      const title: string = entry[0] as string;
      const tid: number = entry[1] as number;
      const listEl: Element | undefined =
        HtmlParseUtil.findOneByTagAndClass(doc, 'div', `loop_list${tid}`);
      if (listEl !== undefined) {
        const videos: Video[] = VideoRepository.parseItemList(listEl);
        if (videos.length > 0) {
          groups.push(new RecommendGroup(title, tid, videos));
        }
      }
    }
    return new IndexPage(banners, groups);
  }

  /** 轮播解析：div.slide 内 a.i 为真实封面，a.t 内 div 为标题、p 为简介 */
  private static parseBanners(root: Element | object): Video[] {
    const banners: Video[] = [];
    const slides: Element[] = HtmlParseUtil.findAllByTagAndClass(root as Element, 'div', 'slide');
    for (let i = 0; i < slides.length; i++) {
      const slide: Element = slides[i];
      const imageLink: Element | undefined = HtmlParseUtil.findOneByTagAndClass(slide, 'a', 'i');
      const textLink: Element | undefined = HtmlParseUtil.findOneByTagAndClass(slide, 'a', 't');
      if (imageLink === undefined) {
        continue;
      }
      const hid: string = VideoRepository.extractHid(HtmlParseUtil.attr(imageLink, 'href'));
      if (hid.length === 0) {
        // 外链公告位（/play/d{id}/）不进视频流
        continue;
      }
      const img: Element | undefined = HtmlParseUtil.findOneByTag(imageLink, 'img');
      const thumb: string = img !== undefined
        ? VideoRepository.toAbsolute(HtmlParseUtil.attr(img, 'src'))
        : '';
      const previewFrames: string[] = img !== undefined
        ? VideoRepository.extractPreviewFrames(img)
        : [];
      let title: string = '';
      let description: string = '';
      if (textLink !== undefined) {
        const titleDiv: Element | undefined = HtmlParseUtil.findOneByTag(textLink, 'div');
        if (titleDiv !== undefined) {
          title = HtmlParseUtil.text(titleDiv).trim();
        }
        const descP: Element | undefined = HtmlParseUtil.findOneByTag(textLink, 'p');
        if (descP !== undefined) {
          description = HtmlParseUtil.text(descP).trim();
        }
      }
      if (title.length === 0) {
        title = `视频 ${hid}`;
      }
      const record: Record<string, Object> = {
        'hid': hid,
        'title': title,
        'thumb': thumb,
        'previewFrames': previewFrames,
        'description': description
      };
      banners.push(Video.fromApiJson(record));
    }
    return banners;
  }

  /** 分组条目解析：div.item 内 a.vp（封面+hid）/ a.t（标题）/ div.i（播放数+UP主） */
  private static parseItemList(listEl: Element): Video[] {
    const videos: Video[] = [];
    const items: Element[] = HtmlParseUtil.findAllByTagAndClass(listEl, 'div', 'item');
    for (let i = 0; i < items.length; i++) {
      const item: Element = items[i];
      const vpLink: Element | undefined = HtmlParseUtil.findOneByTagAndClass(item, 'a', 'vp');
      if (vpLink === undefined) {
        continue;
      }
      const hid: string = VideoRepository.extractHid(HtmlParseUtil.attr(vpLink, 'href'));
      if (hid.length === 0) {
        continue;
      }
      const thumb: string = VideoRepository.extractItemThumb(vpLink);
      const previewFrames: string[] = VideoRepository.extractItemPreviewFrames(vpLink);
      const titleLink: Element | undefined = HtmlParseUtil.findOneByTagAndClass(item, 'a', 't');
      const title: string = titleLink !== undefined ? HtmlParseUtil.text(titleLink).trim() : '';
      let play: number = 0;
      let user: string = '';
      let userid: string = '';
      const infoDiv: Element | undefined = HtmlParseUtil.findOneByTagAndClass(item, 'div', 'i');
      if (infoDiv !== undefined) {
        const playSpan: Element | undefined = HtmlParseUtil.findOneByTag(infoDiv, 'span');
        if (playSpan !== undefined) {
          play = JsonCoerce.asNumber(HtmlParseUtil.text(playSpan).trim());
        }
        const userLink: Element | undefined = HtmlParseUtil.findOneByTag(infoDiv, 'a');
        if (userLink !== undefined) {
          user = HtmlParseUtil.text(userLink).trim();
          userid = VideoRepository.extractUserid(HtmlParseUtil.attr(userLink, 'href'));
        }
      }
      if (title.length === 0) {
        continue;
      }
      const record: Record<string, Object> = {
        'hid': hid,
        'title': title,
        'play': play,
        'thumb': thumb,
        'previewFrames': previewFrames,
        'user': user,
        'userid': userid
      };
      videos.push(Video.fromApiJson(record));
    }
    return videos;
  }

  /** 条目封面：a.vp 内 img 的 style background-image 为真实封面，data-img 首张为备选，img src 为兜底 */
  private static extractItemThumb(vpLink: Element): string {
    const img: Element | undefined = HtmlParseUtil.findOneByTag(vpLink, 'img');
    if (img === undefined) {
      return '';
    }
    const styleUrl: string = VideoRepository.extractStyleUrl(HtmlParseUtil.attr(img, 'style'));
    if (styleUrl.length > 0) {
      return styleUrl;
    }
    const dataImg: string = HtmlParseUtil.attr(img, 'data-img');
    if (dataImg.length > 0) {
      const parts: string[] = dataImg.split(',');
      for (let i = 0; i < parts.length; i++) {
        const candidate: string = parts[i].trim();
        if (candidate.startsWith('http')) {
          return candidate;
        }
      }
    }
    return VideoRepository.toAbsolute(HtmlParseUtil.attr(img, 'src'));
  }

  /** 条目悬停预览帧：a.vp 内 img 的 data-img 按逗号切分、过滤空段、绝对化归一 */
  private static extractItemPreviewFrames(vpLink: Element): string[] {
    const img: Element | undefined = HtmlParseUtil.findOneByTag(vpLink, 'img');
    if (img === undefined) {
      return [];
    }
    return VideoRepository.extractPreviewFrames(img);
  }

  /**
   * img 的 data-img 悬停预览帧列表（",url1,url2" 或 "url1,url2" 两种实测格式统一处理：
   * 逗号切分后过滤空段；少数 gif 卡 data-img 为空 → 空数组，封面本身即动图）
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
        frames.push(VideoRepository.toAbsolute(candidate));
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
    let end: number = style.indexOf(')', start);
    if (end < 0) {
      return '';
    }
    let raw: string = style.substring(start, end).trim();
    if (quote.length > 0 && raw.endsWith(quote)) {
      raw = raw.substring(0, raw.length - 1);
    }
    return raw;
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

  /** api_v2 回执校验（code:"200"；异常抛 TucaoApiError 携带 msg） */
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
      throw new TucaoApiError(`[${code}] ${msg}`, -1);
    }
  }

  /** api_v2 视频对象 → Video（补齐 file 字段 + 分集规整） */
  static parseVideoRecord(obj: Record<string, Object>): Video {
    const video: Video = Video.fromApiJson(obj);
    const rawParts: Object[] = JsonCoerce.asObjectArray(obj['video']);
    for (let i = 0; i < video.parts.length && i < rawParts.length; i++) {
      const partObj: Record<string, Object> | undefined = JsonCoerce.asRecord(rawParts[i]);
      if (partObj !== undefined) {
        video.parts[i].file = JsonCoerce.asString(partObj['file']);
      }
    }
    VideoRepository.normalizeParts(video);
    return video;
  }

  /** 分集规整（对齐安卓 checkInit 硬约定） */
  static normalizeParts(video: Video): void {
    for (let i = 0; i < video.parts.length; i++) {
      const part: Part = video.parts[i];
      part.order = i;
      if (part.title.length === 0) {
        part.title = `第${i + 1}集`;
      }
      if (part.durls.length === 0 && part.file.length > 0) {
        part.vid = `${video.hid}${i}`;
        part.sourceType = part.file.includes('clicli') ? PartSourceType.CLICLI : PartSourceType.DIRECT;
      } else {
        part.sourceType = PartSourceType.PLAYURL;
      }
    }
  }
}
