/**
 * 系统投播控制器（主通道）
 * - AVSession 系统通道：Cast+ Stream / DLNA 双协议（setAVMetadata filter 声明）
 * - 设备选择：AVCastPickerHelper.select() 拉起系统设备半模态（设备发现/连接/认证由系统完成）
 * - 会话接管：一个 ability 仅一个 AVSession——投播期间接管（先释放 AVSessionService 基础会话），
 *   结束后以其公开 activate() 归还播控中心集成（AVSessionService 对  只读）
 * - 播放链路：outputDeviceChange(CONNECTED) → getAVCastController → prepare/start(AVQueueItem)；
 *   多段视频段链式投放（远端 COMPLETED → 下一段 start），进度镜像统一折算"整集总时位"
 * - 控制：sendControlCommand play/pause/seek/setVolume；playbackStateChange('all') 状态同步；
 *   castControlIoError / outputDeviceChange(DISCONNECTED) → 断开回调带恢复位置
 * - 本地文件：优先 fdSrc（plan ）；投播失败由 CastVM 回退 LocalHttpServer URL 重建目标
 */
import { avSession } from '@kit.AVSessionKit';
import { media } from '@kit.MediaKit';
import { fileIo } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Video } from '../../model/entity/BaseEntities';
import { AVSessionService, AVSessionOwner } from '../player/AVSessionService';
import { AppContextHolder } from '../../common/GlobalState';

/** 投屏通道 */
export enum CastChannel {
  /** AVSession 系统投播（Cast+ Stream / DLNA 协议，系统设备选择器） */
  SYSTEM_CAST = 0,
  /** 自研 DLNA 兜底通道（SSDP 发现 + SOAP 控制 + 本地 HTTP 推送） */
  DLNA_CUSTOM = 1
}

/** 投屏设备（统一视图；系统通道设备信息由系统选择器呈现，连接后仅得知名称） */
export class CastDevice {
  channel: CastChannel = CastChannel.SYSTEM_CAST;
  deviceId: string = '';
  deviceName: string = '';
  /** DLNA：AVTransport 控制地址 */
  controlUrl: string = '';
  /** DLNA：RenderingControl 控制地址（缺失则该设备不支持音量调节） */
  renderingControlUrl: string = '';
}

/** 投屏媒体段（远程 URL 与本地文件路径二选一） */
export class CastSegment {
  /** 远程地址（url 非空时生效） */
  url: string = '';
  /** 本地文件路径（localPath 非空时生效，走 fdSrc） */
  localPath: string = '';
  /** 段时长 ms */
  lengthMs: number = 0;
}

/** 投屏媒体目标（一次投播任务；多段视频 = segments 段链） */
export class CastMediaTarget {
  assetId: string = '';
  title: string = '';
  subtitle: string = '';
  artist: string = '';
  thumb: string = '';
  /** 整集总时长 ms */
  totalMs: number = 0;
  segments: CastSegment[] = [];
  /** 起始段索引 */
  startSegment: number = 0;
  /** 起始整集总时位 ms（内部折算为段内偏移） */
  startOffsetMs: number = 0;
}

/** 远端播放镜像（进度/时长均为整集总时位，多段已折算） */
export class CastRemoteState {
  playing: boolean = false;
  positionMs: number = 0;
  durationMs: number = 0;
  /** 归一化音量 0~1（设备音量/maxVolume） */
  volume: number = 1.0;
  /** 设备端是否支持音量调节 */
  volumeSupported: boolean = true;
}

/** 系统通道回调（CastVM 注入） */
export class CastControllerCallbacks {
  /** 设备连接成功（系统选择器选定设备后触发） */
  onConnected: ((device: CastDevice) => void) | null = null;
  /** 连接断开（携带恢复用整集总时位 ms） */
  onDisconnected: ((resumePositionMs: number) => void) | null = null;
  /** 远端状态镜像变化 */
  onRemoteStateChanged: ((state: CastRemoteState) => void) | null = null;
  /** 投播链路错误（start 失败/IO 错误；CastVM 可回退本地 HTTP 推送） */
  onError: ((message: string) => void) | null = null;
}

/** 系统投播单例 */
export class CastController {
  private static instance: CastController | undefined;

  static getInstance(): CastController {
    if (CastController.instance === undefined) {
      CastController.instance = new CastController();
    }
    return CastController.instance;
  }

