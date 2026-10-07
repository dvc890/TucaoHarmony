/**
 * 播放内核控制器（AVPlayer 状态机 /  播放列表）
 * - 单例：VideoDetailVM / Player 页面共享同一实例，跨页续播不断流
 * - 加载链路（PLAYLIST 模式）：resolvePartDurls → createAVPlayer → setMediaSource(首段)
 *   → surfaceId → addPlaybackMediaSource(余段) → prepare → 段内 seek → play
 * - 兜底（SEQUENTIAL 模式）：addPlaybackMediaSource 异常时逐段 setMediaSource，
 *   completed 手动推进（接缝有轻微停顿）；模式自动降级，不影响对外接口
 * - 状态机：IDLE→LOADING→PREPARING→READY→PLAYING⇄PAUSED→COMPLETED→STOPPED/ERROR
 * - 失败重试 ≤3 次指数退避（1s/2s/4s），重试前重新解析地址（clicli/过期直链换新）；
 *   稳定播放 30s 后重试预算清零，长会话内多次独立故障不累计误判
 * - 假完成守卫（BUG C）：拉流断供时引擎可能误报 completed/error（实测 part 播 2 分半
 *   被误标已看并触发自动连播，或弹误导性 UNSUPPORT_FORMAT），completed 时距已知
 *   结尾超容差即拦截，保住真实进度走可重试重载而非假收尾
 * - 并发防护：loadingToken 递增使旧异步链路全部作废，避免快速切集竞态
 * - 本地播放：durl.cachePath 非空走 fd 源（SegmentPlaylist 内处理）
 * -  扩展点：onSegmentChanged 携带分段偏移，弹幕时间轴 = 段偏移 + 段内时间
 */
import { media } from '@kit.MediaKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Durl, Part, Video } from '../../model/entity/BaseEntities';
import { VideoRepository } from '../../model/repository/VideoRepository';
import { SegmentPlaylist } from './SegmentPlaylist';

/** 播放内核状态（页面展示态由 VideoDetailVM 再映射） */
export enum PlayerCoreState {
  /** 空闲（未加载或已释放） */
  IDLE = 0,
  /** 地址解析/实例创建中 */
  LOADING = 1,
  /** prepare 中 */
  PREPARING = 2,
  /** prepared（可播放） */
  READY = 3,
  PLAYING = 4,
  PAUSED = 5,
  COMPLETED = 6,
  STOPPED = 7,
  ERROR = 8
}

/** 播放模式：播放列表拼接 / 逐段手动推进 */
export enum PlaybackMode {
  PLAYLIST = 0,
  SEQUENTIAL = 1
}

/** 播放回调集合（VM 注入；字段可空，未注入即忽略） */
export class PlayerCallbacks {
  /** 内核状态变化 */
  onStateChange: ((state: PlayerCoreState) => void) | null = null;
  /** 进度（总时位/总时长，ms） */
  onProgress: ((currentMs: number, totalMs: number) => void) | null = null;
  /** 分段切换（索引 + 该段起始偏移，弹幕对齐用） */
  onSegmentChanged: ((index: number, offsetMs: number) => void) | null = null;
  /** 错误（是否可重试） */
  onError: ((message: string, retryable: boolean) => void) | null = null;
  /** prepared（可播放） */
  onPrepared: (() => void) | null = null;
  /** 本分集播完（PLAYLIST=末段播完；SEQUENTIAL=末段播完） */
  onCompletion: (() => void) | null = null;
  /** 缓冲中状态变化 */
  onBuffering: ((busy: boolean) => void) | null = null;
}

/** 播放内核单例 */
export class PlayerController {
  private static instance: PlayerController | undefined;

  static getInstance(): PlayerController {
    if (PlayerController.instance === undefined) {
      PlayerController.instance = new PlayerController();
    }
    return PlayerController.instance;
  }

  /** AVPlayer 实例（未加载为 null） */
  private player: media.AVPlayer | null = null;
  /** 分段簿记 */
  private playlist: SegmentPlaylist | null = null;
  /** 回调集合 */
  private callbacks: PlayerCallbacks = new PlayerCallbacks();

