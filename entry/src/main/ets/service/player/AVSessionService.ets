/**
 * AVSession 媒体会话服务（播控中心补缺 2026-09）
 * - 元数据：assetId={hid}#{partIndex}（官方语义：assetId 变化→元数据整体刷新，
 *   解决同视频切分集不刷新）、封面 mediaImage=thumb、skipIntervals=10s
 *   （与应用内 ±10s 惯例一致）
 * - 命令：play/pause/stop/playNext/playPrevious/seek/fastForward/rewind →
 *   按会话持有者（在线页/离线页）路由到对应 handler
 * - 状态同步：仅事件点上报（状态切换/seek/倍速/缓冲/时长就绪），系统按
 *   elapsedTime+updateTime+speed 自推算进度，无需轮询；每次均携带已知时长
 *   （AVPlaybackState.duration，起播 duration=0 兜底）
 * - setLaunchAbility：点击播控卡片拉回应用（与长时任务共用拉起代理）
 * - 长时任务：audioPlayback 模式，PLAYING（含缓冲）申请、暂停/完成/错误/销毁
 *   释放；退后台/锁屏续播依赖此任务（未接入 AVSession 的应用不可申请）
 * - 容错：createAVSession 失败（6600101：销毁后立即重建偶发）退避 500ms 重试
 *   一次；仍失败降级为无播控，不阻断播放
 * - 并发防护：激活链串行化（快速切集/自愈重建不产生并发重建）；epoch 纪元
 *   使在途激活在销毁后自弃，防幽灵会话
 * - 幂等：同分集重复激活跳过（仅切命令归属）；destroy 幂等
 */
