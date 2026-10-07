/**
 * 基础实体与三格式解析约定（D-Data Model）
 *
 * 三格式约定：Video 的同一实体有三个来源，解析入口统一收敛到本文件：
 * 1. api_v2 JSON（list/search/view/rank）→ Video.fromApiJson / Part.fromApiJson
 * 2. 站点 HTML 抓取（首页推荐等）→ HtmlParseUtil 构造 Record 后走 Video.fromApiJson（字段名对齐）
 * 3. 本地存储 JSON（star.json/history.json/download_catalog）→ Video.fromLocalJson / Video.toLocalRecord
 *
 * 所有实体使用 @ObservedV2 + @Trace（State Management V2）。
 */
import { PartSourceType } from '../../common/Constants';

/** 下载状态机（READY → OBTAIN_URL → CONNECTING → DOWNLOADING ⇄ PAUSED/FAILED → COMPLETED） */
export enum DownloadStatus {
  READY = 0,
  OBTAIN_URL = 1,
  CONNECTING = 2,
  DOWNLOADING = 3,
  PAUSED = 4,
  FAILED = 5,
  COMPLETED = 6
}

/** JSON 强转工具（ArkTS 禁 any，JSON.parse 产物统一经此处收窄） */
export class JsonCoerce {
  /** 解析文本为 Record，失败返回 undefined */
  static parseRecord(text: string): Record<string, Object> | undefined {
    try {
      const obj: Object | null = JSON.parse(text);
      if (obj === null || typeof obj !== 'object') {
        return undefined;
      }
      return obj as Record<string, Object>;
    } catch (err) {
      return undefined;
    }
  }

  /** 解析文本为对象数组，失败返回空数组 */
  static parseObjectArray(text: string): Object[] {
    try {
      const obj: Object | null = JSON.parse(text);
      if (obj !== null && Array.isArray(obj)) {
        return obj as Object[];
      }
      return [];
    } catch (err) {
      return [];
    }
  }

  /** 安全取字符串 */
  static asString(v: Object | undefined, dft: string = ''): string {
    return typeof v === 'string' ? v : dft;
  }

  /** 安全取数值（数字或数字字符串均接受；对齐安卓版 Moshi 对 "230" 等字符串数值的宽松转换） */
  static asNumber(v: Object | undefined, dft: number = 0): number {
    if (typeof v === 'number') {
      return v;
    }
    if (typeof v === 'string') {
      // 站点计数带千分位逗号（如 "34,847"），先剔除再解析
      const normalized: string = v.split(',').join('').trim();
      if (normalized.length === 0) {
        return dft;
      }
      const parsed: number = Number.parseFloat(normalized);
      return Number.isNaN(parsed) ? dft : parsed;
    }
    return dft;
  }

  /** 安全取布尔 */
  static asBoolean(v: Object | undefined, dft: boolean = false): boolean {
    return typeof v === 'boolean' ? v : dft;
  }

  /** 安全取 Record（非数组对象） */
  static asRecord(v: Object | undefined): Record<string, Object> | undefined {
    if (v !== null && v !== undefined && typeof v === 'object' && !Array.isArray(v)) {
      return v as Record<string, Object>;
    }
    return undefined;
  }

  /** 安全取对象数组 */
  static asObjectArray(v: Object | undefined): Object[] {
    if (v !== null && v !== undefined && Array.isArray(v)) {
      return v as Object[];
    }
    return [];
  }

  /** 安全取字符串数组 */
  static asStringArray(v: Object | undefined): string[] {
    const raw: Object[] = JsonCoerce.asObjectArray(v);
    const result: string[] = [];
    for (let i = 0; i < raw.length; i++) {
      const item: Object | undefined = raw[i];
      if (typeof item === 'string') {
        result.push(item);
      }
    }
    return result;
  }
}

/** 视频分段（playurl XML 的 durl / 下载任务的分片） */
@ObservedV2
export class Durl {
  /** 分段序号 */
  @Trace order: number = 0;
  /** 时长 ms */
  @Trace length: number = 0;
  /** 远程地址 */
  @Trace url: string = '';
  /** 本地缓存路径（下载后存在） */
  @Trace cachePath: string = '';
  /** 已下载字节数 */
  @Trace downloadedSize: number = 0;
  /** 分段总大小（Content-Length，未知为 -1） */
  @Trace totalSize: number = -1;
  /** 分段下载状态 */
  @Trace flag: DownloadStatus = DownloadStatus.READY;