  /** 当前视频 */
  private video: Video | null = null;
  /** 当前分集索引 */
  private partIndex: number = 0;
  /** 当前分集分段 */
  private segments: Durl[] = [];
  /** 播放模式（加载失败自动降级为 SEQUENTIAL） */
  private mode: PlaybackMode = PlaybackMode.PLAYLIST;
  /** 并发令牌：每次加载递增，旧链路检查后自弃 */
  private loadingToken: number = 0;
  /** 错误重试计数（用户主动 load 重置；重试路径保留累计；稳定播放 30s 后清零） */
  private retryCount: number = 0;
  /** 错误重试上限 */
  private static readonly MAX_RETRY: number = 3;
  /** 重试定时器 */
  private retryTimer: number = -1;
  /** 稳定播放重试预算重置定时器（连续播放 30s 视为链路健康，预算清零） */
  private retryResetTimer: number = -1;
  /** 稳定播放判定阈值 ms */
  private static readonly RETRY_RESET_AFTER_MS: number = 30000;
  /** 假完成守卫容差 ms：completed 时距已知结尾不足该值视为正常收尾（含时长元数据噪声） */
  private static readonly COMPLETION_TOLERANCE_MS: number = 15000;
  /** 假完成验证位置：拦截后若重载在同一位置再次完成（±10s），视为时长元数据虚高的真实片尾放行 */
  private verifyCompletionMs: number = -1;
  /** 进度推送定时器（500ms，独立于 timeUpdate 保证滑杆流畅） */
  private progressTimer: number = -1;
  /** 起播看门狗定时器（LOADING→首个 PLAYING 期间超时则报错，避免"永远转圈"） */
  private startWatchdog: number = -1;
  /** 源初始化等待的解算器（handleState 收到 initialized/error 时触发，一次即弃） */
  private initSettler: ((state: string) => void) | null = null;
  /** 起播看门狗阈值 ms（含解析/建实例/prepare/起播缓冲） */
  private static readonly START_WATCHDOG_MS: number = 24000;
  /** 展示 surface（XComponent） */
  private surfaceId: string = '';
  /** 加载完成后的自动播放 */
  private autoPlay: boolean = true;
  /** prepared 后待执行的起点 seek（总时位） */
  private pendingSeekMs: number = 0;
  /** 倍速（跨实例记忆，prepared 后重放） */
  private speed: number = 1.0;
  /** 音量 0~1（应用内软件音量） */
  private volume: number = 1.0;
  /** 画面缩放模式（跨实例记忆，prepared 后重放；FIT=拉伸为 AVPlayer 默认，故默认原比例） */
  private scaleType: media.VideoScaleType = media.VideoScaleType.VIDEO_SCALE_TYPE_SCALED_ASPECT;

  /** 内核状态 */
  state: PlayerCoreState = PlayerCoreState.IDLE;
  /** 总时位 ms */
  currentMs: number = 0;
  /** 总时长 ms（分段长度已知时精确，否则当前段时长） */
  totalMs: number = 0;
  /** 缓冲中 */
  isBuffering: boolean = false;

  private constructor() {
  }

  /** 注入回调（整体替换） */
  setCallbacks(callbacks: PlayerCallbacks): void {
    this.callbacks = callbacks;
  }

  /** 当前视频 */
  getVideo(): Video | null {
    return this.video;
  }

  /** 当前分集索引 */
  getPartIndex(): number {
    return this.partIndex;
  }

  /** 分集分段（供 UI 倍速/清晰度等展示） */
  getSegments(): Durl[] {
    return this.segments;
  }

  /** 播放模式 */
  getPlaybackMode(): PlaybackMode {
    return this.mode;
  }

  /** 倍速 */
  getSpeed(): number {
    return this.speed;
  }

  /** 应用内音量 0~1 */
  getVolume(): number {
    return this.volume;
  }

  /**
   * 设置显示 surface（XComponent onLoad 回调传入）
   * - initialized：首次设置（加载链路内应用）
   * - prepared/playing/paused/completed/stopped：官方支持运行中换窗，
   *   视频画面迁移到新窗口继续播（详情页半屏 ⇄ 全屏页共用同一 AVPlayer，验证点）
   * - 未加载：缓存，load 时应用
   */
  setSurfaceId(surfaceId: string): void {
    this.surfaceId = surfaceId;
    if (this.player === null) {
      return;
    }
    if (this.state === PlayerCoreState.READY || this.state === PlayerCoreState.PLAYING
      || this.state === PlayerCoreState.PAUSED || this.state === PlayerCoreState.COMPLETED
      || this.state === PlayerCoreState.STOPPED) {
      try {
        this.player.surfaceId = surfaceId;
      } catch (err) {
        // 换窗失败忽略（旧窗口继续渲染）
      }
    }
  }

  /**
   * 加载分集（自动播放）
   * @param video      视频（含 parts）
   * @param partIndex  分集索引（0 起）
   * @param startMs    起播总时位（断点续播）
   */
  async load(video: Video, partIndex: number, startMs: number): Promise<void> {
    this.retryCount = 0;
    this.verifyCompletionMs = -1;
    await this.internalLoad(video, partIndex, startMs, true, null);
  }

  /**
   * 以显式分段加载（清晰度切换换源 /  离线播放直供 durls，跳过仓库解析）
   */
  async loadSegments(video: Video, partIndex: number, segments: Durl[], startMs: number): Promise<void> {
    this.retryCount = 0;
    this.verifyCompletionMs = -1;
    await this.internalLoad(video, partIndex, startMs, true, segments);
  }

  /** 重试加载（沿用上次 video/partIndex，从错误时位置继续） */
  private async retryLoad(): Promise<void> {
    if (this.video === null) {
      return;
    }
    const video: Video = this.video;
    const partIndex: number = this.partIndex;
    const startMs: number = this.currentMs;
    await this.internalLoad(video, partIndex, startMs, true, null);
  }

