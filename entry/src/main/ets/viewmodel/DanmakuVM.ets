/**
 * 弹幕视图模型
 *
 * 多页共存（详情页半屏 / 全屏播放页）：
 * - 每页 DanmakuView 各持一个引擎 Model；attach 登记、detach 注销，末位挂载者为激活模型
 * - 激活模型切换时暂停前一模型；detach 后回退剩余末位模型，由同步循环恢复至当前播放位置
 *
 * 时间轴对齐（250ms 轮询 VideoDetailVM 镜像态，对齐安卓 setTextAndProgress 300ms 轮询）：
 * - 播放中：引擎停走则 start(currentMs)；漂移超阈值 seekTo 校正（拖动/倍速累积）
 * - 非播放（暂停/缓冲/停止/错误/完成）：引擎走表则 pause()；偏差超阈值 start+pause 原子停靠
 * - 换集：partIndex 变化 → 重拉弹幕池并重绑（stop→prepare 重建引擎数据集）
 * - 倍速：滚动节奏按 danmakuSpeed*speed 补偿（对齐安卓 setScrollSpeedFactor(config*speed)），
 *   时间轴仍由漂移校正周期拉回（安卓不校正时间轴，本版为 spec  倍速跟随的增强）
 *
 * 分段偏移：VideoDetailVM.currentMs 为多段总时位，弹幕时间轴直接对齐总时位即可，
 * 无需安卓版 setSegmentOffset（偏差，见 plan.md 弹幕数据模型节）。
 *
 * 时钟源：DanmakuClock 抽象播放上下文读取，默认在线时钟包裹 VideoDetailVM；
 * OfflinePlayer 以 useOfflineClock 注入离线时钟（本地 danmu.xml + 离线播放态），
 * 页面退出时 restoreOnlineClock 还原，避免单例残留离线上下文污染在线弹幕。
 */
import { BaseDanmaku, DanmakuContext, DanmakuViewV2 } from '@ohos/danmakuflamemaster';
import { DanmuConst, PlayerId } from '../common/Constants';
import { PreferenceStore } from '../data/PreferenceStore';
import { Part, PlayerConfig, Video } from '../model/entity/BaseEntities';
import { DanmakuPool, DanmakuSendState } from '../model/entity/DanmakuEntities';
import { DanmakuService } from '../service/danmaku/DanmakuService';
import { PlayerCoreState } from '../service/player/PlayerController';
import { VideoDetailVM } from './VideoDetailVM';

/**
 * 弹幕时钟源：解耦 DanmakuVM 与具体播放上下文
 * - 在线：VideoDetailVM 镜像态（默认）
 * - 离线：OfflinePlayerVM 适配器（实现于 pages/OfflinePlayer.ets）
 * 时间轴语义统一为「当前分集本地时间轴」，离线侧由播放内核给出同轴值。
 */
export interface DanmakuClock {
  /** 当前视频（null = 未加载） */
  danmakuVideo(): Video | null;
  /** 当前分集下标（video.parts 下标） */
  danmakuPartIndex(): number;
  /** 弹幕时间轴当前位置（ms） */
  danmakuCurrentMs(): number;
  /** 是否正在播放（不含缓冲） */
  danmakuPlaying(): boolean;
  /** 播放倍速 */
  danmakuSpeed(): number;
  /** 本地弹幕文件路径（离线源返回 danmu.xml 绝对路径；在线源返回 null） */
  danmakuLocalPath(): string | null;
}

/** 在线时钟：包裹 VideoDetailVM 镜像态（默认时钟源） */
class OnlineDanmakuClock implements DanmakuClock {
  private readonly vm: VideoDetailVM;

  constructor(vm: VideoDetailVM) {
    this.vm = vm;
  }

  danmakuVideo(): Video | null {
    return this.vm.video;
  }

  danmakuPartIndex(): number {
    return this.vm.partIndex;
  }

  danmakuCurrentMs(): number {
    return this.vm.currentMs;
  }

  danmakuPlaying(): boolean {
    return this.vm.coreState === PlayerCoreState.PLAYING && !this.vm.isBuffering;
  }

  danmakuSpeed(): number {
    return this.vm.speed;
  }

  danmakuLocalPath(): string | null {
    return null;
  }
}

@ObservedV2
export class DanmakuVM {
  private static instance: DanmakuVM | null = null;

