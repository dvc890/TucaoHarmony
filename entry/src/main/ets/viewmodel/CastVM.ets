/**
 * 投屏面板/控制条共享 VM
 * - 单例 @ObservedV2：面板态（可见/发现中/设备列表/面板错误）+
 *   投播态（投播中/连接中/通道/设备名/远端镜像/投播错误）
 * - 双通道路由：系统投播（CastController，选择器驱动连接）与 DLNA 兜底（DlnaEngine）
 * - 目标构建：VideoRepository.resolvePartDurls(part) 与本机播放同源解析
 *   （已下载本地文件 / 直连 / playurl 多段）；fdSrc 失败 → LocalHttpServer 推送回退（仅一次）
 * - 守卫（@Computed + @Monitor 监听 VideoDetailVM）：
 *   · 投播中切集 → 远端换集重投 + 本机暂停（避免双端声音）
 *   · 投播中本机恢复播放（播控中心 play 等）→ 立即暂停
 *   · 播放页销毁（coreState → IDLE）→ 结束投播（不恢复本地）
 * - 断开恢复：远端镜像位置 → detailVm.seekTo + （原在播时）togglePlay + 断点落盘
 */
import { CastChannel, CastController, CastDevice, CastMediaTarget, CastRemoteState, CastSegment } from '../service/cast/CastController';
import { DlnaEngine, LocalHttpServer } from '../service/cast/DlnaEngine';
import { VideoDetailVM } from './VideoDetailVM';
import { PlayerCoreState } from '../service/player/PlayerController';
import { Durl, Part, Video } from '../model/entity/BaseEntities';
import { VideoRepository } from '../model/repository/VideoRepository';

@ObservedV2
export class CastVM {
  private static instance: CastVM | undefined;

  static shared(): CastVM {
    if (CastVM.instance === undefined) {
      CastVM.instance = new CastVM();
    }
    return CastVM.instance;
  }

  // ============ 面板态 ============
  /** 投屏面板可见 */
  @Trace panelVisible: boolean = false;
  /** DLNA 发现中 */
  @Trace discovering: boolean = false;
  /** 发现的 DLNA 设备列表 */
  @Trace dlnaDevices: CastDevice[] = [];
  /** 面板错误（发现失败/会话失败等，空=无） */
  @Trace panelError: string = '';

  // ============ 投播态 ============
  /** 投播中（远端接管播放） */
  @Trace casting: boolean = false;
  /** 连接/投放进行中 */
  @Trace connecting: boolean = false;
  /** 当前投播通道 */
  @Trace channel: CastChannel = CastChannel.SYSTEM_CAST;
  /** 当前设备名 */
  @Trace deviceName: string = '';
  /** 远端播放镜像（进度/时长为整集总时位） */
  @Trace remote: CastRemoteState = new CastRemoteState();
  /** 投播错误（控制条内展示，空=无） */
  @Trace castError: string = '';

  private readonly detailVm: VideoDetailVM = VideoDetailVM.shared();
  private readonly castController: CastController = CastController.getInstance();
  private readonly dlnaEngine: DlnaEngine = DlnaEngine.getInstance();
  private readonly repo: VideoRepository = VideoRepository.getInstance();
  /** fdSrc 失败回退标记（一次投播会话仅回退一次，避免循环） */
  private httpFallbackTried: boolean = false;
  /** 目标缓存（partIndex + 清晰度一致时复用，换集/退出失效） */
  private cachedTarget: CastMediaTarget | null = null;
  private cachedPartIndex: number = -1;
  private cachedQualitySrc: string = '';
  /** 投播前本机位置/播放态（连接早期失败/断开无远端进度时恢复用） */
  private preCastMs: number = 0;
  private localWasPlaying: boolean = false;

  private constructor() {
    // 系统通道回调
    this.castController.callbacks.onConnected = (device: CastDevice): void => {
      this.onSystemConnected(device);
    };
    this.castController.callbacks.onDisconnected = (resumePositionMs: number): void => {
      this.onDisconnected(resumePositionMs);
    };
    this.castController.callbacks.onRemoteStateChanged = (state: CastRemoteState): void => {
      this.remote = state;
    };
    this.castController.callbacks.onError = (message: string): void => {
      this.onCastError(message);
    };
    // DLNA 通道回调
    this.dlnaEngine.callbacks.onDevicesFound = (devices: CastDevice[]): void => {
      this.dlnaDevices = devices;
      if (devices.length > 0) {
        this.panelError = '';
      }
    };
    this.dlnaEngine.callbacks.onRemoteStateChanged = (state: CastRemoteState): void => {
      this.remote = state;
    };
    this.dlnaEngine.callbacks.onDisconnected = (resumePositionMs: number): void => {
      this.onDisconnected(resumePositionMs);
    };
    this.dlnaEngine.callbacks.onError = (message: string): void => {
      this.onCastError(message);
    };
  }