  /** 接管的投播会话（投播期间本 ability 唯一 AVSession） */
  private session: avSession.AVSession | null = null;
  private castController: avSession.AVCastController | null = null;
  private pickerHelper: avSession.AVCastPickerHelper | null = null;
  /** 回调（CastVM 注入） */
  readonly callbacks: CastControllerCallbacks = new CastControllerCallbacks();
  /** 当前连接设备 */
  private activeDevice: CastDevice | null = null;
  /** 当前投播目标 */
  private target: CastMediaTarget | null = null;
  /** 当前段索引 */
  private segmentIndex: number = 0;
  /** 当前段之前的累计时长（总时位折算基准） */
  private segmentBaseMs: number = 0;
  /** 远端镜像（内部最新值，断开时取恢复位置） */
  private remoteState: CastRemoteState = new CastRemoteState();
  /** 设备音量刻度上限（AVPlaybackState.maxVolume，缺省 15） */
  private maxVolume: number = 15;
  /** 本地文件句柄（fdSrc 生命周期管理） */
  private localFile: fileIo.File | null = null;
  /** 会话归还信息（stopCasting 后重建 AVSessionService 会话） */
  private restoreVideo: Video | null = null;
  private restorePartIndex: number = 0;
  private restorePartTitle: string = '';
  private restoreDurationMs: number = 0;
  /** 断开流程进行中标记（防重入） */
  private disconnecting: boolean = false;

  private constructor() {
  }

  /** 是否投播中 */
  isCasting(): boolean {
    return this.activeDevice !== null;
  }

  /** 当前连接设备（未连接返回 null） */
  currentDevice(): CastDevice | null {
    return this.activeDevice;
  }

  /**
   * 打开系统投播选择器（设备发现/连接/认证由系统完成）
   * 前置：ensureCastSession 已就绪（filter 双协议声明后才搜得到设备）
   */
  async openSystemPicker(): Promise<void> {
    const context = AppContextHolder.get();
    if (context === null) {
      this.callbacks.onError?.('上下文未就绪，无法投屏');
      return;
    }
    if (this.pickerHelper === null) {
      this.pickerHelper = new avSession.AVCastPickerHelper(context);
    }
    const options: avSession.AVCastPickerOptions = {
      sessionType: 'video'
    };
    try {
      await this.pickerHelper.select(options);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      this.callbacks.onError?.(`拉起投播设备选择失败：${error.message}`);
    }
  }

  /**
   * 确保投播会话就绪（幂等）：
   * 1. 释放 AVSessionService 基础播控会话（一个 ability 仅一个 AVSession）
   * 2. 创建投播会话：filter 声明 Cast+ Stream | DLNA 双协议 + url-cast 能力声明
   * 3. 激活并挂 outputDeviceChange / 播控中心命令监听
   * @param partIndex 当前分集索引（归还时重建元数据用，assetId=hid#partIndex）
   * @return 会话是否就绪
   */
  async ensureCastSession(video: Video, partIndex: number, partTitle: string,
    durationMs: number): Promise<boolean> {
    if (this.session !== null) {
      return true;
    }
    const context = AppContextHolder.get();
    if (context === null) {
      this.callbacks.onError?.('上下文未就绪，无法投屏');
      return false;
    }
    try {
      // 接管唯一会话（AVSessionService 公开 destroy；结束后归还）
      await AVSessionService.getInstance().destroy();
      const session: avSession.AVSession = await avSession.createAVSession(context, 'tucaoCast', 'video');
      this.session = session;
      this.restoreVideo = video;
      this.restorePartIndex = partIndex;
      this.restorePartTitle = partTitle;
      this.restoreDurationMs = durationMs;
      // 元数据 + 双协议 filter（未声明则默认仅 Cast+ Stream，搜不到 DLNA 设备）
      const metadata: avSession.AVMetadata = {
        assetId: video.hid,
        title: video.title,
        subtitle: partTitle,
        artist: video.user,
        duration: durationMs,
        mediaImage: video.thumb,
        filter: avSession.ProtocolType.TYPE_CAST_PLUS_STREAM | avSession.ProtocolType.TYPE_DLNA
      };
      await session.setAVMetadata(metadata);
      // url-cast 能力声明（未声明则设备选择器搜不到设备）
      const extras: Record<string, Object> = {};
      extras[avSession.ExtraKey.REQUIRE_ABILITY_LIST] = ['url-cast'];
      await session.setExtras(extras);
      this.registerSessionEvents(session);
      await session.activate();
      return true;
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      this.session = null;
      this.callbacks.onError?.(`投播会话创建失败：${error.message}`);
      return false;
    }
  }