  static shared(): DanmakuVM {
    if (DanmakuVM.instance === null) {
      DanmakuVM.instance = new DanmakuVM();
    }
    return DanmakuVM.instance;
  }

  private constructor() {
    // 屏蔽词默认值（默认 http，对齐安卓 BlockListHelpers）
    if (this.config.blockList.length === 0 && DanmuConst.DEFAULT_BLOCK_WORDS.length > 0) {
      this.config.blockList = DanmuConst.DEFAULT_BLOCK_WORDS.slice();
    }
    this.lastDanmakuOn = this.config.danmakuOn;
  }

  /** 同步轮询间隔（ms） */
  private static readonly SYNC_INTERVAL_MS: number = 250;
  /** 时间轴漂移校正阈值（ms） */
  private static readonly DRIFT_CORRECT_MS: number = 600;
  /** 未 prepared 模型重绑自愈间隔（ms）：库 Model.prepare 对 null delegate 静默丢弃，需周期重试 */
  private static readonly REBIND_INTERVAL_MS: number = 2000;

  private readonly config: PlayerConfig = PreferenceStore.playerConfig();
  private readonly service: DanmakuService = DanmakuService.getInstance();
  /** 默认在线时钟 */
  private readonly onlineClock: OnlineDanmakuClock = new OnlineDanmakuClock(VideoDetailVM.shared());
  /** 当前时钟源（useOfflineClock 切换；restoreOnlineClock 还原；与 onlineClock 同实例表示在线态） */
  private clock: DanmakuClock = this.onlineClock;

  // ---------- 视图状态 ----------
  @Trace poolLoading: boolean = false;
  @Trace poolError: string = '';
  /** 在线池为空（提示"暂无弹幕"，输入框仍可用） */
  @Trace poolEmpty: boolean = false;
  @Trace sendState: DanmakuSendState = DanmakuSendState.IDLE;
  @Trace sendText: string = '';
  @Trace settingsOpen: boolean = false;

  // ---------- 模型管理 ----------
  private readonly models: DanmakuViewV2.Model[] = [];
  private readonly modelLineLimits: Map<DanmakuViewV2.Model, number> = new Map();
  private activeModel: DanmakuViewV2.Model | null = null;
  private currentPool: DanmakuPool | null = null;
  private currentPlayerId: string = '';
  /** 各模型已绑定的分集号（半屏/全屏多页共存时独立跟踪，防止一页绑定掩盖另一页的换集） */
  private readonly boundPartByModel: Map<DanmakuViewV2.Model, number> = new Map();
  private lastRebindAt: number = 0;
  private syncTimerId: number = -1;
  private lastEnginePlaying: boolean = false;
  /** 上次已下发的弹幕可见性（show/hide 变化驱动，见 syncTick） */
  private lastDanmakuOn: boolean = true;
  private lastSpeed: number = 1.0;
  private fetching: boolean = false;

  // ---------- 挂载/卸载 ----------

  /** 页面弹幕层挂载（aboutToAppear）：多页共存时后挂载者为激活模型，前一激活者暂停；
   *  绑定交给首个同步 tick（库子组件 aboutToAppear 先于 +250ms 执行，规避 delegate 竞态） */
  attach(model: DanmakuViewV2.Model, limitScrollLines: number): void {
    if (this.models.indexOf(model) < 0) {
      this.models.push(model);
    }
    this.modelLineLimits.set(model, limitScrollLines);
    const previous: DanmakuViewV2.Model | null = this.activeModel;
    this.activeModel = model;
    if (previous !== null && previous !== model) {
      previous.pause();
    }
    // 激活模型切换：作废走表/可见性记忆——新激活模型可能残留 attach 时的暂停/隐藏态，
    // 下一 tick 由 playing 分支 start() 重新起表、可见性块重申一次
    this.lastEnginePlaying = false;
    this.lastDanmakuOn = !this.config.danmakuOn;
    this.startSync();
  }

  /** 页面弹幕层卸载（aboutToDisappear）：解绑并回退激活模型 */
  detach(model: DanmakuViewV2.Model): void {
    const index: number = this.models.indexOf(model);
    if (index >= 0) {
      this.models.splice(index, 1);
    }
    this.modelLineLimits.delete(model);
    this.boundPartByModel.delete(model);
    this.service.unbindModel(model);
    if (this.activeModel === model) {
      this.activeModel = null;
      if (this.models.length > 0) {
        this.activeModel = this.models[this.models.length - 1];
        // 回退模型曾被 attach 暂停/隐藏：作废走表/可见性记忆，由同步循环复活并重申
        this.lastEnginePlaying = false;
        this.lastDanmakuOn = !this.config.danmakuOn;
      }
    }
    if (this.models.length === 0) {
      this.stopSync();
    }
  }