  /** 内部加载实现（resolved 非空时跳过仓库解析；重试路径不重置 retryCount） */
  private async internalLoad(video: Video, partIndex: number, startMs: number, play: boolean,
    resolved: Durl[] | null): Promise<void> {
    const token: number = ++this.loadingToken;
    this.video = video;
    this.partIndex = partIndex;
    this.autoPlay = play;
    this.pendingSeekMs = startMs;
    this.currentMs = startMs;
    this.totalMs = 0;
    this.isBuffering = false;
    this.stopTimers();
    await this.releasePlayer(token);
    if (token !== this.loadingToken) {
      return; // 已被更新的一次加载取代
    }
    this.updateState(PlayerCoreState.LOADING);
    this.startStartWatchdog(token);

    // 1. 解析播放地址（显式传入优先；否则本地 COMPLETED 优先，三分支见 resolvePartDurls）
    const part: Part | undefined = video.parts[partIndex];
    if (part === undefined) {
      this.fail('分集不存在', false, token);
      return;
    }
    let segments: Durl[] = [];
    if (resolved !== null) {
      segments = resolved;
    } else {
      try {
        segments = await VideoRepository.getInstance().resolvePartDurls(part);
      } catch (err) {
        // 地址解析失败进入重试（换新直链/clicli）
      }
    }
    if (token !== this.loadingToken) {
      return;
    }
    const usable: Durl[] = segments.filter((d: Durl): boolean => d.url.length > 0 || d.cachePath.length > 0);
    if (usable.length === 0) {
      this.fail('暂无可用播放地址', true, token);
      return;
    }
    this.segments = usable;
    this.mode = PlaybackMode.PLAYLIST;

    // 2. 创建实例并注册事件
    let player: media.AVPlayer;
    try {
      player = await media.createAVPlayer();
    } catch (err) {
      this.fail('播放器创建失败', true, token);
      return;
    }
    if (token !== this.loadingToken) {
      this.destroyQuietly(player);
      return;
    }
    this.player = player;
    this.registerEvents(player);

    // 3. 播放列表：首段 setMediaSource（idle→initialized），余段 addPlaybackMediaSource
    const playlist: SegmentPlaylist = new SegmentPlaylist(player);
    playlist.onSegmentChanged = (index: number): void => {
      this.currentMs = playlist.totalPositionMs();
      if (this.callbacks.onSegmentChanged !== null) {
        this.callbacks.onSegmentChanged(index, playlist.offsetBeforeIndex(index));
      }
    };
    this.playlist = playlist;
    const first: media.MediaSource | undefined = playlist.begin(usable);
    if (first === undefined) {
      this.fail('播放源不可用', true, token);
      return;
    }
    try {
      await player.setMediaSource(first);
    } catch (err) {
      this.fail('播放源设置失败', true, token);
      return;
    }
    if (token !== this.loadingToken) {
      return;
    }
    // setMediaSource 后状态异步迁入 initialized（实测 6~43ms，URL 源尤甚）：
    // surfaceId 赋值与 prepare 均要求 initialized，冒进会被 5400102 拒绝并把播放器带崩
    const initOk: boolean = await this.waitForSourceInit(player, token);
    if (token !== this.loadingToken) {
      return;
    }
    if (!initOk) {
      // 源加载失败（error 事件已由 error 监听器上抛）；此处不再重复 fail
      return;
    }
    if (this.surfaceId.length > 0) {
      player.surfaceId = this.surfaceId;
    }
    // 余段追加；任一段失败降级 SEQUENTIAL（首段继续播，不整体失败）
    for (let i = 1; i < usable.length; i++) {
      const source: media.MediaSource | undefined = playlist.appendSource(i);
      if (source === undefined) {
        this.mode = PlaybackMode.SEQUENTIAL;
        break;
      }
      try {
        const id: string = await player.addPlaybackMediaSource(source);
        playlist.registerSourceId(i, id);
      } catch (err) {
        this.mode = PlaybackMode.SEQUENTIAL;
        break;
      }
      if (token !== this.loadingToken) {
        return;
      }
    }

    // 4. prepare →（prepared 回调内）seek 起播
    this.updateState(PlayerCoreState.PREPARING);
    try {
      await player.prepare();
    } catch (err) {
      this.fail(this.describePrepareError(), true, token);
    }
  }

  /** 播放错误描述（http 明文 https 回退仍失败时显式说明，/ 不静默） */
  private describePlaybackError(code: number): string {
    if (code === media.AVErrorCode.AVERR_UNSUPPORT_FORMAT) {
      // 站点 API 回归期推荐位死链频发：view.php 空 token → 302 跳转 → 播放器报
      // 5400106——实态是链接失效而非设备不支持编码，按真实语义提示（真不支持
      // 编码在 prepare 期即失败走加载失败文案，播放期命中本码以死链为主）
      return '视频不可用：链接已失效或已被删除';
    }
    if (this.playlist !== null && this.playlist.hasUsedHttpsFallback()) {
      return `播放出错(${code})：媒体地址为 http 明文，已尝试 https 同主机回退仍失败`;
    }
    return `播放出错(${code})`;
  }