  /**
   * 投放媒体（系统通道；连接成功后由 CastVM 调用）
   * 多段目标按段链式投放：起始段立即 start，其后各段在远端 COMPLETED 时续投
   */
  async startCast(target: CastMediaTarget): Promise<void> {
    const controller: avSession.AVCastController | null = this.castController;
    if (controller === null) {
      this.callbacks.onError?.('投播未连接，无法投放');
      return;
    }
    this.target = target;
    // 更新会话归还信息（投播中切集后标题/时长以最新为准）
    this.restorePartTitle = target.subtitle;
    this.restoreDurationMs = target.totalMs;
    // 总时位 → 段索引 + 段内偏移
    let index: number = 0;
    let offset: number = target.startOffsetMs;
    while (index < target.segments.length - 1 && offset >= target.segments[index].lengthMs) {
      offset -= target.segments[index].lengthMs;
      index++;
    }
    await this.startSegment(index, offset);
  }

  /** 远端：播放 */
  async play(): Promise<void> {
    await this.sendCommand('play');
  }

  /** 远端：暂停 */
  async pause(): Promise<void> {
    await this.sendCommand('pause');
  }

  /** 远端：跳转（整集总时位 ms） */
  async seekTo(totalMs: number): Promise<void> {
    const target: CastMediaTarget | null = this.target;
    if (target === null) {
      return;
    }
    // 总时位 → 段内偏移（不跨段 seek：落在当前段内直接 seek，跨段则换段重投）
    let index: number = 0;
    let offset: number = totalMs;
    while (index < target.segments.length - 1 && offset >= target.segments[index].lengthMs) {
      offset -= target.segments[index].lengthMs;
      index++;
    }
    if (index !== this.segmentIndex) {
      await this.startSegment(index, offset);
      return;
    }
    await this.sendCommand('seek', offset);
    // 本地镜像先行更新（远端回调为准的兜底刷新）
    this.remoteState.positionMs = totalMs;
    this.pushRemoteState();
  }

  /** 远端：设置音量（归一化 0~1 → 设备刻度） */
  async setVolume(volume01: number): Promise<void> {
    const scale: number = this.maxVolume > 0 ? this.maxVolume : 15;
    const deviceVolume: number = Math.round(Math.min(1, Math.max(0, volume01)) * scale);
    await this.sendCommand('setVolume', deviceVolume);
    this.remoteState.volume = deviceVolume / scale;
    this.pushRemoteState();
  }

  /**
   * 结束投播（主动退出；幂等）
   * 断开远端 → 释放控制器 → 销毁投播会话 → 归还 AVSessionService 播控中心集成
   */
  async stopCasting(): Promise<void> {
    await this.teardown(false);
  }

  /** 内部：断开全链路（ioError/设备离线 = silent，主动退出上报 onDisconnected） */
  private async teardown(invokeCallback: boolean): Promise<void> {
    if (this.disconnecting) {
      return;
    }
    this.disconnecting = true;
    const resumeMs: number = this.remoteState.positionMs;
    const session: avSession.AVSession | null = this.session;
    const controller: avSession.AVCastController | null = this.castController;
    this.activeDevice = null;
    this.castController = null;
    this.closeLocalFile();
    // 1. 结束系统投播（远端断开）
    if (session !== null) {
      try {
        await session.stopCasting();
      } catch (err) {
        // 远端已离线等情况忽略
      }
    }
    // 2. 释放投播控制器
    if (controller !== null) {
      try {
        await controller.release();
      } catch (err) {
        // 忽略
      }
    }
    // 3. 销毁投播会话
    if (session !== null) {
      try {
        session.off('outputDeviceChange');
        session.off('play');
        session.off('pause');
        session.off('stop');
        session.off('seek');
        await session.destroy();
      } catch (err) {
        // 忽略
      }
    }
    this.session = null;
    this.target = null;
    this.segmentIndex = 0;
    this.segmentBaseMs = 0;
    this.disconnecting = false;
    // 4. 归还播控中心集成（AVSessionService 公开 activate 重建基础会话）
    await this.restoreMediaSession();
    // 5. 上报断开（携带恢复位置）
    if (invokeCallback) {
      this.callbacks.onDisconnected?.(resumeMs);
    }
  }