  // ---------- 时钟源切换 ----------

  /** 注入离线时钟（OfflinePlayer aboutToAppear）：切换后重绑当前激活模型（本地弹幕池） */
  useOfflineClock(clock: DanmakuClock): void {
    this.clock = clock;
    this.refreshPool();
  }

  /** 还原在线时钟（OfflinePlayer aboutToDisappear，必须调用）：避免单例残留离线上下文 */
  restoreOnlineClock(): void {
    this.clock = this.onlineClock;
    this.refreshPool();
  }

  /** 当前是否离线时钟（离线发送禁用 / 输入条禁用判定） */
  isOfflineClock(): boolean {
    return this.clock !== this.onlineClock;
  }

  /** 作废当前弹幕池并重绑激活模型（切时钟 / 弹幕文件更新成功后调用） */
  refreshPool(): void {
    this.currentPool = null;
    this.currentPlayerId = '';
    this.boundPartByModel.clear();
    const model: DanmakuViewV2.Model | null = this.activeModel;
    if (model !== null) {
      this.ensurePoolAndBind(model);
    }
  }

  // ---------- 弹幕池与绑定 ----------

  private async ensurePoolAndBind(model: DanmakuViewV2.Model): Promise<void> {
    if (this.fetching) {
      return;
    }
    const clock: DanmakuClock = this.clock;
    const video: Video | null = clock.danmakuVideo();
    if (video === null) {
      return;
    }
    const part: Part | undefined = video.parts[clock.danmakuPartIndex()];
    if (part === undefined) {
      return;
    }
    const playerId: string = PlayerId.generate(video.hid, part.order);
    if (this.currentPlayerId === playerId && this.currentPool !== null) {
      this.bindModelNow(model, this.currentPool);
      return;
    }
    this.fetching = true;
    this.poolLoading = true;
    this.poolError = '';
    try {
      const localPath: string | null = clock.danmakuLocalPath();
      let pool: DanmakuPool;
      if (localPath !== null) {
        pool = this.service.loadLocalPool(playerId, localPath);
      } else {
        pool = await this.service.fetchPool(playerId);
      }
      // 等待期间可能已换集/切时钟：丢弃过期结果，下一轮 syncTick 重试收敛
      if (clock !== this.clock) {
        return;
      }
      const currentVideo: Video | null = clock.danmakuVideo();
      if (currentVideo === null) {
        return;
      }
      const currentPart: Part | undefined = currentVideo.parts[clock.danmakuPartIndex()];
      if (currentPart === undefined) {
        return;
      }
      if (PlayerId.generate(currentVideo.hid, currentPart.order) !== playerId) {
        return;
      }
      this.currentPool = pool;
      this.currentPlayerId = playerId;
      this.poolError = pool.error;
      this.poolEmpty = pool.error.length === 0 && pool.danmakus.length === 0;
      // 等待期间页面可能已销毁
      if (this.models.indexOf(model) >= 0) {
        this.bindModelNow(model, pool);
      }
    } finally {
      this.fetching = false;
      this.poolLoading = false;
    }
  }

  private bindModelNow(model: DanmakuViewV2.Model, pool: DanmakuPool): void {
    const clock: DanmakuClock = this.clock;
    const limit: number = this.modelLineLimits.get(model) ?? 0;
    this.service.bindModel(model, pool, clock.danmakuCurrentMs(), clock.danmakuPlaying(),
      clock.danmakuSpeed(), limit);
    this.boundPartByModel.set(model, clock.danmakuPartIndex());
    this.lastEnginePlaying = clock.danmakuPlaying();
    this.lastSpeed = clock.danmakuSpeed();
  }

  // ---------- 同步循环 ----------

  private startSync(): void {
    if (this.syncTimerId >= 0) {
      return;
    }
    // 首个 tick 交给定时器（+250ms）：attach 同栈内库子组件尚未挂载，立即 tick 会踩 delegate 竞态
    this.syncTimerId = setInterval((): void => {
      this.syncTick();
    }, DanmakuVM.SYNC_INTERVAL_MS);
  }

