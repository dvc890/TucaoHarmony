/**
 * 弹幕系统实体与数据装载
 *
 * 对齐安卓版：
 * - 弹幕类型与 tucao XML p 属性 mode 字段一一对应（1 滚动 / 4 底部 / 5 顶部 / 6 左→右 / 7 特殊）
 * - 在线池：GET /index.php?m=mukio&c=index&a=init?playerID={id}&r={秒级时间戳}
 * - 本地池：离线下载目录 {downloadDir}/{hid}/p{order}/danmu.xml（OfflinePlayer 依赖 loadLocalPool）
 */
import { fileIo } from '@kit.CoreFileKit';
import { XmlApi } from '../../common/Constants';
import { Danmaku } from './BaseEntities';
import { TucaoApiClient } from '../../service/api/TucaoApiClient';
import { XmlParseUtil } from '../../service/api/XmlParseUtil';

/** 弹幕类型（对齐安卓 BaseDanmaku 类型常量与 tucao XML mode 字段） */
export class DanmakuMode {
  /** 从右向左滚动 */
  static readonly SCROLL_RL: number = 1;
  /** 底部固定 */
  static readonly FIX_BOTTOM: number = 4;
  /** 顶部固定 */
  static readonly FIX_TOP: number = 5;
  /** 从左向右滚动 */
  static readonly SCROLL_LR: number = 6;
  /** 特殊弹幕 */
  static readonly SPECIAL: number = 7;

  /** 归一化：未知类型回退为滚动弹幕 */
  static normalize(mode: number): number {
    if (mode === DanmakuMode.SCROLL_RL || mode === DanmakuMode.FIX_BOTTOM
      || mode === DanmakuMode.FIX_TOP || mode === DanmakuMode.SCROLL_LR
      || mode === DanmakuMode.SPECIAL) {
      return mode;
    }
    return DanmakuMode.SCROLL_RL;
  }
}

/** 弹幕池来源 */
export enum DanmakuPoolSource {
  /** 在线 mukio init 接口 */
  ONLINE = 0,
  /** 本地 danmu.xml（离线缓存） */
  LOCAL = 1
}

/** 弹幕池：一次分集的弹幕数据集 */
@ObservedV2
export class DanmakuPool {
  readonly playerId: string;
  readonly source: DanmakuPoolSource;
  readonly danmakus: Danmaku[];
  @Trace loading: boolean = false;
  @Trace error: string = '';

  constructor(playerId: string, source: DanmakuPoolSource, danmakus: Danmaku[]) {
    this.playerId = playerId;
    this.source = source;
    this.danmakus = danmakus;
  }
}

/** 弹幕发送状态 */
export enum DanmakuSendState {
  IDLE = 0,
  SENDING = 1,
  SUCCESS = 2,
  FAILED = 3
}

/** 弹幕池装载器：在线拉取（会话级缓存）/ 本地文件读取 */
export class DanmakuPoolLoader {
  private static onlineCache: Map<string, DanmakuPool> = new Map<string, DanmakuPool>();
  private static cacheOrder: string[] = [];
  private static readonly MAX_CACHE_SIZE: number = 8;

  private constructor() {
  }

  /** 拉取在线弹幕池（失败时返回 error 置位的空池，不抛异常） */
  static async fetchOnlinePool(playerId: string): Promise<DanmakuPool> {
    const cached: DanmakuPool | undefined = DanmakuPoolLoader.onlineCache.get(playerId);
    if (cached !== undefined) {
      return cached;
    }
    const pool: DanmakuPool = new DanmakuPool(playerId, DanmakuPoolSource.ONLINE, []);
    pool.loading = true;
    try {
      const params: Record<string, string> = {
        'playerID': playerId,
        'r': `${Math.floor(Date.now() / 1000)}`
      };
      const xmlText: string = await TucaoApiClient.getInstance().getXmlText(XmlApi.DANMU_INIT, params);
      const danmakus: Danmaku[] = XmlParseUtil.parseDanmaku(xmlText);
      for (let i = 0; i < danmakus.length; i++) {
        pool.danmakus.push(danmakus[i]);
      }
      DanmakuPoolLoader.putCache(pool);
    } catch (e) {
      pool.error = '弹幕加载失败';
    } finally {
      pool.loading = false;
    }
    return pool;
  }

  /** 读取本地弹幕文件（绝对路径；文件不存在/读取失败时返回 error 置位的空池，不抛异常） */
  static loadLocalPool(playerId: string, danmuPath: string): DanmakuPool {
    const pool: DanmakuPool = new DanmakuPool(playerId, DanmakuPoolSource.LOCAL, []);
    pool.loading = true;
    try {
      if (!fileIo.accessSync(danmuPath)) {
        pool.error = '本地弹幕文件不存在';
        return pool;
      }
      const xmlText: string = fileIo.readTextSync(danmuPath);
      const danmakus: Danmaku[] = XmlParseUtil.parseDanmaku(xmlText);
      for (let i = 0; i < danmakus.length; i++) {
        pool.danmakus.push(danmakus[i]);
      }
    } catch (e) {
      pool.error = '本地弹幕读取失败';
    } finally {
      pool.loading = false;
    }
    return pool;
  }

  private static putCache(pool: DanmakuPool): void {
    if (DanmakuPoolLoader.onlineCache.has(pool.playerId)) {
      return;
    }
    DanmakuPoolLoader.onlineCache.set(pool.playerId, pool);
    DanmakuPoolLoader.cacheOrder.push(pool.playerId);
    while (DanmakuPoolLoader.cacheOrder.length > DanmakuPoolLoader.MAX_CACHE_SIZE) {
      const oldest: string | undefined = DanmakuPoolLoader.cacheOrder.shift();
      if (oldest === undefined) {
        break;
      }
      DanmakuPoolLoader.onlineCache.delete(oldest);
    }
  }
}