  // ============ 守卫：监听本机播放态（@Computed + @Monitor 跨实例追踪） ============

  @Computed
  private get watchPartIndex(): number {
    return this.detailVm.partIndex;
  }

  @Computed
  private get watchLocalPlaying(): boolean {
    return this.detailVm.coreState === PlayerCoreState.PLAYING;
  }

  @Computed
  private get watchLocalIdle(): boolean {
    return this.detailVm.coreState === PlayerCoreState.IDLE;
  }

  /** 投播中切集：远端换集重投 + 本机暂停（避免双端声音） */
  @Monitor('watchPartIndex')
  private onWatchPartIndex(monitor: IMonitor): void {
    if (!this.casting) {
      return;
    }
    this.detailVm.pause();
    this.recastCurrentPart();
  }

  /** 投播中本机恢复播放（播控中心 play 等）→ 立即暂停（守卫） */
  @Monitor('watchLocalPlaying')
  private onWatchLocalPlaying(monitor: IMonitor): void {
    if (!this.casting) {
      return;
    }
    this.detailVm.pause();
  }

  /** 播放页销毁（shutdown → IDLE）→ 结束投播（不恢复本地） */
  @Monitor('watchLocalIdle')
  private onWatchLocalIdle(monitor: IMonitor): void {
    if (!this.casting) {
      return;
    }
    this.teardownCast(false);
  }

  // ============ 面板操作 ============

  /** 打开投屏面板（自动开始 DLNA 发现） */
  openPanel(): void {
    const video: Video | null = this.detailVm.video;
    if (video === null || video.parts.length === 0 || this.connecting) {
      return;
    }
    this.panelVisible = true;
    this.panelError = '';
    this.refreshDlna();
  }

  /** 关闭面板（未投播时同时停止发现） */
  closePanel(): void {
    this.panelVisible = false;
    this.connecting = false;
    if (!this.casting) {
      this.dlnaEngine.stopDiscovery();
      this.discovering = false;
    }
  }

  /** 重新扫描 DLNA 设备（4.5s 后未发现则提示） */
  refreshDlna(): void {
    this.discovering = true;
    this.panelError = '';
    this.dlnaDevices = [];
    this.dlnaEngine.startDiscovery();
    setTimeout((): void => {
      this.discovering = false;
      if (this.dlnaDevices.length === 0 && !this.casting) {
        this.panelError = '未发现设备，请确认电视/盒子与手机连接同一 Wi-Fi';
      }
    }, 4500);
  }

  /** 拉起系统投播选择器（Cast+ Stream / DLNA 系统发现） */
  async openSystemPicker(): Promise<void> {
    const video: Video | null = this.detailVm.video;
    if (video === null || video.parts.length === 0 || this.casting) {
      return;
    }
    this.connecting = true;
    this.panelError = '';
    const part: Part | undefined = video.parts[this.detailVm.partIndex];
    const partTitle: string = part !== undefined ? part.title : '';
    const ok: boolean = await this.castController.ensureCastSession(video, this.detailVm.partIndex,
      partTitle, this.detailVm.totalMs);
    if (!ok) {
      this.connecting = false;
      return;
    }
    // 预构建目标（用户选定设备后立即可投）
    await this.buildTarget();
    await this.castController.openSystemPicker();
  }

  /** 投放至 DLNA 设备（列表项点击；投播中点其他设备 = 换设备） */
  async castToDevice(device: CastDevice): Promise<void> {
    const video: Video | null = this.detailVm.video;
    if (video === null || video.parts.length === 0 || this.connecting) {
      return;
    }
    const current: CastDevice | null = this.dlnaEngine.currentDevice();
    if (this.casting && current !== null && current.deviceId === device.deviceId) {
      return;
    }
    // 换设备：先静默断开旧链路（不恢复本地）
    if (this.casting) {
      await this.silentlyStopEngines();
      this.casting = false;
      this.deviceName = '';
      this.remote = new CastRemoteState();
    }
    this.connecting = true;
    this.panelError = '';
    this.preCastMs = this.detailVm.currentMs;
    this.localWasPlaying = this.detailVm.coreState === PlayerCoreState.PLAYING;
    await this.detailVm.pause();
    this.httpFallbackTried = false;
    const target: CastMediaTarget | null = await this.buildTarget();
    if (target === null) {
      this.connecting = false;
      // 投放失败：恢复本机原播放态（位置未变，仅续播）
      if (this.localWasPlaying) {
        await this.detailVm.togglePlay();
      }
      return;
    }
    await this.dlnaEngine.castToDevice(device, target);
    if (this.dlnaEngine.isCasting()) {
      this.channel = device.channel;
      this.deviceName = device.deviceName;
      this.casting = true;
      this.connecting = false;
      this.panelVisible = false;
      this.castError = '';
    } else {
      this.connecting = false;
    }
  }

