/**
 * 离线播放 VM
 * - 隔离内核：私有 AVPlayer + SegmentPlaylist（不复用 PlayerController 单例——其回调集被
 *   VideoDetailVM 构造时独占，复用会互相覆盖回调与状态；离线场景无需地址重试/SEQUENTIAL 兜底）
 * -  防污染：findVideo → toLocalRecord → fromLocalJson 克隆，绝不引用引擎目录实例
 * - 分集选择：路由 hid#order 精准定位；无 order 取首个已完成分集；未完成分集直接报错
 * - 断点续播：与在线一致（autoResume 直续 / 关则提示条手动跳转）；历史写回经克隆实例
 * -  自动连播：仅当下一分集已缓存完成才连播，遇未缓存分集停止
 * - 弹幕：danmuMissing 检测分集目录 danmu.xml；updateDanmu 透传引擎重拉；
 *   danmuPathOfCurrent 供  DanmakuView 接线（onSegmentChanged 亦留对齐注释）
 * - 礼让在线播放：playPartInternal 前调 VideoDetailVM.shared().pause()（不触碰其回调槽）
 * - AVSession：复用 AVSessionService 单例（owner=offline，命令路由/状态上报按持有者
 *   鉴权，与在线页互不串写）；起播激活、prepared 补时长、事件点状态同步、
 *   播控命令回注本 VM 私有内核；shutdown 销毁会话并释放长时任务
 * 偏差（vs PlayerController）：无自动重试（离线文件不涉及地址过期）、无 SEQUENTIAL 兜底
 */
import { media } from '@kit.MediaKit';
import { audio } from '@kit.AudioKit';
import { fileIo } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Video, Part, Durl, DownloadStatus } from '../model/entity/BaseEntities';
import { SegmentPlaylist } from '../service/player/SegmentPlaylist';
import { PlayerCoreState } from '../service/player/PlayerController';
import { HistoryService, ResumePoint } from '../service/player/HistoryService';
import { AVSessionService, AVSessionCommandHandler, AVSessionOwner } from '../service/player/AVSessionService';
import { AppContextHolder } from '../common/GlobalState';
import { DownloadEngine } from '../service/download/DownloadEngine';
import { VideoDetailVM } from './VideoDetailVM';
import { PreferenceStore } from '../data/PreferenceStore';

/** 离线倍速档位（与在线 PlayerControlView.SpeedTable 同构） */
export class OfflineSpeedTable {
  static readonly ALL: number[] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 3.0];

  static labelOf(rate: number): string {
    return `${rate}x`;
  }
}

/** 离线播放 VM（页面私有实例，aboutToDisappear 时 shutdown 释放内核） */
@ObservedV2
export class OfflinePlayerVM {
  // ============ 页面状态 ============
  /** 目录加载失败（全页错误态） */
  @Trace loadError: string = '';
  /** 当前视频（引擎目录克隆 + 历史合并） */
  @Trace video: Video | null = null;
  /** 当前分集索引 */
  @Trace partIndex: number = 0;
  /** 内核状态 */
  @Trace coreState: PlayerCoreState = PlayerCoreState.IDLE;
  /** 总时位 ms */
  @Trace currentMs: number = 0;
  /** 总时长 ms */
  @Trace totalMs: number = 0;
  /** 缓冲中 */
  @Trace isBuffering: boolean = false;
  /** 倍速 */
  @Trace speed: number = 1.0;
  /** 音量镜像（0~1 映射系统媒体音量；R7 落点三竖滑手势起点） */
  @Trace volume: number = 1.0;
  /** 画面缩放（R7 落点二：fit/16:9/4:3/fill，prepared 后即时生效） */
  @Trace scaleMode: string = 'fit';
  /** 分集加载中 */
  @Trace partLoading: boolean = false;
  /** 播放错误（控制层错误条） */
  @Trace playbackError: string = '';
  /** 断点续播提示条 */
  @Trace resumeTipVisible: boolean = false;
  @Trace resumeTipText: string = '';
  /** 弹幕文件缺失提示 */
  @Trace danmuMissing: boolean = false;