  private stopSync(): void {
    if (this.syncTimerId >= 0) {
      clearInterval(this.syncTimerId);
      this.syncTimerId = -1;
    }
  }

  private syncTick(): void {
    const model: DanmakuViewV2.Model | null = this.activeModel;
    if (model === null) {
      return;
    }
    const clock: DanmakuClock = this.clock;
    const partIndex: number = clock.danmakuPartIndex();
    // 换集检测（按模型独立跟踪）：重拉弹幕池并重绑（fetching 期间跳过，完成后由下一轮重试收敛）；
    // 离线时钟换集 → danmakuLocalPath 随分集变化，自动重读本地 danmu.xml
    if (partIndex !== (this.boundPartByModel.get(model) ?? -1)) {
      this.ensurePoolAndBind(model);
      return;
    }
    if (!model.isPrepared()) {
      // 自愈重绑：库 Model.prepare 在 delegate（库子组件）挂载前会静默丢弃，
      // attach 后首绑/换集风暴均可能踩中；按间隔用缓存池重绑直至 prepared
      const now: number = Date.now();
      if (now - this.lastRebindAt > DanmakuVM.REBIND_INTERVAL_MS
        && this.currentPool !== null && this.currentPlayerId.length > 0) {
        this.lastRebindAt = now;
        this.bindModelNow(model, this.currentPool);
      }
      return;
    }
    // 倍速补偿滚动节奏（对齐安卓 setSpeed：config.danmakuSpeed * 播放倍速）
    if (clock.danmakuSpeed() !== this.lastSpeed) {
      this.lastSpeed = clock.danmakuSpeed();
      this.service.applyStyleToAll(this.config, clock.danmakuSpeed());
    }
    const playing: boolean = clock.danmakuPlaying();
    const currentMs: number = clock.danmakuCurrentMs();
    // 开关：变化驱动（原 250ms 无条件 show/hide 有害——库 show() 并非纯可见性切换，
    // 会清 quitFlag 并重启渲染动画：暂停态每 tick 复活引擎时钟，漂移超阈值又被
    // start+pause 停靠拉回 → 弹幕来回跳动；对齐安卓 showDanmu 仅在切换时调用。
    // 首绑/重绑的初始可见性由 DanmakuService.bindModel 的 prepared 回调负责）
    if (this.config.danmakuOn !== this.lastDanmakuOn) {
      this.lastDanmakuOn = this.config.danmakuOn;
      if (this.config.danmakuOn) {
        model.show();
        if (!playing) {
          // 暂停态开弹幕：show 复活的时钟立即重锚停靠，避免继续走表
          model.start(currentMs);
          model.pause();
        }
      } else {
        model.hide();
      }
    }
    if (playing) {
      if (!this.lastEnginePlaying) {
        // 播放恢复：从视频当前位置启动（引擎 resume 有阶梯重试延迟，弃用）
        model.start(currentMs);
      } else {
        const drift: number = model.getCurrentTime() - currentMs;
        if (Math.abs(drift) > DanmakuVM.DRIFT_CORRECT_MS) {
          // 用户拖动/倍速累积偏差：校正；用 start 而非 seekTo——库 view.seekTo
          // 不复位 quitFlag/渲染动画，跨页回退到被 attach 暂停过的模型时渲染已停，
          // start 兼具重锚与复活两者
          model.start(currentMs);
        }
      }
    } else {
      if (this.lastEnginePlaying) {
        // 暂停/缓冲/停止/错误/完成：停靠
        model.pause();
      }
      const drift: number = model.getCurrentTime() - currentMs;
      if (Math.abs(drift) > DanmakuVM.DRIFT_CORRECT_MS) {
        // 暂停态拖动：start+pause 原子停靠（SEEK_POS 自动恢复，配合 PAUSE 存在时序风险）
        model.start(currentMs);
        model.pause();
      }
    }
    this.lastEnginePlaying = playing;
  }

  // ---------- 发送 ----------