import { avSession } from '@kit.AVSessionKit';
import { Context, wantAgent, Want, WantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { Video } from '../../model/entity/BaseEntities';

/** 会话持有者标识（命令路由与状态上报按持有者鉴权，防在线/离线跨页串写） */
export class AVSessionOwner {
  /** 在线播放页（VideoDetailVM） */
  static readonly ONLINE: string = 'online';
  /** 离线播放页（OfflinePlayerVM） */
  static readonly OFFLINE: string = 'offline';
}

/** 媒体控制命令处理器（VM 按持有者注册；未注入的命令忽略） */
export class AVSessionCommandHandler {
  onPlay: (() => void) | null = null;
  onPause: (() => void) | null = null;
  onStop: (() => void) | null = null;
  /** 下一分集 */
  onPlayNext: (() => void) | null = null;
  /** 上一分集 */
  onPlayPrevious: (() => void) | null = null;
  /** 跳转（总时位 ms） */
  onSeek: ((timeMs: number) => void) | null = null;
  /** 快进（+skipIntervals，无参命令） */
  onFastForward: (() => void) | null = null;
  /** 快退（-skipIntervals，无参命令） */
  onRewind: (() => void) | null = null;
}

/** AVSession 单例封装 */
export class AVSessionService {
  private static instance: AVSessionService | undefined;

  static getInstance(): AVSessionService {
    if (AVSessionService.instance === undefined) {
      AVSessionService.instance = new AVSessionService();
    }
    return AVSessionService.instance;
  }

  /** 当前会话（null=未激活） */
  private session: avSession.AVSession | null = null;
  /** 会话资产键（hid#partIndex；去重依据与整体刷新触发器） */
  private sessionAssetId: string = '';
  /** 会话持有者（命令路由/状态上报鉴权） */
  private owner: string = '';
  /** 持有者 → 命令处理器（VM 构造时注册，activate 时按 owner 启用） */
  private handlers: Map<string, AVSessionCommandHandler> = new Map();
  /** 激活链（串行化并发激活，防重复重建竞态） */
  private activateChain: Promise<void> = Promise.resolve();
  /** 会话纪元（destroy 递增；在途激活据此自弃，防销毁后幽灵会话） */
  private epoch: number = 0;
  /** 会话上下文（长时任务申请用） */
  private context: Context | null = null;
  /** 元数据快照（updateDuration 局部重建用） */
  private metaVideo: Video | null = null;
  private metaPartTitle: string = '';
  /** 已知媒体时长 ms（-1=未知；prepared 后由 updateDuration 精确化） */
  private durationMs: number = -1;
  /** 播放长时任务运行中 */
  private bgTaskRunning: boolean = false;
  /** 拉起代理（setLaunchAbility 与长时任务共用，惰性构建一次） */
  private launchAgent: WantAgent | null = null;

  private constructor() {
  }

  /** 是否已激活 */
  isActive(): boolean {
    return this.session !== null;
  }

  /**
   * 激活（或复用）视频会话并设置元数据（链上串行，可安全并发调用）
   * @param context   UIAbility context
   * @param video     当前视频
   * @param partIndex 当前分集索引（assetId 组成部分：切分集时元数据整体刷新）
   * @param partTitle 当前分集标题
   * @param durationMs 总时长（未就绪传 0，prepared 后 updateDuration 精确化）
   * @param owner     会话持有者（命令路由归属）
   */
  async activate(context: Context, video: Video, partIndex: number,
    partTitle: string, durationMs: number, owner: string): Promise<void> {
    const task = async (): Promise<void> => {
      await this.runActivate(context, video, partIndex, partTitle, durationMs, owner);
    };
    this.activateChain = this.activateChain.then(task, task);
    await this.activateChain;
  }

  /** 注册命令处理器（持有者键；传 null 清除） */
  setCommandHandler(owner: string, handler: AVSessionCommandHandler | null): void {
    if (handler === null) {
      this.handlers.delete(owner);
      return;
    }
    this.handlers.set(owner, handler);
  }

  /**
   * 时长精确化（onPrepared 回调调用；此时 durationUpdate 已回，总时长可靠）
   * 同步刷新元数据与后续状态上报携带的 duration，修复起播 duration=0 导致
   * 播控进度条不可用
   */
  async updateDuration(owner: string, durationMs: number): Promise<void> {
    if (this.session === null || this.owner !== owner || durationMs <= 0) {
      return;
    }
    this.durationMs = durationMs;
    try {
      await this.session.setAVMetadata(this.buildMetadata());
    } catch (err) {
      // 忽略：会话可能已被系统回收
    }
  }

  /**
   * 同步播放状态（仅事件点上报；owner 鉴权防跨页串写）
   * @param owner    持有者
   * @param playing  内核是否处于播放态
   * @param positionMs 当前总时位（系统以此为新锚点自推算）
   * @param speed    倍速
   * @param completed 播完
   * @param error    错误
   * @param buffering 缓冲中（显示播放但进度不走）
   */
  async updatePlaybackState(owner: string, playing: boolean, positionMs: number,
    speed: number, completed: boolean = false, error: boolean = false,
    buffering: boolean = false): Promise<void> {
    const session: avSession.AVSession | null = this.session;
    if (session === null || this.owner !== owner) {
      return;
    }
    let state: avSession.PlaybackState = avSession.PlaybackState.PLAYBACK_STATE_PAUSE;
    if (error) {
      state = avSession.PlaybackState.PLAYBACK_STATE_ERROR;
    } else if (completed) {
      state = avSession.PlaybackState.PLAYBACK_STATE_COMPLETED;
    } else if (buffering && playing) {
      state = avSession.PlaybackState.PLAYBACK_STATE_BUFFERING;
    } else if (playing) {
      state = avSession.PlaybackState.PLAYBACK_STATE_PLAY;
    }
    const playbackState: avSession.AVPlaybackState = {
      state: state,
      speed: speed > 0 ? speed : 1,
      position: {
        // 防御：系统不接受负时位（播放器重启期可能产生）
        elapsedTime: Math.max(0, positionMs),
        updateTime: Date.now()
      }
    };
    if (this.durationMs > 0) {
      playbackState.duration = this.durationMs;
    }
    try {
      await session.setAVPlaybackState(playbackState);
    } catch (err) {
      // 疑似系统因音频焦点丢失停用会话（播放器重启/异常中断）：重激活后重试一次
      try {
        await session.activate();
        await session.setAVPlaybackState(playbackState);
      } catch (ignore) {
        // 仍失败：放弃本次上报（不阻断播放）
      }
    }
    // 长时任务随播放态联动：播放（含缓冲）保活，暂停/完成/错误释放
    if (playing && !error && !completed) {
      await this.startBackgroundTask();
    } else {
      this.stopBackgroundTask();
    }
  }

  /** 销毁会话（页面退出/切视频/投播接管时调用，幂等；同时释放长时任务） */
  async destroy(): Promise<void> {
    this.epoch++;
    const session: avSession.AVSession | null = this.session;
    this.session = null;
    this.sessionAssetId = '';
    this.owner = '';
    this.metaVideo = null;
    this.metaPartTitle = '';
    this.durationMs = -1;
    this.stopBackgroundTask();
    if (session !== null) {
      try {
        session.off('play');
        session.off('pause');
        session.off('stop');
        session.off('playNext');
        session.off('playPrevious');
        session.off('seek');
        session.off('fastForward');
        session.off('rewind');
        await session.destroy();
      } catch (err) {
        // 忽略：会话可能已被系统回收
      }
    }
  }

  // ==================== 内部：激活链 ====================

  /** 激活执行体（链上串行执行） */
  private async runActivate(context: Context, video: Video, partIndex: number,
    partTitle: string, durationMs: number, owner: string): Promise<void> {
    const assetId: string = `${video.hid}#${partIndex}`;
    if (this.session !== null && this.sessionAssetId === assetId) {
      // 同分集重复激活（切清晰度/重试/自愈重建）：仅切命令归属，不重建
      this.owner = owner;
      return;
    }
    await this.destroy();
    const epoch: number = this.epoch;
    this.context = context;
    this.metaVideo = video;
    this.metaPartTitle = partTitle;
    this.durationMs = durationMs > 0 ? durationMs : -1;
    const ok: boolean = await this.tryCreateSession(context, assetId, owner);
    if (!ok && this.epoch === epoch) {
      // 6600101（销毁后立即重建偶发失败）：退避 500ms 重试一次
      await AVSessionService.delay(500);
      if (this.epoch === epoch) {
        await this.tryCreateSession(context, assetId, owner);
      }
    }
  }

  /** 创建并装配会话（失败返回 false 由调用方重试） */
  private async tryCreateSession(context: Context, assetId: string,
    owner: string): Promise<boolean> {
    const epoch: number = this.epoch;
    let session: avSession.AVSession | null = null;
    try {
      session = await avSession.createAVSession(context, 'tucaoPlayer', 'video');
      if (this.epoch !== epoch) {
        // 创建等待期间已销毁（快速退出/切集/投播接管）：静默丢弃防幽灵会话
        try {
          await session.destroy();
        } catch (err) {
          // 忽略
        }
        return true;
      }
      this.session = session;
      this.sessionAssetId = assetId;
      this.owner = owner;
      await session.setAVMetadata(this.buildMetadata());
      const agent: WantAgent | null = await this.ensureLaunchAgent();
      if (agent !== null) {
        // 点击播控卡片封面 → 拉回应用（未设置时点击无响应）
        await session.setLaunchAbility(agent);
      }
      this.registerCommands(session);
      await session.activate();
      return true;
    } catch (err) {
      // 装配失败：清理半成品引用，降级为无播控（不阻断播放）
      if (session !== null && this.session === session) {
        this.session = null;
        this.sessionAssetId = '';
        this.owner = '';
      }
      if (session !== null) {
        try {
          await session.destroy();
        } catch (ignore) {
          // 忽略
        }
      }
      return false;
    }
  }

  /** 组装元数据（assetId 不变时字段级更新；变化时系统整体刷新） */
  private buildMetadata(): avSession.AVMetadata {
    const metadata: avSession.AVMetadata = {
      assetId: this.sessionAssetId.length > 0 ? this.sessionAssetId : 'tucaoPlayer',
      // 快进快退步长：应用内按钮为 ±10s，播控中心保持一致
      skipIntervals: avSession.SkipIntervals.SECONDS_10
    };
    const video: Video | null = this.metaVideo;
    if (video !== null) {
      metadata.title = video.title;
      metadata.artist = video.user;
      // 封面（string 仅支持网络路径；离线无网时无封面，可接受，见调研风险1）
      if (video.thumb.length > 0) {
        metadata.mediaImage = video.thumb;
      }
    }
    if (this.metaPartTitle.length > 0) {
      metadata.subtitle = this.metaPartTitle;
    }
    if (this.durationMs > 0) {
      metadata.duration = this.durationMs;
    }
    return metadata;
  }

  // ==================== 内部：命令路由 ====================

  /** 注册播控命令（转发给当前持有者的 handler） */
  private registerCommands(session: avSession.AVSession): void {
    session.on('play', (): void => {
      this.dispatch((handler: AVSessionCommandHandler): void => {
        if (handler.onPlay !== null) {
          handler.onPlay();
        }
      });
    });
    session.on('pause', (): void => {
      this.dispatch((handler: AVSessionCommandHandler): void => {
        if (handler.onPause !== null) {
          handler.onPause();
        }
      });
    });
    session.on('stop', (): void => {
      this.dispatch((handler: AVSessionCommandHandler): void => {
        if (handler.onStop !== null) {
          handler.onStop();
        }
      });
    });
    session.on('playNext', (): void => {
      this.dispatch((handler: AVSessionCommandHandler): void => {
        if (handler.onPlayNext !== null) {
          handler.onPlayNext();
        }
      });
    });
    session.on('playPrevious', (): void => {
      this.dispatch((handler: AVSessionCommandHandler): void => {
        if (handler.onPlayPrevious !== null) {
          handler.onPlayPrevious();
        }
      });
    });
    session.on('seek', (time: number): void => {
      this.dispatch((handler: AVSessionCommandHandler): void => {
        if (handler.onSeek !== null) {
          handler.onSeek(time);
        }
      });
    });
    session.on('fastForward', (): void => {
      this.dispatch((handler: AVSessionCommandHandler): void => {
        if (handler.onFastForward !== null) {
          handler.onFastForward();
        }
      });
    });
    session.on('rewind', (): void => {
      this.dispatch((handler: AVSessionCommandHandler): void => {
        if (handler.onRewind !== null) {
          handler.onRewind();
        }
      });
    });
  }

  /** 命令统一派发（按当前持有者取 handler；未注册时忽略） */
  private dispatch(action: (handler: AVSessionCommandHandler) => void): void {
    const handler: AVSessionCommandHandler | undefined = this.handlers.get(this.owner);
    if (handler !== undefined) {
      action(handler);
    }
  }

  // ==================== 内部：长时任务与拉起代理 ====================

  /** 起播放长时任务（幂等；audioPlayback 需会话在身，仅接入了 AVSession 的应用可申请） */
  private async startBackgroundTask(): Promise<void> {
    if (this.bgTaskRunning) {
      return;
    }
    const context: Context | null = this.context;
    if (context === null) {
      return;
    }
    const agent: WantAgent | null = await this.ensureLaunchAgent();
    if (agent === null) {
      // wantAgent 为必传参数；构建失败则放弃长时任务（前台播放不受影响）
      return;
    }
    try {
      await backgroundTaskManager.startBackgroundRunning(context, ['audioPlayback'], agent);
      this.bgTaskRunning = true;
    } catch (err) {
      this.bgTaskRunning = false;
      // 前台播放不受影响；退后台可能被系统暂停
    }
  }

  /** 停播放长时任务（幂等容错：暂停 10 分钟卡片移除时系统可能已代为取消） */
  private stopBackgroundTask(): void {
    if (!this.bgTaskRunning) {
      return;
    }
    this.bgTaskRunning = false;
    const context: Context | null = this.context;
    if (context === null) {
      return;
    }
    backgroundTaskManager.stopBackgroundRunning(context).catch((): void => {
      // 忽略：任务可能已被系统取消
    });
  }

  /** 构建并缓存拉起代理（点击播控卡片/长时任务通知 → 回应用） */
  private async ensureLaunchAgent(): Promise<WantAgent | null> {
    if (this.launchAgent !== null) {
      return this.launchAgent;
    }
    const want: Want = {
      bundleName: 'me.sweetll.tucao',
      abilityName: 'EntryAbility'
    };
    const info: wantAgent.WantAgentInfo = {
      wants: [want],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0
    };
    try {
      const agent: WantAgent = await wantAgent.getWantAgent(info);
      this.launchAgent = agent;
      return agent;
    } catch (err) {
      return null;
    }
  }

  /** 延时工具（重试退避用） */
  private static delay(ms: number): Promise<void> {
    return new Promise<void>((resolve) => {
      setTimeout(resolve, ms);
    });
  }
}