  /** 归还 AVSessionService 基础播控会话（assetId=hid#partIndex 对齐新签名） */
  private async restoreMediaSession(): Promise<void> {
    const video: Video | null = this.restoreVideo;
    const context = AppContextHolder.get();
    if (video === null || context === null) {
      return;
    }
    try {
      await AVSessionService.getInstance().activate(context, video, this.restorePartIndex,
        this.restorePartTitle, this.restoreDurationMs, AVSessionOwner.ONLINE);
    } catch (err) {
      // 归还失败不影响本地播放
    }
  }

  // ============ 内部：会话事件 / 段链 / 命令 ============

  /** 投播会话事件注册（设备连接变化 + 播控中心命令转发） */
  private registerSessionEvents(session: avSession.AVSession): void {
    session.on('outputDeviceChange', (state: avSession.ConnectionState,
      device: avSession.OutputDeviceInfo): void => {
      if (state === avSession.ConnectionState.STATE_CONNECTED
        && device.devices.length > 0
        && device.devices[0].castCategory === avSession.AVCastCategory.CATEGORY_REMOTE) {
        this.onDeviceConnected(device.devices[0].deviceName);
      } else if (state === avSession.ConnectionState.STATE_DISCONNECTED) {
        if (this.activeDevice !== null && !this.disconnecting) {
          this.teardown(true);
        }
      }
    });
    // 投播期间播控中心命令 → 远端（本机已暂停，命令面向投播画面）
    session.on('play', (): void => {
      this.play();
    });
    session.on('pause', (): void => {
      this.pause();
    });
    session.on('stop', (): void => {
      this.pause();
    });
    session.on('seek', (timeMs: number): void => {
      this.seekTo(this.segmentBaseMs + timeMs);
    });
  }

  /** 设备连接成功：取投播控制器 + 挂远端事件 */
  private async onDeviceConnected(deviceName: string): Promise<void> {
    const session: avSession.AVSession | null = this.session;
    if (session === null) {
      return;
    }
    try {
      const controller: avSession.AVCastController = await session.getAVCastController();
      this.castController = controller;
      const device: CastDevice = new CastDevice();
      device.channel = CastChannel.SYSTEM_CAST;
      device.deviceId = 'system-cast';
      device.deviceName = deviceName;
      this.activeDevice = device;
      this.remoteState = new CastRemoteState();
      this.maxVolume = 15;
      this.registerCastControllerEvents(controller);
      this.callbacks.onConnected?.(device);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      this.callbacks.onError?.(`获取投播控制器失败：${error.message}`);
    }
  }

  /** 投播控制器事件（状态镜像 / IO 错误） */
  private registerCastControllerEvents(controller: avSession.AVCastController): void {
    controller.on('playbackStateChange', 'all', (state: avSession.AVPlaybackState): void => {
      this.onRemotePlaybackState(state);
    });
    controller.on('castControlIoError', (error: BusinessError): void => {
      // DLNA/SOAP 链路 IO 错误：按断开处理（CastVM 提示并恢复本地播放）
      if (this.activeDevice !== null && !this.disconnecting) {
        this.callbacks.onError?.('投播链路异常，已断开');
        this.teardown(true);
      }
    });
  }

  /** 远端播放状态 → 镜像（段内进度折算总时位；完成续投下一段） */
  private onRemotePlaybackState(state: avSession.AVPlaybackState): void {
    const target: CastMediaTarget | null = this.target;
    if (target === null) {
      return;
    }
    const segment: CastSegment | undefined = target.segments[this.segmentIndex];
    const segLength: number = segment !== undefined ? segment.lengthMs : 0;
    // 音量刻度
    if (state.maxVolume !== undefined && state.maxVolume > 0) {
      this.maxVolume = state.maxVolume;
    }
    if (state.volume !== undefined && this.maxVolume > 0) {
      this.remoteState.volume = Math.min(1, Math.max(0, state.volume / this.maxVolume));
    }
    // 进度（段内 → 总时位）
    if (state.position !== undefined) {
      this.remoteState.positionMs = this.segmentBaseMs + state.position.elapsedTime;
    }
    if (state.duration !== undefined && state.duration > 0) {
      this.remoteState.durationMs = target.totalMs > 0 ? target.totalMs : state.duration;
    } else if (segLength > 0) {
      this.remoteState.durationMs = target.totalMs;
    }
    // 播放态
    const pbState: avSession.PlaybackState | undefined = state.state;
    if (pbState !== undefined) {
      if (pbState === avSession.PlaybackState.PLAYBACK_STATE_PLAY
        || pbState === avSession.PlaybackState.PLAYBACK_STATE_FAST_FORWARD
        || pbState === avSession.PlaybackState.PLAYBACK_STATE_REWIND) {
        this.remoteState.playing = true;
      } else if (pbState === avSession.PlaybackState.PLAYBACK_STATE_COMPLETED) {
        // 当前段播完 → 续投下一段；末段则停投（保持画面，本端可退出恢复）
        const next: number = this.segmentIndex + 1;
        if (next < target.segments.length) {
          this.startSegment(next, 0);
          return;
        }
        this.remoteState.playing = false;
        this.remoteState.positionMs = target.totalMs;
      } else {
        this.remoteState.playing = false;
      }
    }
    this.pushRemoteState();
  }