  static fromApiJson(obj: Record<string, Object>): Durl {
    const d: Durl = new Durl();
    d.order = JsonCoerce.asNumber(obj['order']);
    d.length = JsonCoerce.asNumber(obj['length']);
    d.url = JsonCoerce.asString(obj['url']);
    return d;
  }
}

/** 视频分集（...） */
@ObservedV2
export class Part {
  /** 分集标题 */
  @Trace title: string = '';
  /** 分集序号（1 起） */
  @Trace order: number = 0;
  /** 分集 vid（playurl 接口参数） */
  @Trace vid: string = '';
  /** 站点类型原始串（api_v2 返回，如 youku/direct 等） */
  @Trace type: string = '';
  /** 播放来源类型（仓库层依据 type/file 推导，默认 PLAYURL） */
  @Trace sourceType: PartSourceType = PartSourceType.PLAYURL;
  /** 直连地址（DIRECT 类型时使用） */
  @Trace file: string = '';
  /** 分段列表 */
  @Trace durls: Durl[] = [];
  /** 下载状态 */
  @Trace flag: DownloadStatus = DownloadStatus.READY;
  /** 已下载字节数 */
  @Trace downloadSize: number = 0;
  /** 总字节数 */
  @Trace totalSize: number = 0;
  /** 已看标记 */
  @Trace hadPlay: boolean = false;
  /** 断点位置 ms */
  @Trace lastPlayPosition: number = 0;

  static fromApiJson(obj: Record<string, Object>): Part {
    const p: Part = new Part();
    p.title = JsonCoerce.asString(obj['title']);
    p.order = JsonCoerce.asNumber(obj['order']);
    p.vid = JsonCoerce.asString(obj['vid']);
    p.type = JsonCoerce.asString(obj['type']);
    return p;
  }

  /** 依据 durls 汇总刷新下载进度与状态 */
  refreshDownloadState(): void {
    let downloadSize: number = 0;
    let totalSize: number = 0;
    let hasFailed: boolean = false;
    let hasPaused: boolean = false;
    let hasDownloading: boolean = false;
    let hasReady: boolean = false;
    let allCompleted: boolean = this.durls.length > 0;
    for (let i = 0; i < this.durls.length; i++) {
      const d: Durl = this.durls[i];
      downloadSize += d.downloadedSize;
      if (d.totalSize > 0) {
        totalSize += d.totalSize;
      }
      if (d.flag === DownloadStatus.FAILED) {
        hasFailed = true;
        allCompleted = false;
      } else if (d.flag === DownloadStatus.PAUSED) {
        hasPaused = true;
        allCompleted = false;
      } else if (d.flag === DownloadStatus.DOWNLOADING || d.flag === DownloadStatus.CONNECTING
        || d.flag === DownloadStatus.OBTAIN_URL) {
        hasDownloading = true;
        allCompleted = false;
      } else if (d.flag === DownloadStatus.READY) {
        hasReady = true;
        allCompleted = false;
      }
    }
    this.downloadSize = downloadSize;
    this.totalSize = totalSize;
    if (hasFailed) {
      this.flag = DownloadStatus.FAILED;
    } else if (hasPaused) {
      this.flag = DownloadStatus.PAUSED;
    } else if (hasDownloading) {
      this.flag = DownloadStatus.DOWNLOADING;
    } else if (hasReady) {
      this.flag = DownloadStatus.READY;
    } else if (allCompleted) {
      this.flag = DownloadStatus.COMPLETED;
    }
  }
}

/** 视频（三格式实体，字段对齐安卓版 Video.kt） */
@ObservedV2
export class Video {
  @Trace hid: string = '';
  @Trace title: string = '';
  @Trace play: number = 0;
  @Trace mukio: number = 0;
  @Trace create: string = '';
  @Trace thumb: string = '';
  @Trace bg: string = '';
  /** 悬停预览帧列表（站点卡片 img 的 data-img 逗号切分；api_v2 JSON 无此字段，容错为空数组） */
  @Trace previewFrames: string[] = [];
  @Trace typeid: number = 0;
  @Trace typename: string = '';
  @Trace description: string = '';
  @Trace userid: string = '';
  @Trace user: string = '';
  @Trace keywords: string = '';
  /** 分集数量（与 parts.length 冗余存储，兼容本地序列化） */
  @Trace part: number = 0;
  /** 最后播放分集索引（0 起） */
  @Trace lastplay: number = 0;
  /** 是否已收藏 */
  @Trace isStarred: boolean = false;
  /** 下载态聚合（任一分集非 READY 即视为有下载） */
  @Trace downloadState: DownloadStatus = DownloadStatus.READY;
  /** 分集列表 */
  @Trace parts: Part[] = [];

