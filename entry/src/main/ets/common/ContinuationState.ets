/**
 * 多端应用接续状态（§4.1/§4.3）
 * 三件套：
 * - ContinuePayload：接续状态协议（wantParam 单键 'tucao.cont' 打包的 JSON，约 200 字节）。
 *   最小充分集 {hid, partIndex, positionMs, playing, title}，与 HistoryService 断点体系
 *   语义完全同构（hid + lastplay/partIndex + lastPlayPosition/positionMs）；刻意不传
 *   durls 直链/cookie/heroParam（目标端重拉公开详情+直链，绕开 PHP 会话跨端不通）。
 *   自定义键不得与系统预置键（version/targetDevice）重名——统一收在单键字符串内。
 * - ContinuationSlot：进程内接续槽单例。EntryAbility（onCreate/onNewWant 的 CONTINUATION
 *   分支）写入 → Index 骨架 aboutToAppear peek 导航直达详情页 → VideoDetailVM.loadDetail
 *   按 hid takeIfMatch 消费续播。不选 AppStorage 直塞：项目状态管理统一走单例体系。
 * - MissionContinueSwitch：接续入口动态开关（setMissionContinueState 包装）。仅播放场景
 *   向系统全局接续入口亮出本应用（Index 路由拦截按落位页驱动），对齐官方"接续一般用于
 *   长时间停留页面"建议；失败重置去重标记，下次导航幂等重试自愈。
 */
import { AbilityConstant } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppContextHolder } from './GlobalState';

const DOMAIN = 0x0000;
const TAG = 'TucaoContinuation';

/** 接续状态协议（源端 onContinue 采集 → wantParam → 目标端 onCreate/onNewWant 解析） */
export class ContinuePayload {
  /** wantParam 携带键（单键打包，规避与系统预置键冲突） */
  static readonly WANT_KEY: string = 'tucao.cont';

  /** 视频 hid（目标端重拉详情的唯一标识，必填） */
  hid: string = '';
  /** 当前分集索引（对应 video.lastplay 语义） */
  partIndex: number = 0;
  /** 分集内多段总时位 ms（对应 part.lastPlayPosition 语义） */
  positionMs: number = 0;
  /** 源端是否正在播放（true=目标端自动续播；false=封面态+续播条） */
  playing: boolean = false;
  /** 标题快照（详情未加载完时的接续提示，可选） */
  title: string = '';
  /** 分集名快照（同上，可选） */
  partTitle: string = '';
  /** 源端采集时间戳（调试用，可选） */
  ts: number = 0;

  /** 序列化为 wantParam 单键字符串（Record 字面量显式类型，键加引号） */
  static toJson(payload: ContinuePayload): string {
    const obj: Record<string, Object> = {
      'hid': payload.hid,
      'partIndex': payload.partIndex,
      'positionMs': payload.positionMs,
      'playing': payload.playing,
      'title': payload.title,
      'partTitle': payload.partTitle,
      'ts': payload.ts
    };
    return JSON.stringify(obj);
  }

  /** 反序列化（解析失败/hid 缺失返回 null，按普通启动处理；不依赖 JsonCoerce 以保持 common 层自包含） */
  static fromJson(json: string): ContinuePayload | null {
    let raw: Object | null = null;
    try {
      raw = JSON.parse(json);
    } catch (_err) {
      return null;
    }
    if (raw === null || typeof raw !== 'object') {
      return null;
    }
    const obj: Record<string, Object> = raw as Record<string, Object>;
    const payload: ContinuePayload = new ContinuePayload();
    payload.hid = ContinuePayload.asText(obj['hid']);
    payload.partIndex = ContinuePayload.asNum(obj['partIndex']);
    payload.positionMs = ContinuePayload.asNum(obj['positionMs']);
    payload.playing = ContinuePayload.asBool(obj['playing']);
    payload.title = ContinuePayload.asText(obj['title']);
    payload.partTitle = ContinuePayload.asText(obj['partTitle']);
    payload.ts = ContinuePayload.asNum(obj['ts']);
    if (payload.hid.length === 0) {
      return null;
    }
    return payload;
  }