  /** 投放指定段（段内偏移起始；fdSrc 本地 / mediaUri 远程） */
  private async startSegment(index: number, offsetMs: number): Promise<void> {
    const controller: avSession.AVCastController | null = this.castController;
    const target: CastMediaTarget | null = this.target;
    if (controller === null || target === null) {
      return;
    }
    const segment: CastSegment | undefined = target.segments[index];
    if (segment === undefined) {
      return;
    }
    this.closeLocalFile();
    const description: avSession.AVMediaDescription = {
      assetId: `${target.assetId}-seg${index}`,
      mediaType: 'VIDEO',
      title: target.title,
      subtitle: target.subtitle,
      artist: target.artist,
      mediaImage: target.thumb,
      duration: segment.lengthMs,
      startPosition: offsetMs
    };
    if (segment.localPath.length > 0) {
      // 本地文件：fdSrc（系统读取本端文件推流）
      try {
        const file: fileIo.File = fileIo.openSync(segment.localPath, fileIo.OpenMode.READ_ONLY);
        this.localFile = file;
        const stat: fileIo.Stat = fileIo.statSync(file.fd);
        description.fdSrc = {
          fd: file.fd,
          offset: 0,
          length: stat.size
        };
      } catch (err) {
        this.callbacks.onError?.('本地文件打开失败，尝试经局域网推送');
        // fdSrc 失败 → 上报错误，CastVM 回退 LocalHttpServer URL 重建目标
        return;
      }
    } else {
      description.mediaUri = segment.url;
    }
    const item: avSession.AVQueueItem = {
      itemId: index + 1,
      description: description
    };
    // 段基准（总时位折算）
    this.segmentIndex = index;
    let base: number = 0;
    for (let i: number = 0; i < index; i++) {
      const seg: CastSegment | undefined = target.segments[i];
      base += seg !== undefined ? seg.lengthMs : 0;
    }
    this.segmentBaseMs = base;
    this.remoteState.positionMs = base + offsetMs;
    this.remoteState.durationMs = target.totalMs;
    this.remoteState.playing = true;
    try {
      await controller.prepare(item);
      await controller.start(item);
      this.pushRemoteState();
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      this.callbacks.onError?.(`投播启动失败：${error.message}`);
    }
  }

  /** 发送远端命令 */
  private async sendCommand(command: avSession.AVCastControlCommandType,
    parameter?: number): Promise<void> {
    const controller: avSession.AVCastController | null = this.castController;
    if (controller === null) {
      return;
    }
    const cmd: avSession.AVCastControlCommand = {
      command: command,
      parameter: parameter
    };
    try {
      await controller.sendControlCommand(cmd);
    } catch (err) {
      // 连接已断开/命令不支持等情况：静默（状态回调会纠正 UI）
    }
  }

  /** 关闭本地文件句柄 */
  private closeLocalFile(): void {
    if (this.localFile !== null) {
      try {
        fileIo.closeSync(this.localFile);
      } catch (err) {
        // 忽略
      }
      this.localFile = null;
    }
  }

  /** 推送远端镜像到回调 */
  private pushRemoteState(): void {
    const snapshot: CastRemoteState = new CastRemoteState();
    snapshot.playing = this.remoteState.playing;
    snapshot.positionMs = this.remoteState.positionMs;
    snapshot.durationMs = this.remoteState.durationMs;
    snapshot.volume = this.remoteState.volume;
    snapshot.volumeSupported = this.remoteState.volumeSupported;
    this.callbacks.onRemoteStateChanged?.(snapshot);
  }
}