  // ============ 内核 ============
  private player: media.AVPlayer | null = null;
  private playlist: SegmentPlaylist | null = null;
  /** 并发令牌（切集/关闭时旧链路作废） */
  private token: number = 0;
  private surfaceId: string = '';
  /** 源就绪等待槽（waitForSourceInit 与常驻 stateChange 路由对接，与 PlayerController 同构） */
  private initSettler: ((state: string) => void) | null = null;
  private pendingSeekMs: number = 0;
  private progressTimer: number = -1;
  /** 断点节流时间戳 */
  private lastBreakpointAt: number = 0;
  private static readonly BREAKPOINT_INTERVAL: number = 5000;
  private readonly engine: DownloadEngine = DownloadEngine.getInstance();
  private readonly history: HistoryService = HistoryService.getInstance();
  /** 播控会话（与在线页共用单例，按 owner=offline 鉴权隔离） */
  private readonly session: AVSessionService = AVSessionService.getInstance();

  constructor() {
    this.session.setCommandHandler(AVSessionOwner.OFFLINE, this.buildCommandHandler());
  }

  // ============ 入口 ============

  /**
   * 路由进入（hid 或 hid#order）
   * @param order 分集 order（0 基；-1 = 未指定，取首个已完成分集）
   */
  async prepare(hid: string, order: number): Promise<void> {
    this.loadError = '';
    const entry: Video | undefined = this.engine.findVideo(hid);
    if (entry === undefined) {
      this.loadError = '未找到缓存信息，请从离线缓存列表重新进入';
      return;
    }
    // 目录克隆（引擎单例实例禁止直引，历史写回不污染目录）
    const video: Video = Video.fromLocalJson(entry.toLocalRecord());
    // 合并播放历史（已看/断点）
    const historyRecord: Video | undefined = this.history.findHistory(hid);
    if (historyRecord !== undefined) {
      for (let i = 0; i < video.parts.length; i++) {
        const part: Part = video.parts[i];
        const old: Part | undefined = historyRecord.parts.find((p: Part): boolean => p.vid === part.vid);
        if (old !== undefined) {
          part.hadPlay = old.hadPlay;
          part.lastPlayPosition = old.lastPlayPosition;
        }
      }
    }
    // 分集定位：order 精准优先，否则首个已完成分集
    let index: number = -1;
    if (order >= 0) {
      for (let i = 0; i < video.parts.length; i++) {
        if (video.parts[i].order === order) {
          index = i;
          break;
        }
      }
    }
    if (index < 0) {
      for (let i = 0; i < video.parts.length; i++) {
        if (video.parts[i].flag === DownloadStatus.COMPLETED) {
          index = i;
          break;
        }
      }
    }
    if (index < 0) {
      this.loadError = '该视频尚未缓存完成';
      return;
    }
    if (video.parts[index].flag !== DownloadStatus.COMPLETED) {
      this.loadError = '该分集尚未缓存完成';
      return;
    }
    this.video = video;
    // 断点续播（与在线语义一致）
    this.speed = PreferenceStore.playerConfig().speed;
    const point: ResumePoint | null = this.history.resumePointOf(video);
    if (point !== null && point.partIndex === index) {
      if (PreferenceStore.playerConfig().autoResume) {
        await this.playPartInternal(index, point.positionMs);
      } else {
        this.showResumeTip(point.partIndex, point.positionMs);
        await this.playPartInternal(index, 0);
      }
      return;
    }
    await this.playPartInternal(index, 0);
  }

  // ============ 播放驱动 ============

  /** 播放指定分集（仅已完成分集可播） */
  async switchPart(index: number): Promise<void> {
    const video: Video | null = this.video;
    if (video === null || index < 0 || index >= video.parts.length) {
      return;
    }
    if (video.parts[index].flag !== DownloadStatus.COMPLETED) {
      return;
    }
    await this.playPartInternal(index, 0);
  }

  /** 播放/暂停切换 */
  async togglePlay(): Promise<void> {
    if (this.coreState === PlayerCoreState.PLAYING) {
      await this.pause();
    } else {
      await this.play();
    }
  }