  // ============ 投播控制（CastControlBar 直调） ============

  /** 远端 播放/暂停 切换 */
  async togglePlay(): Promise<void> {
    if (!this.casting) {
      return;
    }
    if (this.remote.playing) {
      await this.pauseRemote();
    } else {
      if (this.channel === CastChannel.SYSTEM_CAST) {
        await this.castController.play();
      } else {
        await this.dlnaEngine.play();
      }
    }
  }

  /** 远端 暂停 */
  async pauseRemote(): Promise<void> {
    if (!this.casting) {
      return;
    }
    if (this.channel === CastChannel.SYSTEM_CAST) {
      await this.castController.pause();
    } else {
      await this.dlnaEngine.pause();
    }
  }

  /** 远端 跳转（整集总时位 ms） */
  async seekTo(totalMs: number): Promise<void> {
    if (!this.casting) {
      return;
    }
    if (this.channel === CastChannel.SYSTEM_CAST) {
      await this.castController.seekTo(totalMs);
    } else {
      await this.dlnaEngine.seekTo(totalMs);
    }
  }

  /** 远端 音量（归一化 0~1） */
  async setVolume(volume01: number): Promise<void> {
    if (!this.casting) {
      return;
    }
    if (this.channel === CastChannel.SYSTEM_CAST) {
      await this.castController.setVolume(volume01);
    } else {
      await this.dlnaEngine.setVolume(volume01);
    }
  }

  /** 退出投屏（控制条退出按钮）：断开远端并恢复本地播放 */
  async exitCast(): Promise<void> {
    await this.teardownCast(true);
  }

  // ============ 内部：连接/断开/回退 ============

  /** 系统通道设备连接成功：暂停本机 → 投放当前分集 */
  private async onSystemConnected(device: CastDevice): Promise<void> {
    this.channel = device.channel;
    this.deviceName = device.deviceName;
    this.casting = true;
    this.connecting = true;
    this.panelVisible = false;
    this.castError = '';
    this.preCastMs = this.detailVm.currentMs;
    this.localWasPlaying = this.detailVm.coreState === PlayerCoreState.PLAYING;
    await this.detailVm.pause();
    this.httpFallbackTried = false;
    const target: CastMediaTarget | null = await this.buildTarget();
    if (target === null) {
      // 目标构建失败：断开远端并恢复本地原位
      this.casting = false;
      this.connecting = false;
      this.deviceName = '';
      this.remote = new CastRemoteState();
      await this.castController.stopCasting();
      await this.resumeLocalAt(this.preCastMs, this.localWasPlaying);
      return;
    }
    await this.castController.startCast(target);
    this.connecting = false;
  }

  /** 引擎上报断开（设备离线/设备端停止/链路错误）：恢复本地播放 */
  private async onDisconnected(resumePositionMs: number): Promise<void> {
    if (!this.casting) {
      return;
    }
    const wasPlaying: boolean = this.remote.positionMs > 0
      ? this.remote.playing : this.localWasPlaying;
    const resumeMs: number = resumePositionMs > 0 ? resumePositionMs : this.preCastMs;
    this.casting = false;
    this.connecting = false;
    this.deviceName = '';
    this.castError = '';
    this.remote = new CastRemoteState();
    await this.resumeLocalAt(resumeMs, wasPlaying);
  }

  /** 错误分流：fdSrc 本地文件失败 → HTTP 推送回退；其余按面板/控制条归位展示 */
  private onCastError(message: string): void {
    if (this.casting && !this.httpFallbackTried
      && this.channel === CastChannel.SYSTEM_CAST
      && message.indexOf('本地文件') >= 0) {
      //  场景 6：本地文件系统通道失败 → 经局域网 HTTP 推送重建目标（仅一次）
      this.httpFallbackTried = true;
      this.rebuildWithHttpFallback();
      return;
    }
    if (!this.casting || this.panelVisible) {
      this.panelError = message;
    } else {
      this.castError = message;
    }
  }

  /** fdSrc 失败回退：本地文件段改 LocalHttpServer URL 后重投 */
  private async rebuildWithHttpFallback(): Promise<void> {
    const target: CastMediaTarget | null = this.cachedTarget;
    if (target === null) {
      this.castError = '投播失败，已恢复本机播放';
      await this.teardownCast(true);
      return;
    }
    const server: LocalHttpServer = LocalHttpServer.getInstance();
    const base: string | null = await server.start();
    if (base === null) {
      this.castError = '局域网推送服务启动失败';
      await this.teardownCast(true);
      return;
    }
    for (let i: number = 0; i < target.segments.length; i++) {
      const seg: CastSegment = target.segments[i];
      if (seg.localPath.length > 0) {
        const url: string | null = server.registerFile(seg.localPath);
        if (url !== null) {
          seg.url = url;
          seg.localPath = '';
        }
      }
    }
    // 远端已有真实进度则从其续投，否则保留原起始位置
    if (this.remote.positionMs > 0) {
      target.startOffsetMs = this.remote.positionMs;
    }
    await this.castController.startCast(target);
  }