  private static asText(v: Object | undefined): string {
    return typeof v === 'string' ? v as string : '';
  }

  private static asNum(v: Object | undefined): number {
    return typeof v === 'number' ? v as number : 0;
  }

  private static asBool(v: Object | undefined): boolean {
    return typeof v === 'boolean' ? v as boolean : false;
  }
}

/**
 * 接续槽（进程内单例）：EntryAbility 写入，Index peek 导航，VideoDetailVM 按 hid 消费。
 * 消费语义：详情拉取失败时接续点保留在槽内（重试成功后仍可续播）；导航到其他视频
 * 视为接续意图已被取代（takeIfMatch 不命中即清槽）。
 */
export class ContinuationSlot {
  private static instance: ContinuationSlot | undefined;

  static shared(): ContinuationSlot {
    if (ContinuationSlot.instance === undefined) {
      ContinuationSlot.instance = new ContinuationSlot();
    }
    return ContinuationSlot.instance;
  }

  private payload: ContinuePayload | null = null;

  private constructor() {
  }

  /** 写入接续数据（onCreate/onNewWant 的 CONTINUATION 分支） */
  set(payload: ContinuePayload): void {
    this.payload = payload;
  }

  /** 窥视接续数据（Index 导航用，不消费——续播点由 VM 按 hid 消费） */
  peek(): ContinuePayload | null {
    return this.payload;
  }

  /** 按 hid 消费：命中则取出并清槽；不命中（已被其他视频的 loadDetail 取代）同样清槽 */
  takeIfMatch(hid: string): ContinuePayload | null {
    const cur: ContinuePayload | null = this.payload;
    if (cur === null) {
      return null;
    }
    this.payload = null;
    if (cur.hid !== hid) {
      hilog.info(DOMAIN, TAG, '[Continuation] 接续槽被取代清空: slot=%{public}s cur=%{public}s', cur.hid, hid);
      return null;
    }
    return cur;
  }

  /** 清槽 */
  clear(): void {
    this.payload = null;
  }
}

/**
 * 接续入口动态开关：仅播放场景（在线详情/全屏）向系统接续入口亮出本应用，
 * 首页/其余页面隐藏（onContinue REJECT 之外的双保险，天然规避"首页发起接续
 * 该传什么"的边界问题）。去重：状态未变跳过；失败重置标记，下次导航重试。
 */
export class MissionContinueSwitch {
  /** 当前期望状态（同步置值；null = 下发失败，允许重试） */
  private static lastActive: boolean | null = null;

  static setActive(active: boolean): void {
    hilog.info(DOMAIN, TAG, '[ContinueSwitch] setActive want=%{public}s last=%{public}s',
      `${active}`, `${MissionContinueSwitch.lastActive}`);
    if (MissionContinueSwitch.lastActive === active) {
      hilog.info(DOMAIN, TAG, '[ContinueSwitch] skip (same as last)');
      return;
    }
    const context = AppContextHolder.get();
    if (context === null) {
      hilog.warn(DOMAIN, TAG, '[ContinueSwitch] no context, abort');
      return;
    }
    const state: AbilityConstant.ContinueState = active
      ? AbilityConstant.ContinueState.ACTIVE : AbilityConstant.ContinueState.INACTIVE;
    // 同步置值消除竞态：promise 异步回填时，接续入槽段 true→false→true 三连发会读到
    // 过期缓存把末次 setActive 吞掉，系统 state 卡在 0（不可接续），反向接续失败
    MissionContinueSwitch.lastActive = active;
    hilog.info(DOMAIN, TAG, '[ContinueSwitch] dispatching state=%{public}s', `${active}`);
    context.setMissionContinueState(state)
      .catch((err: BusinessError): void => {
        MissionContinueSwitch.lastActive = null;
        hilog.warn(DOMAIN, TAG, 'setMissionContinueState failed: %{public}s', JSON.stringify(err));
      });
  }
}