  /** 继续播放（播完态重播从头） */
  async play(): Promise<void> {
    const player: media.AVPlayer | null = this.player;
    if (player === null) {
      return;
    }
    if (this.coreState === PlayerCoreState.READY || this.coreState === PlayerCoreState.PAUSED
      || this.coreState === PlayerCoreState.COMPLETED) {
      if (this.coreState === PlayerCoreState.COMPLETED) {
        this.pendingSeekMs = 0;
      }
      player.play().catch((): void => {
      });
    }
  }

  /** 暂停 */
  async pause(): Promise<void> {
    const player: media.AVPlayer | null = this.player;
    if (player === null || this.coreState !== PlayerCoreState.PLAYING) {
      return;
    }
    player.pause().catch((): void => {
    });
  }

  /** 总时位 seek（跨段自动 advance） */
  async seekTotal(totalMs: number): Promise<void> {
    const player: media.AVPlayer | null = this.player;
    const playlist: SegmentPlaylist | null = this.playlist;
    if (player === null || playlist === null) {
      return;
    }
    if (this.coreState !== PlayerCoreState.READY && this.coreState !== PlayerCoreState.PLAYING
      && this.coreState !== PlayerCoreState.PAUSED && this.coreState !== PlayerCoreState.COMPLETED) {
      this.pendingSeekMs = totalMs;
      return;
    }
    this.currentMs = totalMs;
    const pos = playlist.mapTotal(totalMs);
    try {
      if (pos.index !== playlist.getCurrentIndex()) {
        const sourceId: string = playlist.getSourceId(pos.index);
        if (sourceId.length === 0) {
          return;
        }
        await player.advanceToMediaSource(sourceId);
      }
      player.seek(pos.withinMs);
    } catch (err) {
      // seek 失败忽略（保持原位置）
    }
    this.syncSessionPosition();
  }

  /** 快进/快退 ±ms */
  async skipBy(deltaMs: number): Promise<void> {
    const upper: number = this.totalMs > 0 ? this.totalMs : this.currentMs + 60000;
    const target: number = Math.min(Math.max(0, this.currentMs + deltaMs), upper);
    await this.seekTotal(target);
  }

  /** 倍速（持久化 PlayerConfig；同步 void API try/catch） */
  setSpeed(rate: number): void {
    this.speed = rate;
    PreferenceStore.playerConfig().speed = rate;
    const player: media.AVPlayer | null = this.player;
    if (player === null) {
      return;
    }
    if (this.coreState === PlayerCoreState.READY || this.coreState === PlayerCoreState.PLAYING
      || this.coreState === PlayerCoreState.PAUSED || this.coreState === PlayerCoreState.COMPLETED) {
      try {
        player.setSpeed(OfflinePlayerVM.toPlaybackSpeed(rate));
      } catch (err) {
        // 状态不允许时忽略
      }
    }
    // 倍速变化即新锚点：播控中心按新倍速推算
    this.session.updatePlaybackState(AVSessionOwner.OFFLINE,
      this.coreState === PlayerCoreState.PLAYING, this.currentMs, rate);
  }

  /** 倍速循环（控制栏点击） */
  nextSpeed(): void {
    const all: number[] = OfflineSpeedTable.ALL;
    const at: number = all.indexOf(this.speed);
    const next: number = all[(at + 1) % all.length] ?? 1.0;
    this.setSpeed(next);
  }

  /** 音量（0~1 映射系统媒体音量；对齐在线版 VideoDetailVM.setVolume） */
  async setVolume(volume: number): Promise<void> {
    const clamped: number = Math.min(1.0, Math.max(0.0, volume));
    this.volume = clamped;
    try {
      const audioManager = audio.getAudioManager();
      const max: number = await audioManager.getMaxVolume(audio.AudioVolumeType.MEDIA);
      const min: number = await audioManager.getMinVolume(audio.AudioVolumeType.MEDIA);
      await audioManager.setVolume(audio.AudioVolumeType.MEDIA, Math.round(min + clamped * (max - min)));
    } catch (err) {
      // 系统音量调节失败时保持镜像值
    }
  }