  get partCount(): number {
    return this.parts.length > 0 ? this.parts.length : this.part;
  }

  get isSinglePart(): boolean {
    return this.partCount <= 1;
  }

  /** api_v2 JSON / HTML 中间结构（字段名一致）→ Video */
  static fromApiJson(obj: Record<string, Object>): Video {
    const v: Video = new Video();
    v.hid = JsonCoerce.asString(obj['hid']);
    v.title = JsonCoerce.asString(obj['title']);
    v.play = JsonCoerce.asNumber(obj['play']);
    v.mukio = JsonCoerce.asNumber(obj['mukio']);
    v.create = JsonCoerce.asString(obj['create']);
    v.thumb = JsonCoerce.asString(obj['thumb']);
    v.bg = JsonCoerce.asString(obj['bg']);
    v.previewFrames = JsonCoerce.asStringArray(obj['previewFrames']);
    v.typeid = JsonCoerce.asNumber(obj['typeid']);
    v.typename = JsonCoerce.asString(obj['typename']);
    v.description = JsonCoerce.asString(obj['description']);
    v.userid = JsonCoerce.asString(obj['userid']);
    v.user = JsonCoerce.asString(obj['user']);
    v.keywords = JsonCoerce.asString(obj['keywords']);
    v.part = JsonCoerce.asNumber(obj['part']);
    const rawParts: Object[] = JsonCoerce.asObjectArray(obj['video']);
    for (let i = 0; i < rawParts.length; i++) {
      const partObj: Record<string, Object> | undefined = JsonCoerce.asRecord(rawParts[i]);
      if (partObj !== undefined) {
        v.parts.push(Part.fromApiJson(partObj));
      }
    }
    if (v.part === 0 && v.parts.length > 0) {
      v.part = v.parts.length;
    }
    return v;
  }

  /** 本地存储 JSON（star.json/history.json/download_catalog）→ Video */
  static fromLocalJson(obj: Record<string, Object>): Video {
    const v: Video = Video.fromApiJson(obj);
    v.lastplay = JsonCoerce.asNumber(obj['lastplay']);
    v.isStarred = JsonCoerce.asBoolean(obj['isStarred']);
    v.downloadState = JsonCoerce.asNumber(obj['downloadState'], DownloadStatus.READY) as DownloadStatus;
    const rawParts: Object[] = JsonCoerce.asObjectArray(obj['parts']);
    if (rawParts.length > 0) {
      v.parts = [];
      for (let i = 0; i < rawParts.length; i++) {
        const partObj: Record<string, Object> | undefined = JsonCoerce.asRecord(rawParts[i]);
        if (partObj !== undefined) {
          const p: Part = Part.fromApiJson(partObj);
          p.file = JsonCoerce.asString(partObj['file']);
          p.sourceType = JsonCoerce.asNumber(partObj['sourceType'], PartSourceType.PLAYURL) as PartSourceType;
          p.flag = JsonCoerce.asNumber(partObj['flag'], DownloadStatus.READY) as DownloadStatus;
          p.downloadSize = JsonCoerce.asNumber(partObj['downloadSize']);
          p.totalSize = JsonCoerce.asNumber(partObj['totalSize']);
          p.hadPlay = JsonCoerce.asBoolean(partObj['hadPlay']);
          p.lastPlayPosition = JsonCoerce.asNumber(partObj['lastPlayPosition']);
          const rawDurls: Object[] = JsonCoerce.asObjectArray(partObj['durls']);
          for (let j = 0; j < rawDurls.length; j++) {
            const durlObj: Record<string, Object> | undefined = JsonCoerce.asRecord(rawDurls[j]);
            if (durlObj !== undefined) {
              const d: Durl = Durl.fromApiJson(durlObj);
              d.cachePath = JsonCoerce.asString(durlObj['cachePath']);
              d.downloadedSize = JsonCoerce.asNumber(durlObj['downloadedSize']);
              d.totalSize = JsonCoerce.asNumber(durlObj['totalSize'], -1);
              d.flag = JsonCoerce.asNumber(durlObj['flag'], DownloadStatus.READY) as DownloadStatus;
              p.durls.push(d);
            }
          }
          v.parts.push(p);
        }
      }
    }
    return v;
  }

