/**
 * 全局路由契约
 * - 单一 NavPathStack：Index 骨架 aboutToAppear 时 init，全应用共享
 * - 参数纪律：仅 hid / 轻量 id / 轻量枚举；大对象一律经 VM 单例传递
 * - 目标页面随各用户故事在 resources/base/profile/router_map.json 增量注册；
 *   未注册时 push 仅告警不崩溃
 */

import { HeroCardParam, PlayerExpandParam } from './HeroTransition';

/** 楼中楼详情参数（tid + rid 两个轻量 id 打包） */
export class ReplyFloorParam {
  tid: number = 0;
  rid: number = 0;

  constructor(tid: number, rid: number) {
    this.tid = tid;
    this.rid = rid;
  }
}

/** 搜索页水波揭示入场参数（首页悬浮球点击时采集，px 窗口坐标） */
export class SearchRevealParam {
  /** 悬浮球圆心 x（px，窗口坐标） */
  centerXpx: number = 0;
  /** 悬浮球圆心 y（px，窗口坐标） */
  centerYpx: number = 0;
  /** 悬浮球直径 px */
  diameterPx: number = 0;
}

export class Router {
  private static stack: NavPathStack | null = null;

  /** Index 骨架初始化时注入共享路由栈 */
  static init(stack: NavPathStack): void {
    Router.stack = stack;
  }

  /** 取共享路由栈（未初始化返回 null，供需直接操作栈的场景判空） */
  static navPathStack(): NavPathStack | null {
    return Router.stack;
  }

  /** 返回上一页 */
  static back(): void {
    if (Router.stack !== null) {
      Router.stack.pop();
    }
  }

  /** 视频详情页（参数 = { hid } 轻量对象，与一镜到底共用同一路由面） */
  static goVideoDetail(hid: string): void {
    const param: Record<string, Object> = { 'hid': hid };
    Router.push('VideoDetail', param);
  }

  /** 视频详情页（卡片 hero 连续缩放：额外携带 HeroCardParam，未生成时降级为普通进入） */
  static goVideoDetailWithTransition(hid: string, heroParam: HeroCardParam | undefined): void {
    const param: Record<string, Object> = { 'hid': hid };
    if (heroParam !== undefined && heroParam !== null) {
      param['heroParam'] = heroParam;
    }
    Router.push('VideoDetail', param);
  }

  /** 全屏播放页（播放上下文经 PlayerVM 单例传递） */
  static goPlayer(hid: string): void {
    Router.push('Player', hid);
  }

  /** 全屏播放页（半屏 → 全屏连续缩放：额外携带 PlayerExpandParam，未生成时降级为普通进入） */
  static goPlayerWithTransition(hid: string, expandParam: PlayerExpandParam | undefined): void {
    const param: Record<string, Object> = { 'hid': hid };
    if (expandParam !== undefined && expandParam !== null) {
      param['expandParam'] = expandParam;
    }
    Router.push('Player', param);
  }

  /** 离线播放页（本地缓存播放，上下文经 PlayerVM 单例传递） */
  static goOfflinePlayer(hid: string): void {
    Router.push('OfflinePlayer', hid);
  }

  /** 离线缓存列表页 */
  static goDownload(): void {
    Router.push('Download', null);
  }

  /** 下载设置页 */
  static goDownloadSettings(): void {
    Router.push('DownloadSettings', null);
  }

  /** 排行榜页 */
  static goRank(): void {
    Router.push('Rank', null);
  }

  /** 放送表页 */
  static goShowtime(): void {
    Router.push('Showtime', null);
  }

  /** 历史新番页 */
  static goAnimeTime(): void {
    Router.push('AnimeTime', null);
  }

  /** 频道详情页（tid 为轻量枚举型频道 id） */
  static goChannelDetail(tid: number): void {
    Router.push('ChannelDetail', tid);
  }

  /** UP 主空间页（api_v2 userid 为字符串） */
  static goUploader(userId: string): void {
    Router.push('Uploader', userId);
  }

  /** 内置浏览器页 */
  static goBrowser(url: string): void {
    Router.push('Browser', url);
  }

  /** 搜索页（可携带初始关键词） */
  static goSearch(keyword: string = ''): void {
    Router.push('Search', keyword);
  }

  /** 搜索页·悬浮球入口（携带 SearchRevealParam：Search 页以悬浮球圆心播放水波圆形揭示入场，
   *  替代系统推入转场；keyword 可选初始关键词） */
  static goSearchWithReveal(revealParam: SearchRevealParam, keyword: string = ''): void {
    const param: Record<string, Object> = { 'keyword': keyword, 'revealParam': revealParam };
    Router.push('Search', param);
  }

  /** 登录页 */
  static goLogin(): void {
    Router.push('Login', null);
  }

  /** 注册页 */
  static goRegister(): void {
    Router.push('Register', null);
  }

  /** 忘记密码页 */
  static goForgotPassword(): void {
    Router.push('ForgotPassword', null);
  }

  /** 个人中心页 */
  static goPersonal(): void {
    Router.push('Personal', null);
  }

  /** 楼中楼详情页 */
  static goReplyFloor(tid: number, rid: number): void {
    Router.push('ReplyFloor', new ReplyFloorParam(tid, rid));
  }

  /** 短消息会话列表页 */
  static goMessageList(): void {
    Router.push('MessageList', null);
  }

  /** 短消息详情页（所选会话经 MessageVM 单例传递） */
  static goMessageDetail(): void {
    Router.push('MessageDetail', null);
  }

  /** 我的收藏页 */
  static goStar(): void {
    Router.push('Star', null);
  }

  /** 历史记录页 */
  static goPlayHistory(): void {
    Router.push('PlayHistory', null);
  }

  /** 关于页 */
  static goAbout(): void {
    Router.push('About', null);
  }

  /** 设置页 */
  static goSettings(): void {
    Router.push('Settings', null);
  }

  private static push(name: string, param: Object | null): void {
    const stack: NavPathStack | null = Router.stack;
    if (stack === null) {
      return;
    }
    if (param === null) {
      stack.pushPathByName(name, null);
    } else {
      stack.pushPathByName(name, param);
    }
  }
}