  /** 读取系统媒体音量同步到镜像（页面 onShown/aboutToAppear 时调用） */
  async refreshSystemVolume(): Promise<void> {
    try {
      const audioManager = audio.getAudioManager();
      const max: number = await audioManager.getMaxVolume(audio.AudioVolumeType.MEDIA);
      const vol: number = await audioManager.getVolume(audio.AudioVolumeType.MEDIA);
      if (max > 0) {
        this.volume = Math.min(1.0, Math.max(0.0, vol / max));
      }
    } catch (err) {
      // 忽略
    }
  }

  /** 画面缩放（R7 落点二：fit=保持比例留黑边；16:9/4:3=内容拉伸变形；fill=保持比例裁剪撑满） */
  setScaleMode(mode: string): void {
    this.scaleMode = mode;
    const player: media.AVPlayer | null = this.player;
    if (player === null) {
      return;
    }
    if (this.coreState === PlayerCoreState.READY || this.coreState === PlayerCoreState.PLAYING
      || this.coreState === PlayerCoreState.PAUSED || this.coreState === PlayerCoreState.COMPLETED) {
      try {
        player.videoScaleType = OfflinePlayerVM.toVideoScaleType(mode);
      } catch (err) {
        // 忽略：部分状态不支持
      }
    }
  }

  /** 缩放模式 → 内核枚举 */
  static toVideoScaleType(mode: string): media.VideoScaleType {
    if (mode === 'fill') {
      return media.VideoScaleType.VIDEO_SCALE_TYPE_FIT_CROP;
    }
    if (mode === '16:9' || mode === '4:3') {
      return media.VideoScaleType.VIDEO_SCALE_TYPE_FIT;
    }
    return media.VideoScaleType.VIDEO_SCALE_TYPE_SCALED_ASPECT;
  }

  /** 播放错误重试（错误条按钮） */
  async retryPlayback(): Promise<void> {
    this.playbackError = '';
    await this.playPartInternal(this.partIndex, this.currentMs);
  }

  /** 续播提示条：立即跳转 */
  async resumeFromTip(): Promise<void> {
    const video: Video | null = this.video;
    if (video === null) {
      return;
    }
    const point: ResumePoint | null = this.history.resumePointOf(video);
    if (point !== null) {
      await this.playPartInternal(point.partIndex, point.positionMs);
    }
  }

  /** surface 绑定（XComponent onLoad） */
  attachSurface(surfaceId: string): void {
    this.surfaceId = surfaceId;
    const player: media.AVPlayer | null = this.player;
    if (player === null) {
      return;
    }
    if (this.coreState === PlayerCoreState.READY || this.coreState === PlayerCoreState.PLAYING
      || this.coreState === PlayerCoreState.PAUSED || this.coreState === PlayerCoreState.COMPLETED) {
      try {
        player.surfaceId = surfaceId;
      } catch (err) {
        // 换窗失败忽略
      }
    }
  }

  /** 断点立即落盘 */
  saveBreakpointNow(): void {
    const video: Video | null = this.video;
    if (video === null) {
      return;
    }
    if (this.coreState !== PlayerCoreState.PLAYING && this.coreState !== PlayerCoreState.PAUSED) {
      return;
    }
    this.lastBreakpointAt = Date.now();
    this.history.saveBreakpoint(video, this.partIndex, this.currentMs);
  }

  /** 页面销毁：断点落盘 + 释放内核 + 销毁播控会话（含长时任务释放） */
  shutdown(): void {
    this.token++;
    this.saveBreakpointNow();
    this.stopProgressTimer();
    this.releaseCore();
    this.coreState = PlayerCoreState.IDLE;
    this.partLoading = false;
    // 销毁幂等；会话若已被在线页/投播接管（owner 切换），service 内按持有者鉴权忽略
    this.session.destroy();
  }

  // ============ 播控会话（AVSession，owner=offline） ============