  /** Video → 本地存储 Record（JSON.stringify 直接可序列化） */
  toLocalRecord(): Record<string, Object> {
    const parts: Object[] = [];
    for (let i = 0; i < this.parts.length; i++) {
      const p: Part = this.parts[i];
      const durls: Object[] = [];
      for (let j = 0; j < p.durls.length; j++) {
        const d: Durl = p.durls[j];
        const durlRecord: Record<string, Object> = {
          'order': d.order,
          'length': d.length,
          'url': d.url,
          'cachePath': d.cachePath,
          'downloadedSize': d.downloadedSize,
          'totalSize': d.totalSize,
          'flag': d.flag
        };
        durls.push(durlRecord);
      }
      const partRecord: Record<string, Object> = {
        'title': p.title,
        'order': p.order,
        'vid': p.vid,
        'type': p.type,
        'sourceType': p.sourceType,
        'file': p.file,
        'flag': p.flag,
        'downloadSize': p.downloadSize,
        'totalSize': p.totalSize,
        'hadPlay': p.hadPlay,
        'lastPlayPosition': p.lastPlayPosition,
        'durls': durls
      };
      parts.push(partRecord);
    }
    const record: Record<string, Object> = {
      'hid': this.hid,
      'title': this.title,
      'play': this.play,
      'mukio': this.mukio,
      'create': this.create,
      'thumb': this.thumb,
      'bg': this.bg,
      'previewFrames': this.previewFrames,
      'typeid': this.typeid,
      'typename': this.typename,
      'description': this.description,
      'userid': this.userid,
      'user': this.user,
      'keywords': this.keywords,
      'part': this.part,
      'lastplay': this.lastplay,
      'isStarred': this.isStarred,
      'downloadState': this.downloadState,
      'parts': parts
    };
    return record;
  }
}

/** 弹幕（在线 XML 与离线 danmu.xml 同一结构） */
export class Danmaku {
  /** 模式：1 滚动 / 4 底部 / 5 顶部 */
  mode: number = 1;
  /** 出现时间 ms */
  stime: number = 0;
  /** 颜色（十进制 RGB） */
  color: number = 16777215;
  /** 字号 */
  size: number = 25;
  /** 内容 */
  text: string = '';
  /** 弹幕池 */
  pool: number = 0;

  constructor(mode: number, stime: number, color: number, size: number, text: string, pool: number) {
    this.mode = mode;
    this.stime = stime;
    this.color = color;
    this.size = size;
    this.text = text;
    this.pool = pool;
  }
}

/** 用户（preferences:user 持久化，登录判定=name 非空） */
@ObservedV2
export class User {
  @Trace email: string = '';
  @Trace name: string = '';
  @Trace avatar: string = '';
  @Trace level: number = 0;
  @Trace signature: string = '';
  /** 未读私信数 */
  @Trace message: number = 0;

  /** 会话是否有效（2026-09 站点改版个人页已无邮箱行，email 不可得，登录锚点改为 name） */
  isValid(): boolean {
    return this.name.length > 0;
  }

  /** 清空会话 */
  invalidate(): void {
    this.email = '';
    this.name = '';
    this.avatar = '';
    this.level = 0;
    this.signature = '';
    this.message = 0;
  }

  static fromRecord(obj: Record<string, Object>): User {
    const u: User = new User();
    u.email = JsonCoerce.asString(obj['email']);
    u.name = JsonCoerce.asString(obj['name']);
    u.avatar = JsonCoerce.asString(obj['avatar']);
    u.level = JsonCoerce.asNumber(obj['level']);
    u.signature = JsonCoerce.asString(obj['signature']);
    u.message = JsonCoerce.asNumber(obj['message']);
    return u;
  }

  toRecord(): Record<string, Object> {
    const record: Record<string, Object> = {
      'email': this.email,
      'name': this.name,
      'avatar': this.avatar,
      'level': this.level,
      'signature': this.signature,
      'message': this.message
    };
    return record;
  }
}

/** 播放器配置（PersistenceV2：preferences:player_config） */
@ObservedV2
export class PlayerConfig {
  /** 自动连播 */
  @Trace autoNext: boolean = true;
  /** 记忆续播 */
  @Trace autoResume: boolean = true;
  /** 倍速（1.0/1.25/1.5/2.0） */
  @Trace speed: number = 1.0;
  /** 弹幕开关 */
  @Trace danmakuOn: boolean = true;
  /** 弹幕不透明度 0~1 */
  @Trace danmakuOpacity: number = 1.0;
  /** 弹幕缩放 */
  @Trace danmakuScale: number = 1.0;
  /** 弹幕速度 */
  @Trace danmakuSpeed: number = 1.0;
  /** 屏蔽词列表 */
  @Trace blockList: string[] = [];
  /** 屏蔽开关 */
  @Trace blockEnable: boolean = false;
}