  /** 投播中切集：换目标重投至当前设备 */
  private async recastCurrentPart(): Promise<void> {
    this.cachedTarget = null;
    this.connecting = true;
    const target: CastMediaTarget | null = await this.buildTarget();
    if (target === null) {
      this.connecting = false;
      return;
    }
    if (this.channel === CastChannel.SYSTEM_CAST) {
      await this.castController.startCast(target);
    } else {
      const device: CastDevice | null = this.dlnaEngine.currentDevice();
      if (device !== null) {
        await this.dlnaEngine.castToDevice(device, target);
      }
    }
    this.connecting = false;
  }

  /** 结束投播：断开远端 → 归还播控会话 →（可选）恢复本地播放 */
  private async teardownCast(resumeLocal: boolean): Promise<void> {
    // 远端无真实进度（刚连接即退出）时回退投播前本机位置/播放态
    const wasPlaying: boolean = this.remote.positionMs > 0
      ? this.remote.playing : this.localWasPlaying;
    const resumeMs: number = this.remote.positionMs > 0
      ? this.remote.positionMs : this.preCastMs;
    this.casting = false;
    this.connecting = false;
    this.deviceName = '';
    this.castError = '';
    this.remote = new CastRemoteState();
    await this.silentlyStopEngines();
    this.panelVisible = false;
    if (resumeLocal) {
      await this.resumeLocalAt(resumeMs, wasPlaying);
    }
  }

  /** 静默断开双通道（不触发引擎回调；幂等） */
  private async silentlyStopEngines(): Promise<void> {
    if (this.castController.isCasting()) {
      await this.castController.stopCasting();
    }
    if (this.dlnaEngine.isCasting()) {
      await this.dlnaEngine.stopCasting();
    }
  }

  /** 恢复本地播放：跳转到远端位置 + 原在播时续播 + 断点落盘 */
  private async resumeLocalAt(resumePositionMs: number, wasPlaying: boolean): Promise<void> {
    const detail: VideoDetailVM = this.detailVm;
    if (detail.video === null) {
      return;
    }
    await detail.seekTo(resumePositionMs);
    if (wasPlaying) {
      await detail.togglePlay();
    }
    detail.saveBreakpointNow();
  }

  /** 构建投播目标（与本机播放同源解析；缓存 partIndex+清晰度） */
  private async buildTarget(): Promise<CastMediaTarget | null> {
    const video: Video | null = this.detailVm.video;
    if (video === null) {
      return null;
    }
    const partIndex: number = this.detailVm.partIndex;
    const part: Part | undefined = video.parts[partIndex];
    if (part === undefined) {
      return null;
    }
    const qualitySrc: string = this.detailVm.currentQualitySrc;
    // 缓存命中：仅刷新起始位置
    if (this.cachedTarget !== null && this.cachedPartIndex === partIndex
      && this.cachedQualitySrc === qualitySrc) {
      this.cachedTarget.startOffsetMs = this.detailVm.currentMs;
      return this.cachedTarget;
    }
    try {
      const durls: Durl[] = await this.repo.resolvePartDurls(part);
      const usable: Durl[] = durls.filter((d: Durl): boolean => d.url.length > 0 || d.cachePath.length > 0);
      if (usable.length === 0) {
        this.panelError = '暂无可用播放地址';
        return null;
      }
      const target: CastMediaTarget = new CastMediaTarget();
      target.assetId = `${video.hid}-p${partIndex + 1}`;
      target.title = video.title;
      target.subtitle = part.title;
      target.artist = video.user;
      target.thumb = video.thumb;
      let sumMs: number = 0;
      for (let i: number = 0; i < usable.length; i++) {
        const d: Durl = usable[i];
        const seg: CastSegment = new CastSegment();
        if (d.cachePath.length > 0) {
          seg.localPath = d.cachePath;
        } else {
          seg.url = d.url;
        }
        seg.lengthMs = d.length;
        sumMs += d.length;
        target.segments.push(seg);
      }
      target.totalMs = this.detailVm.totalMs > 0 ? this.detailVm.totalMs : sumMs;
      target.startSegment = 0;
      target.startOffsetMs = this.detailVm.currentMs;
      this.cachedTarget = target;
      this.cachedPartIndex = partIndex;
      this.cachedQualitySrc = qualitySrc;
      return target;
    } catch (err) {
      this.panelError = '解析播放地址失败，请重试';
      return null;
    }
  }
}