  /** 播控命令 → 本 VM 私有内核（构造器注册，与在线页命令表隔离） */
  private buildCommandHandler(): AVSessionCommandHandler {
    const handler: AVSessionCommandHandler = new AVSessionCommandHandler();
    const vm: OfflinePlayerVM = this;
    handler.onPlay = (): void => {
      vm.play();
    };
    handler.onPause = (): void => {
      vm.pause();
    };
    handler.onStop = (): void => {
      vm.pause();
    };
    handler.onPlayNext = (): void => {
      vm.switchPart(vm.partIndex + 1);
    };
    handler.onPlayPrevious = (): void => {
      vm.switchPart(vm.partIndex - 1);
    };
    handler.onSeek = (timeMs: number): void => {
      vm.seekTotal(timeMs);
    };
    handler.onFastForward = (): void => {
      // 步长与 metadata.skipIntervals(10s) 一致；钳制边界（mapTotal 不钳负值）
      vm.seekTotal(Math.min(vm.currentMs + 10000, vm.totalMs > 0 ? vm.totalMs : vm.currentMs + 10000));
    };
    handler.onRewind = (): void => {
      vm.seekTotal(Math.max(0, vm.currentMs - 10000));
    };
    return handler;
  }

  /** 激活播控会话（不阻塞起播链路） */
  private activateSession(video: Video, part: Part): void {
    const context = AppContextHolder.get();
    if (context === null) {
      return;
    }
    this.session.activate(context, video, this.partIndex, part.title, this.totalMs,
      AVSessionOwner.OFFLINE);
  }

  /** 状态事件点上报（无轮询） */
  private syncSessionState(error: boolean = false): void {
    this.session.updatePlaybackState(AVSessionOwner.OFFLINE,
      this.coreState === PlayerCoreState.PLAYING, this.currentMs, this.speed,
      this.coreState === PlayerCoreState.COMPLETED, error, this.isBuffering);
  }

  /** seek 后锚点补报（播控中心立即回设新位置，防止按旧位置/旧倍速推算回弹） */
  private syncSessionPosition(): void {
    this.session.updatePlaybackState(AVSessionOwner.OFFLINE,
      this.coreState === PlayerCoreState.PLAYING, this.currentMs, this.speed);
  }

  // ============ 弹幕（接线支撑） ============

  /** 当前分集弹幕文件绝对路径（DanmakuView 直接消费） */
  danmuPathOfCurrent(): string {
    const video: Video | null = this.video;
    if (video === null) {
      return '';
    }
    const part: Part | undefined = video.parts[this.partIndex];
    return part !== undefined ? this.engine.danmuPathOf(video.hid, part.order) : '';
  }

  /** 更新弹幕（缺失提示条「更新」按钮）：重拉当前分集 danmu.xml */
  async updateDanmu(): Promise<boolean> {
    const video: Video | null = this.video;
    if (video === null) {
      return false;
    }
    const part: Part | undefined = video.parts[this.partIndex];
    if (part === undefined) {
      return false;
    }
    const ok: boolean = await this.engine.updateDanmu(video.hid, [part.order]);
    if (ok) {
      this.refreshDanmuMissing();
      //  接线点：成功后通知 DanmakuService 重新加载 danmuPathOfCurrent()
    }
    return ok;
  }

  // ============ 内部：加载链路 ============