  /**
   * 播放期瞬态错误判定（可销毁重建恢复）：
   * 官方对 IO(5400103)/超时(5400104) 的处置即"销毁实例并重新创建"；
   * UNSUPPORT_FORMAT(5400106) 实测在模拟器网络断供时被误报（CDN 与编码均正常），
   * 播放中报出时优先按断供处置；真不支持编码在 prepare 期即失败，走加载期全重试路径
   */
  private static isTransientPlaybackError(code: number): boolean {
    return code === media.AVErrorCode.AVERR_NO_MEMORY
      || code === media.AVErrorCode.AVERR_OPERATE_NOT_PERMIT
      || code === media.AVErrorCode.AVERR_IO
      || code === media.AVErrorCode.AVERR_TIMEOUT
      || code === media.AVErrorCode.AVERR_SERVICE_DIED
      || code === media.AVErrorCode.AVERR_UNSUPPORT_FORMAT;
  }

  /** prepare 失败描述（同上，回退场景显式说明） */
  private describePrepareError(): string {
    if (this.playlist !== null && this.playlist.hasUsedHttpsFallback()) {
      return '视频加载失败：媒体地址为 http 明文，已尝试 https 同主机回退仍失败';
    }
    return '视频加载失败';
  }

  /**
   * 等待媒体源就绪（idle → initialized 异步跃迁）。
   * setMediaSource 仅发起异步加载，真正就绪以 stateChange='initialized' 为准；
   * surfaceId/prepare 前置要求，未就绪调用会被 5400102（Operation Not Permit）拒绝。
   * 返回 false 表示源加载失败（已触 error，不重复上抛）。
   */
  private waitForSourceInit(player: media.AVPlayer, token: number): Promise<boolean> {
    return new Promise<boolean>((resolve) => {
      let settled: boolean = false;
      const finish = (ok: boolean): void => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimeout(timer);
        if (this.initSettler === onState) {
          this.initSettler = null;
        }
        resolve(ok);
      };
      const onState = (state: string): void => {
        // 状态回调统一由 registerEvents 的常驻监听路由，避免临时监听 + off
        // 在部分 SDK 版本把常驻 stateChange 一并移除（起播永远收不到 prepared）
        if (state === 'initialized') {
          finish(true);
        } else if (state === 'error') {
          finish(false);
        }
      };
      this.initSettler = onState;
      const timer = setTimeout((): void => {
        // 兜底：事件已错过时按当前状态判定，仍 idle 则放行让 prepare 暴露真实错误
        finish(player.state === 'initialized');
      }, 8000);
      // 已就绪（事件先于本次监听注册）时立即结束等待
      if (player.state === 'initialized') {
        finish(true);
      }
    });
  }

  /** 继续播放 */
  async play(): Promise<void> {
    if (this.player === null) {
      return;
    }
    if (this.state === PlayerCoreState.READY || this.state === PlayerCoreState.PAUSED
      || this.state === PlayerCoreState.COMPLETED) {
      if (this.state === PlayerCoreState.COMPLETED) {
        // 播完重播从头
        this.pendingSeekMs = 0;
      }
      try {
        await this.player.play();
      } catch (err) {
        // 状态不允许时忽略（记录观测：死点击排查）
        hilog.warn(0x0000, 'PlayerController', `[play] 被拒: state=${this.state}`);
      }
    }
  }

  /** 暂停 */
  async pause(): Promise<void> {
    if (this.player === null) {
      return;
    }
    if (this.state === PlayerCoreState.PLAYING) {
      try {
        await this.player.pause();
      } catch (err) {
        // 忽略（记录观测：实测断供场景 pause 可能被引擎拒绝）
        hilog.warn(0x0000, 'PlayerController', `[pause] 被拒: state=${this.state}`);
        return;
      }
      const player: media.AVPlayer | null = this.player;
      if (player !== null && player.state === 'playing') {
        // 调用成功但引擎仍在播（状态迁移在途或引擎内部异常）：记录观测
        hilog.warn(0x0000, 'PlayerController', `[pause] 未生效: engineState=${player.state}`);
      }
    }
  }

  /** 切换播放/暂停 */
  async togglePlay(): Promise<void> {
    if (this.state === PlayerCoreState.PLAYING) {
      await this.pause();
    } else {
      await this.play();
    }
  }

  /** 总时位 seek（跨段自动 advance） */
  async seekTotal(totalMs: number): Promise<void> {
    if (this.player === null || this.playlist === null) {
      return;
    }
    if (this.state !== PlayerCoreState.READY && this.state !== PlayerCoreState.PLAYING
      && this.state !== PlayerCoreState.PAUSED && this.state !== PlayerCoreState.COMPLETED) {
      this.pendingSeekMs = totalMs; // 未就绪：延迟到 prepared 执行
      return;
    }
    this.currentMs = totalMs;
    const pos = this.playlist.mapTotal(totalMs);
    try {
      if (pos.index !== this.playlist.getCurrentIndex()) {
        if (this.mode === PlaybackMode.PLAYLIST && this.playlist.getSourceId(pos.index).length > 0) {
          await this.player.advanceToMediaSource(this.playlist.getSourceId(pos.index));
        } else {
          // SEQUENTIAL 跨段：换段 + 段内精确 seek（旧实现只到段头）
          await this.switchSegmentSequential(pos.index, pos.withinMs);
          return;
        }
      }
      this.player.seek(pos.withinMs);
    } catch (err) {
      // seek 失败忽略（保持原位置）
      hilog.warn(0x0000, 'PlayerController', `[seek] 失败: total=${totalMs}ms → 段${pos.index}+${pos.withinMs}ms`);
    }
  }

  /** 倍速（prepared 后即时生效；未就绪则记忆，prepared 后应用） */
  async setSpeed(rate: number): Promise<void> {
    this.speed = rate;
    if (this.player === null) {
      return;
    }
    if (this.state === PlayerCoreState.READY || this.state === PlayerCoreState.PLAYING
      || this.state === PlayerCoreState.PAUSED || this.state === PlayerCoreState.COMPLETED) {
      try {
        await this.player.setSpeed(PlayerController.toPlaybackSpeed(rate));
      } catch (err) {
        // 忽略
      }
    }
  }

  /** 应用内音量 0~1 */
  async setVolume(volume: number): Promise<void> {
    this.volume = Math.min(1.0, Math.max(0.0, volume));
    if (this.player === null) {
      return;
    }
    if (this.state === PlayerCoreState.READY || this.state === PlayerCoreState.PLAYING
      || this.state === PlayerCoreState.PAUSED) {
      try {
        await this.player.setVolume(this.volume);
      } catch (err) {
        // 忽略
      }
    }
  }

  /** 画面缩放（prepared 后即时生效；未就绪则记忆，prepared 后应用） */
  async setScale(type: media.VideoScaleType): Promise<void> {
    this.scaleType = type;
    const player: media.AVPlayer | null = this.player;
    if (player === null) {
      return;
    }
    if (this.state === PlayerCoreState.READY || this.state === PlayerCoreState.PLAYING
      || this.state === PlayerCoreState.PAUSED || this.state === PlayerCoreState.COMPLETED) {
      try {
        player.videoScaleType = type;
      } catch (err) {
        // 忽略：部分状态不支持
      }
    }
  }

  /** 快进/快退（±秒数） */
  async skipBy(deltaMs: number): Promise<void> {
    const target: number = Math.min(Math.max(0, this.currentMs + deltaMs), this.seekUpperBound());
    await this.seekTotal(target);
  }

  /** seek 上界（已知总时长；未知时当前 + 60s，允许探索） */
  private seekUpperBound(): number {
    if (this.totalMs > 0) {
      return this.totalMs;
    }
    return this.currentMs + 60000;
  }

  /** 释放（页面销毁/切集时调用） */
  async release(): Promise<void> {
    this.loadingToken++;
    this.video = null;
    this.partIndex = 0;
    this.segments = [];
    this.playlist = null;
    this.verifyCompletionMs = -1;
    this.stopTimers();
    this.updateState(PlayerCoreState.IDLE);
    await this.releasePlayer(this.loadingToken);
  }

  // ==================== 事件与状态机 ====================

  /** 注册 AVPlayer 全部事件 */
  private registerEvents(player: media.AVPlayer): void {
    player.on('stateChange', (state: string, reason: media.StateChangeReason): void => {
      this.handleState(state);
    });
    player.on('error', (err: BusinessError): void => {
      const token: number = this.loadingToken;
      // 加载期错误：一律可重试（销毁重建 + 换新直链）；
      // 播放期错误：仅瞬态码可重试（实测拉流断供会被引擎误报成各种码，
      // UNSUPPORT_FORMAT 亦由网络断供触发，不能按字面判死），其余直接上抛
      const loading: boolean = this.state === PlayerCoreState.LOADING || this.state === PlayerCoreState.PREPARING;
      const retryable: boolean = loading || PlayerController.isTransientPlaybackError(err.code);
      hilog.warn(0x0000, 'PlayerController',
        `[error] code=${err.code} state=${this.state} retryable=${retryable}`);
      this.fail(this.describePlaybackError(err.code), retryable, token);
    });
    player.on('durationUpdate', (duration: number): void => {
      if (this.playlist !== null) {
        this.playlist.observeDuration(duration);
      }
      if (this.playlist !== null && this.playlist.knownTotalMs() > 0) {
        this.totalMs = this.playlist.knownTotalMs();
      } else {
        this.totalMs = duration;
      }
    });
    player.on('timeUpdate', (time: number): void => {
      if (this.playlist !== null) {
        this.currentMs = this.playlist.totalPositionMs();
      } else {
        this.currentMs = time;
      }
    });
    player.on('seekDone', (seekDoneTime: number): void => {
      if (this.playlist !== null) {
        this.currentMs = this.playlist.totalPositionMs();
      } else {
        this.currentMs = seekDoneTime;
      }
    });
    // 播放列表内容切换（SDK 26 独立方法注册，非 on() 重载；回调携带 media source id）
    player.onPlaybackContentChanged((contentId: string): void => {
      if (this.playlist !== null) {
        this.playlist.handleContentChanged(contentId);
      }
    });
    player.on('bufferingUpdate', (infoType: media.BufferingInfoType, value: number): void => {
      // BUFFERING_START / BUFFERING_END / BUFFERING_PERCENT
      const busy: boolean = infoType === media.BufferingInfoType.BUFFERING_START;
      if (busy !== this.isBuffering) {
        this.isBuffering = busy;
        if (this.callbacks.onBuffering !== null) {
          this.callbacks.onBuffering(busy);
        }
      }
    });
  }

  /** AVPlayer 状态 → 内核状态机 */
  private handleState(state: string): void {
    hilog.info(0x0000, 'PlayerController', `[engine] ${state}`);
    switch (state) {
      case 'initialized':
        if (this.initSettler !== null) {
          this.initSettler('initialized');
        }
        break;
      case 'prepared':
        this.onPrepared();
        break;
      case 'playing':
        this.stopStartWatchdog();
        this.startProgressTimer();
        this.scheduleRetryBudgetReset();
        this.updateState(PlayerCoreState.PLAYING);
        break;
      case 'paused':
        this.stopProgressTimer();
        this.updateState(PlayerCoreState.PAUSED);
        break;
      case 'completed':
        this.stopStartWatchdog();
        this.handleCompleted();
        break;
      case 'stopped':
        this.stopProgressTimer();
        this.updateState(PlayerCoreState.STOPPED);
        break;
      case 'released':
        this.stopProgressTimer();
        break;
      case 'error':
        if (this.initSettler !== null) {
          this.initSettler('error');
        }
        break;
      default:
        break;
    }
  }

  /** prepared：应用循环模式/倍速/起播 seek/自动播放 */
  private onPrepared(): void {
    const player: media.AVPlayer | null = this.player;
    const playlist: SegmentPlaylist | null = this.playlist;
    if (player === null || playlist === null) {
      return;
    }
    this.updateState(PlayerCoreState.READY);
    // 播放列表不循环（分集播完回调 VM 决定是否连播下一集）
    if (this.mode === PlaybackMode.PLAYLIST && playlist.getSegments().length > 1) {
      try {
        player.playlistLoopMode = media.PlaylistLoopMode.PLAYLIST_LOOP_MODE_NONE;
      } catch (err) {
        // 不支持时依赖 completed 语义兜底
      }
    }
    // 倍速记忆（setSpeed 为同步 void API，无 Promise）
    if (this.speed !== 1.0) {
      try {
        player.setSpeed(PlayerController.toPlaybackSpeed(this.speed));
      } catch (err) {
        // 忽略：部分状态下不支持倍速设置
      }
    }
    // 音量记忆（setVolume 为同步 void API，无 Promise）
    if (this.volume !== 1.0) {
      try {
        player.setVolume(this.volume);
      } catch (err) {
        // 忽略：部分状态下不支持音量设置
      }
    }
    // 画面缩放记忆（切集重建实例后恢复用户选择的缩放模式）
    try {
      player.videoScaleType = this.scaleType;
    } catch (err) {
      // 忽略
    }
    if (this.callbacks.onPrepared !== null) {
      this.callbacks.onPrepared();
    }
    // 起播 seek（断点续播 / 播完重播）
    const startMs: number = this.pendingSeekMs;
    this.pendingSeekMs = 0;
    const applyAndPlay = (): void => {
      if (this.autoPlay) {
        player.play().catch((): void => {
        });
      }
    };
    if (startMs > 0) {
      const pos = playlist.mapTotal(startMs);
      const doPlay = (): void => applyAndPlay();
      if (pos.index > 0 && this.mode === PlaybackMode.PLAYLIST
        && playlist.getSourceId(pos.index).length > 0) {
        player.advanceToMediaSource(playlist.getSourceId(pos.index))
          .then((): void => {
            player.seek(pos.withinMs);
            doPlay();
          })
          .catch((): void => {
            doPlay(); // 跨段起播失败退回首段播
          });
      } else if (pos.index > 0) {
        // SEQUENTIAL 跨段续播：逐段重建 + 段内精确起播
        // （旧实现直接 player.seek(pos.withinMs) 无 try——跨段位置落在单段时长之外，
        //  引擎以 5400102 拒绝且未捕获，实例状态被带崩后连环报错，雏宫播放出错根因）
        this.switchSegmentSequential(pos.index, pos.withinMs);
      } else {
        try {
          player.seek(pos.withinMs);
        } catch (err) {
          // seek 被拒（状态未稳定）不阻断起播，从头播
        }
        doPlay();
      }
    } else {
      applyAndPlay();
    }
  }

  /**
   * completed：SEQUENTIAL 推进下一段或通知完成（含假完成守卫，BUG C）
   * 拉流断供时引擎可能提前抛 completed：照常收尾会把断点推到片尾、误标已看
   * 并触发自动连播（实测第 2 集播 2 分半即被假完成连跳到第 3 集），
   * 故以实时总时位对照已知总时长校验，超容差即拦截并保位重载
   */
  private handleCompleted(): void {
    this.stopProgressTimer();
    const playlist: SegmentPlaylist | null = this.playlist;
    if (playlist === null) {
      return;
    }
    if (this.mode === PlaybackMode.SEQUENTIAL) {
      // 段内守卫：当前段远未播完却报 completed = 断供误报，保位重载（不推进下一段）
      const segDur: number = playlist.knownSegmentDurationMs(playlist.getCurrentIndex());
      if (segDur > 0 && this.player !== null
        && this.player.currentTime < segDur - PlayerController.COMPLETION_TOLERANCE_MS) {
        this.rejectSpuriousCompletion(playlist.totalPositionMs(), '分段播放中断');
        return;
      }
      const next: number = playlist.getCurrentIndex() + 1;
      if (next < playlist.getSegments().length) {
        this.switchSegmentSequential(next);
        return;
      }
    }
    // 总守卫：距已知结尾仍差 > 容差 = 断供误报完成
    const liveMs: number = playlist.totalPositionMs();
    const total: number = this.totalMs > 0 ? this.totalMs : playlist.knownTotalMs();
    if (total > 0 && liveMs < total - PlayerController.COMPLETION_TOLERANCE_MS) {
      // 同位置二次完成（±10s）：时长元数据虚高（真实片尾短于声明时长），放行收尾
      if (this.verifyCompletionMs >= 0 && Math.abs(liveMs - this.verifyCompletionMs) <= 10000) {
        this.verifyCompletionMs = -1;
      } else {
        this.verifyCompletionMs = liveMs;
        this.rejectSpuriousCompletion(liveMs, '播放中断');
        return;
      }
    }
    this.verifyCompletionMs = -1;
    this.currentMs = total > 0 ? total : liveMs;
    this.updateState(PlayerCoreState.COMPLETED);
    if (this.callbacks.onCompletion !== null) {
      this.callbacks.onCompletion();
    }
  }

  /**
   * 拒绝假完成：保住真实进度走可重试失败（指数退避重载，从断点续播），
   * 而不是把 currentMs 推到片尾误标已看并触发自动连播
   */
  private rejectSpuriousCompletion(liveMs: number, message: string): void {
    this.currentMs = liveMs; // 保位：重载起点 = 真实观看位置
    this.isBuffering = false;
    hilog.warn(0x0000, 'PlayerController',
      `[guard] 假完成拦截: pos=${liveMs}ms total=${this.totalMs}ms mode=${this.mode} → 保位重载`);
    this.fail(`${message}，正在从断点恢复`, true, this.loadingToken);
  }

  /**
   * SEQUENTIAL 模式切换段（setMediaSource → 等待 initialized → prepare → play）；
   * withinMs > 0 时段内精确起播（跨段断点续播 / 跨段 seek 用）
   */
  private async switchSegmentSequential(index: number, withinMs: number = 0): Promise<void> {
    const player: media.AVPlayer | null = this.player;
    const playlist: SegmentPlaylist | null = this.playlist;
    if (player === null || playlist === null) {
      return;
    }
    const source: media.MediaSource | undefined = playlist.appendSource(index);
    if (source === undefined) {
      this.fail('分段切换失败', true, this.loadingToken);
      return;
    }
    this.updateState(PlayerCoreState.PREPARING);
    try {
      await player.setMediaSource(source);
    } catch (err) {
      hilog.warn(0x0000, 'PlayerController', `[segment] setMediaSource(${index}) 失败`);
      this.fail('分段切换失败', true, this.loadingToken);
      return;
    }
    const token: number = this.loadingToken;
    // setMediaSource 异步迁入 initialized：未就绪时 surfaceId/prepare 会被 5400102 拒绝
    const initOk: boolean = await this.waitForSourceInit(player, token);
    if (token !== this.loadingToken) {
      return;
    }
    if (!initOk) {
      return; // 源加载失败已由 error 监听器上抛，此处不重复 fail
    }
    if (this.surfaceId.length > 0) {
      try {
        player.surfaceId = this.surfaceId;
      } catch (err) {
        // 换窗失败忽略（旧窗口继续渲染）
      }
    }
    try {
      await player.prepare();
    } catch (err) {
      hilog.warn(0x0000, 'PlayerController', `[segment] prepare(${index}) 失败`);
      this.fail('分段切换失败', true, this.loadingToken);
      return;
    }
    if (token !== this.loadingToken) {
      return;
    }
    if (withinMs > 0) {
      try {
        player.seek(withinMs);
      } catch (err) {
        // seek 被拒从段头播（位置误差可接受，不阻断换段）
      }
    }
    player.play().catch((): void => {
    });
  }

  /** 统一失败出口：可重试 → 指数退避（1s/2s/4s）重载；否则上抛 */
  private fail(message: string, retryable: boolean, token: number): Promise<void> {
    if (token !== this.loadingToken) {
      return Promise.resolve();
    }
    if (retryable && this.retryCount < PlayerController.MAX_RETRY) {
      this.retryCount++;
      const delayMs: number = 1000 * (1 << (this.retryCount - 1)); // 1s/2s/4s
      this.updateState(PlayerCoreState.LOADING);
      this.retryTimer = setTimeout((): void => {
        this.retryTimer = -1;
        this.retryLoad();
      }, delayMs);
      return Promise.resolve();
    }
    this.stopTimers();
    this.updateState(PlayerCoreState.ERROR);
    if (this.callbacks.onError !== null) {
      this.callbacks.onError(message, false);
    }
    return Promise.resolve();
  }

  /** 状态更新 + 通知 */
  private updateState(state: PlayerCoreState): void {
    if (state !== this.state) {
      hilog.info(0x0000, 'PlayerController', `[state] ${state}（was ${this.state}）`);
    }
    this.state = state;
    if (this.callbacks.onStateChange !== null) {
      this.callbacks.onStateChange(state);
    }
  }

  /** 进度推送（500ms 独立定时器） */
  private startProgressTimer(): void {
    this.stopProgressTimer();
    this.progressTimer = setInterval((): void => {
      const playlist: SegmentPlaylist | null = this.playlist;
      if (playlist === null) {
        return;
      }
      this.currentMs = playlist.totalPositionMs();
      const total: number = playlist.knownTotalMs();
      if (total > 0) {
        this.totalMs = total;
      }
      if (this.callbacks.onProgress !== null) {
        this.callbacks.onProgress(this.currentMs, this.totalMs);
      }
    }, 500);
  }

  private stopProgressTimer(): void {
    if (this.progressTimer >= 0) {
      clearInterval(this.progressTimer);
      this.progressTimer = -1;
    }
  }

  private stopTimers(): void {
    this.stopProgressTimer();
    this.stopStartWatchdog();
    if (this.retryTimer >= 0) {
      clearTimeout(this.retryTimer);
      this.retryTimer = -1;
    }
    if (this.retryResetTimer >= 0) {
      clearTimeout(this.retryResetTimer);
      this.retryResetTimer = -1;
    }
  }

  /**
   * 稳定播放重试预算重置：连续播放 30s 说明链路健康，
   * 历史失败不应累计到后续独立故障（长会话内偶发两次断供不应直接弹终局错误）
   */
  private scheduleRetryBudgetReset(): void {
    if (this.retryResetTimer >= 0) {
      clearTimeout(this.retryResetTimer);
    }
    this.retryResetTimer = setTimeout((): void => {
      this.retryResetTimer = -1;
      if (this.state === PlayerCoreState.PLAYING) {
        this.retryCount = 0;
      }
    }, PlayerController.RETRY_RESET_AFTER_MS);
  }

  /** 起播看门狗：LOADING/PREPARING/READY 停滞超时 → 直接报错（不再无限转圈） */
  private startStartWatchdog(token: number): void {
    this.stopStartWatchdog();
    this.startWatchdog = setTimeout((): void => {
      this.startWatchdog = -1;
      if (token !== this.loadingToken) {
        return;
      }
      if (this.state === PlayerCoreState.LOADING || this.state === PlayerCoreState.PREPARING
        || this.state === PlayerCoreState.READY) {
        this.fail('视频起播超时：请确认网络或设备解码能力后重试', false, token);
      }
    }, PlayerController.START_WATCHDOG_MS);
  }

  private stopStartWatchdog(): void {
    if (this.startWatchdog >= 0) {
      clearTimeout(this.startWatchdog);
      this.startWatchdog = -1;
    }
  }

  /** 释放底层 AVPlayer（含 fd） */
  private async releasePlayer(token: number): Promise<void> {
    if (this.playlist !== null) {
      this.playlist.releaseLocalFds();
    }
    const player: media.AVPlayer | null = this.player;
    this.player = null;
    if (player !== null) {
      try {
        player.release();
      } catch (err) {
        // 忽略
      }
    }
  }

  /** 丢弃加载产物（令牌失效路径） */
  private destroyQuietly(player: media.AVPlayer): void {
    try {
      player.release();
    } catch (err) {
      // 忽略
    }
  }

  /** 倍速映射 */
  private static toPlaybackSpeed(rate: number): media.PlaybackSpeed {
    if (rate <= 0.5) {
      return media.PlaybackSpeed.SPEED_FORWARD_0_50_X;
    }
    if (rate <= 0.75) {
      return media.PlaybackSpeed.SPEED_FORWARD_0_75_X;
    }
    if (rate <= 1.0) {
      return media.PlaybackSpeed.SPEED_FORWARD_1_00_X;
    }
    if (rate <= 1.25) {
      return media.PlaybackSpeed.SPEED_FORWARD_1_25_X;
    }
    if (rate <= 1.5) {
      return media.PlaybackSpeed.SPEED_FORWARD_1_50_X;
    }
    if (rate <= 1.75) {
      return media.PlaybackSpeed.SPEED_FORWARD_1_75_X;
    }
    if (rate <= 2.0) {
      return media.PlaybackSpeed.SPEED_FORWARD_2_00_X;
    }
    return media.PlaybackSpeed.SPEED_FORWARD_3_00_X;
  }
}