  /** 发送弹幕：本地立即回显 + POST（回显不受网络结果影响，发送静默失败，对齐安卓）；离线时钟禁发 */
  async sendDanmu(message: string): Promise<void> {
    const text: string = message.trim();
    if (text.length === 0) {
      return;
    }
    if (this.isOfflineClock()) {
      return; // 离线播放禁用发送
    }
    const clock: DanmakuClock = this.clock;
    const video: Video | null = clock.danmakuVideo();
    if (video === null) {
      return;
    }
    const part: Part | undefined = video.parts[clock.danmakuPartIndex()];
    if (part === undefined) {
      return;
    }
    const model: DanmakuViewV2.Model | null = this.activeModel;
    if (model === null || !model.isPrepared()) {
      return;
    }
    let context: DanmakuContext | null = null;
    try {
      context = model.getConfig();
    } catch (e) {
      context = null;
    }
    if (context === null) {
      return;
    }
    // 本地回显：engineTime+1200，红字白影绿边
    const echo: BaseDanmaku = this.service.createEchoDanmaku(context, model.getCurrentTime(), text);
    model.addDanmaku(echo);
    this.sendText = '';
    this.sendState = DanmakuSendState.SENDING;
    const playerId: string = PlayerId.generate(video.hid, part.order);
    const stimeSec: number = clock.danmakuCurrentMs() / 1000;
    const ok: boolean = await this.service.send(playerId, stimeSec, text);
    this.sendState = ok ? DanmakuSendState.SUCCESS : DanmakuSendState.FAILED;
  }

  // ---------- 设置（DanmakuSettingsDrawer 绑定；写操作即时下发引擎） ----------

  get danmakuOn(): boolean {
    return this.config.danmakuOn;
  }

  set danmakuOn(on: boolean) {
    this.config.danmakuOn = on;
    this.lastDanmakuOn = on;
    // syncTick 250ms 内也会应用，此处立即应用保证开关即时生效
    const model: DanmakuViewV2.Model | null = this.activeModel;
    if (model !== null && model.isPrepared()) {
      if (on) {
        model.show();
        if (!this.clock.danmakuPlaying()) {
          // 暂停态开弹幕：show 复活的时钟立即重锚停靠，避免继续走表
          model.start(this.clock.danmakuCurrentMs());
          model.pause();
        }
      } else {
        model.hide();
      }
    }
  }

  /** 弹幕不透明度 0.2~1.0（对齐安卓 20%~100%） */
  get danmakuOpacity(): number {
    return this.config.danmakuOpacity;
  }

  set danmakuOpacity(value: number) {
    this.config.danmakuOpacity = DanmakuVM.clamp(value, 0.2, 1.0);
    this.service.applyStyleToAll(this.config, this.clock.danmakuSpeed());
  }

  /** 弹幕字号倍率 0.5~2.0 */
  get danmakuScale(): number {
    return this.config.danmakuScale;
  }

  set danmakuScale(value: number) {
    this.config.danmakuScale = DanmakuVM.clamp(value, 0.5, 2.0);
    this.service.applyStyleToAll(this.config, this.clock.danmakuSpeed());
  }

  /** 弹幕滚动速度倍率 0.3~2.0（>1 更慢，<1 更快，引擎语义与安卓一致） */
  get danmakuSpeed(): number {
    return this.config.danmakuSpeed;
  }

  set danmakuSpeed(value: number) {
    this.config.danmakuSpeed = DanmakuVM.clamp(value, 0.3, 2.0);
    this.service.applyStyleToAll(this.config, this.clock.danmakuSpeed());
  }

  get blockEnable(): boolean {
    return this.config.blockEnable;
  }

  set blockEnable(enable: boolean) {
    this.config.blockEnable = enable;
    this.service.applyBlocklistToAll();
  }

  get blockWords(): string[] {
    return this.config.blockList;
  }

  /** 新增屏蔽词（去重、置顶，对齐安卓 BlockListHelpers.add） */
  addBlockWord(word: string): void {
    const text: string = word.trim();
    if (text.length === 0) {
      return;
    }
    const next: string[] = this.config.blockList.filter((w: string): boolean => w !== text);
    next.unshift(text);
    this.config.blockList = next;
    this.service.applyBlocklistToAll();
  }

  removeBlockWord(word: string): void {
    this.config.blockList = this.config.blockList.filter((w: string): boolean => w !== word);
    this.service.applyBlocklistToAll();
  }

  openSettings(): void {
    this.settingsOpen = true;
  }

  closeSettings(): void {
    this.settingsOpen = false;
  }

  private static clamp(value: number, min: number, max: number): number {
    return value < min ? min : (value > max ? max : value);
  }
}