  /** 分集加载（token 防竞态） */
  private async playPartInternal(index: number, startMs: number): Promise<void> {
    const video: Video | null = this.video;
    if (video === null || index < 0 || index >= video.parts.length) {
      return;
    }
    const token: number = ++this.token;
    this.partIndex = index;
    this.partLoading = true;
    this.playbackError = '';
    this.resumeTipVisible = false;
    this.isBuffering = false;
    this.currentMs = startMs;
    this.totalMs = 0;
    this.stopProgressTimer();
    this.releaseCore();
    // 礼让在线播放（不触碰 VideoDetailVM 回调槽）
    VideoDetailVM.shared().pause();
    this.refreshDanmuMissing();

    const part: Part = video.parts[index];
    const usable: Durl[] = part.durls.filter((d: Durl): boolean => d.url.length > 0 || d.cachePath.length > 0);
    if (usable.length === 0) {
      this.failPart(token, '缓存文件缺失');
      return;
    }
    // 历史立记（lastplay 指向当前分集）
    this.history.saveBreakpoint(video, index, startMs);
    // 播控会话激活（owner=offline；此时时长未知，prepared 后 updateDuration 补报）
    this.activateSession(video, part);

    let player: media.AVPlayer;
    try {
      player = await media.createAVPlayer();
    } catch (err) {
      this.failPart(token, '播放器创建失败');
      return;
    }
    if (token !== this.token) {
      this.destroyQuietly(player);
      return;
    }
    this.player = player;
    this.registerEvents(player, token);

    const playlist: SegmentPlaylist = new SegmentPlaylist(player);
    playlist.onSegmentChanged = (segIndex: number): void => {
      this.currentMs = playlist.totalPositionMs();
      //  接线点：弹幕时间轴 = offsetBeforeIndex(segIndex) + 段内时间
    };
    this.playlist = playlist;
    const first: media.MediaSource | undefined = playlist.begin(usable);
    if (first === undefined) {
      this.failPart(token, '缓存文件缺失');
      return;
    }
    try {
      await player.setMediaSource(first);
    } catch (err) {
      this.failPart(token, '缓存读取失败');
      return;
    }
    if (token !== this.token) {
      return;
    }
    // setMediaSource 仅发起异步加载（idle→initialized 实测 6~43ms，fd 源同样适用）：
    // 冒进设 surfaceId 会被 5400102 拒绝并把状态机带崩——真机离线"视频加载失败"根因，
    // 与 PlayerController.waitForSourceInit 同构修复
    const initOk: boolean = await this.waitForSourceInit(player, token);
    if (token !== this.token) {
      return;
    }
    if (!initOk) {
      // 源加载失败（error 监听已 failPart 上抛，此处不重复）
      return;
    }
    if (this.surfaceId.length > 0) {
      player.surfaceId = this.surfaceId;
    }
    // 余段追加（离线无 SEQUENTIAL 兜底：任一段失败该分集报错，见文件头偏差声明）
    for (let i = 1; i < usable.length; i++) {
      const source: media.MediaSource | undefined = playlist.appendSource(i);
      if (source === undefined) {
        this.failPart(token, '缓存文件缺失');
        return;
      }
      try {
        const id: string = await player.addPlaybackMediaSource(source);
        playlist.registerSourceId(i, id);
      } catch (err) {
        this.failPart(token, '缓存读取失败');
        return;
      }
      if (token !== this.token) {
        return;
      }
    }
    this.pendingSeekMs = startMs;
    this.updateState(token, PlayerCoreState.PREPARING);
    try {
      await player.prepare();
    } catch (err) {
      this.failPart(token, '视频加载失败');
    }
  }

  /**
   * 等待媒体源就绪（idle → initialized 异步跃迁）。
   * setMediaSource 仅发起异步加载，真正就绪以 stateChange='initialized' 为准；
   * surfaceId/prepare 前置要求，未就绪调用会被 5400102（Operation Not Permit）拒绝。
   * 返回 false 表示源加载失败（已触 error→failPart，不重复上抛）。
   * （与 PlayerController.waitForSourceInit 同构；其方法 private 不可复用）
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

  /** 统一失败出口（无自动重试，见偏差声明） */
  private failPart(token: number, message: string): void {
    if (token !== this.token) {
      return;
    }
    this.stopProgressTimer();
    this.updateState(token, PlayerCoreState.ERROR);
    this.partLoading = false;
    this.playbackError = message;
  }

  private updateState(token: number, state: PlayerCoreState): void {
    if (token !== this.token) {
      return;
    }
    this.coreState = state;
    if (state === PlayerCoreState.READY || state === PlayerCoreState.ERROR) {
      this.partLoading = false;
    }
    // 播控状态事件点上报（错误态带标记；长时任务申请/释放由 service 内部联动）
    this.syncSessionState(state === PlayerCoreState.ERROR);
  }

  // ============ 内部：事件与状态机 ============

  private registerEvents(player: media.AVPlayer, token: number): void {
    player.on('stateChange', (state: string, reason: media.StateChangeReason): void => {
      this.handleState(token, state);
      // 源就绪等待路由（waitForSourceInit 临时槽；由常驻监听统一转发，避免临时监听+off
      // 在部分 SDK 版本把常驻 stateChange 一并移除）
      if (this.initSettler !== null) {
        this.initSettler(state);
      }
    });
    player.on('error', (err: BusinessError): void => {
      this.failPart(token, `播放出错(${err.code})`);
    });
    player.on('durationUpdate', (duration: number): void => {
      if (token !== this.token || this.playlist === null) {
        return;
      }
      this.playlist.observeDuration(duration);
      const total: number = this.playlist.knownTotalMs();
      this.totalMs = total > 0 ? total : duration;
    });
    player.on('timeUpdate', (time: number): void => {
      if (token !== this.token || this.playlist === null) {
        return;
      }
      this.currentMs = this.playlist.totalPositionMs();
      this.saveBreakpointThrottled();
    });
    player.on('seekDone', (seekDoneTime: number): void => {
      if (token !== this.token || this.playlist === null) {
        return;
      }
      this.currentMs = this.playlist.totalPositionMs();
    });
    // SDK 26 独立注册方法（回调携带 media source id）
    player.onPlaybackContentChanged((contentId: string): void => {
      if (token !== this.token || this.playlist === null) {
        return;
      }
      this.playlist.handleContentChanged(contentId);
    });
    player.on('bufferingUpdate', (infoType: media.BufferingInfoType, value: number): void => {
      if (token !== this.token) {
        return;
      }
      const busy: boolean = infoType === media.BufferingInfoType.BUFFERING_START;
      if (busy !== this.isBuffering) {
        this.isBuffering = busy;
        // 缓冲态上报（播控中心显示播放中但进度不走）
        this.syncSessionState();
      }
    });
  }

  private handleState(token: number, state: string): void {
    switch (state) {
      case 'prepared':
        this.onPrepared(token);
        break;
      case 'playing':
        this.startProgressTimer(token);
        this.updateState(token, PlayerCoreState.PLAYING);
        break;
      case 'paused':
        this.stopProgressTimer();
        this.updateState(token, PlayerCoreState.PAUSED);
        break;
      case 'completed':
        this.handleCompleted(token);
        break;
      case 'stopped':
        this.stopProgressTimer();
        this.updateState(token, PlayerCoreState.STOPPED);
        break;
      case 'released':
        this.stopProgressTimer();
        break;
      default:
        break;
    }
  }

  /** prepared：循环模式/倍速/起播 seek/自动播放 */
  private onPrepared(token: number): void {
    const player: media.AVPlayer | null = this.player;
    const playlist: SegmentPlaylist | null = this.playlist;
    if (player === null || playlist === null || token !== this.token) {
      return;
    }
    this.updateState(token, PlayerCoreState.READY);
    // prepared 补报真实总时长（修起播 duration=0 → 播控进度条不可用样式）
    this.session.updateDuration(AVSessionOwner.OFFLINE, this.totalMs);
    // 播放列表不循环（分集播完由连播逻辑决定）
    if (playlist.getSegments().length > 1) {
      try {
        player.playlistLoopMode = media.PlaylistLoopMode.PLAYLIST_LOOP_MODE_NONE;
      } catch (err) {
        // 不支持时依赖 completed 语义兜底
      }
    }
    // 倍速记忆（同步 void API）
    if (this.speed !== 1.0) {
      try {
        player.setSpeed(OfflinePlayerVM.toPlaybackSpeed(this.speed));
      } catch (err) {
        // 忽略
      }
    }
    // 画面缩放记忆（R7 落点二：prepared 后即时生效）
    if (this.scaleMode !== 'fit') {
      try {
        player.videoScaleType = OfflinePlayerVM.toVideoScaleType(this.scaleMode);
      } catch (err) {
        // 忽略
      }
    }
    // 起播 seek（断点续播）
    const startMs: number = this.pendingSeekMs;
    this.pendingSeekMs = 0;
    const autoPlayNow = (): void => {
      player.play().catch((): void => {
      });
    };
    if (startMs > 0) {
      const pos = playlist.mapTotal(startMs);
      if (pos.index > 0 && playlist.getSourceId(pos.index).length > 0) {
        player.advanceToMediaSource(playlist.getSourceId(pos.index))
          .then((): void => {
            player.seek(pos.withinMs);
            autoPlayNow();
          })
          .catch((): void => {
            autoPlayNow(); // 跨段起播失败退回首段播
          });
      } else {
        player.seek(pos.withinMs);
        autoPlayNow();
      }
    } else {
      autoPlayNow();
    }
  }

  /** 分集播完：已看标记 +  连播（仅下一分集已缓存完成才连播） */
  private handleCompleted(token: number): void {
    this.stopProgressTimer();
    const video: Video | null = this.video;
    if (video === null || token !== this.token) {
      return;
    }
    this.currentMs = this.totalMs > 0 ? this.totalMs : this.currentMs;
    this.updateState(token, PlayerCoreState.COMPLETED);
    this.history.markPartCompleted(video, this.partIndex);
    if (PreferenceStore.playerConfig().autoNext) {
      const next: number = this.partIndex + 1;
      const nextPart: Part | undefined = video.parts[next];
      if (nextPart !== undefined && nextPart.flag === DownloadStatus.COMPLETED) {
        this.playPartInternal(next, 0);
      }
    }
  }

  /** 进度推送（500ms 独立定时器） */
  private startProgressTimer(token: number): void {
    this.stopProgressTimer();
    this.progressTimer = setInterval((): void => {
      const playlist: SegmentPlaylist | null = this.playlist;
      if (playlist === null || token !== this.token) {
        return;
      }
      this.currentMs = playlist.totalPositionMs();
      const total: number = playlist.knownTotalMs();
      if (total > 0) {
        this.totalMs = total;
      }
      this.saveBreakpointThrottled();
    }, 500);
  }

  private stopProgressTimer(): void {
    if (this.progressTimer >= 0) {
      clearInterval(this.progressTimer);
      this.progressTimer = -1;
    }
  }

  /** 断点节流写（5s，播放中才写） */
  private saveBreakpointThrottled(): void {
    if (this.coreState !== PlayerCoreState.PLAYING) {
      return;
    }
    const now: number = Date.now();
    if (now - this.lastBreakpointAt < OfflinePlayerVM.BREAKPOINT_INTERVAL) {
      return;
    }
    this.lastBreakpointAt = now;
    const video: Video | null = this.video;
    if (video !== null) {
      this.history.saveBreakpoint(video, this.partIndex, this.currentMs);
    }
  }

  private showResumeTip(partIndex: number, positionMs: number): void {
    this.resumeTipVisible = true;
    this.resumeTipText = VideoDetailVM.formatClock(positionMs);
  }

  /** 弹幕文件缺失检测（当前分集目录 danmu.xml） */
  private refreshDanmuMissing(): void {
    const video: Video | null = this.video;
    if (video === null) {
      this.danmuMissing = false;
      return;
    }
    const part: Part | undefined = video.parts[this.partIndex];
    if (part === undefined) {
      this.danmuMissing = false;
      return;
    }
    const path: string = this.engine.danmuPathOf(video.hid, part.order);
    let exists: boolean = false;
    try {
      exists = path.length > 0 && fileIo.accessSync(path);
    } catch (err) {
      exists = false;
    }
    this.danmuMissing = !exists;
  }

  /** 释放底层 AVPlayer（含本地 fd） */
  private releaseCore(): void {
    if (this.playlist !== null) {
      this.playlist.releaseLocalFds();
    }
    this.playlist = null;
    this.initSettler = null;
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

  private destroyQuietly(player: media.AVPlayer): void {
    try {
      player.release();
    } catch (err) {
      // 忽略
    }
  }

  /** 倍速映射（与 PlayerController 同构，其方法为 private 不可复用） */
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
