/**
 * 视频详情/播放 VM（单例）
 * - 详情加载：api_v2 view.php → 合并 下载目录()/播放历史(断点·已看)/本地收藏
 * - 播放驱动：VideoDetail 页半屏与 Player 全屏页共享本 VM + PlayerController 单例，
 *   页面迁移仅换 surfaceId（官方支持运行中换窗，视频不断流）
 * - 状态镜像：controller 回调 → @Trace 字段，两页 UI 同源刷新
 * - 断点续播：进度节流 5s 写历史；播放完成标记 hadPlay 并按 autoNext 连播
 * - 清晰度：仅 PLAYURL 类型分集暴露 QualityTable（直连分集自动隐藏菜单）；
 *   切换 = 重拉 playurl(src) + loadSegments 原位换源
 * - AVSession：起播激活（assetId=hid#partIndex，切分集整体刷新），事件点状态
 *   同步（切换/seek/倍速/缓冲/prepared 补时长，无轮询），控制中心命令回注
 *   controller；会话丢失时 PLAYING 态自愈重建
 * - / 扩展点：onSegmentChanged 已透传分集索引+段偏移；缓存入口/评论 Tab 为容器占位
 */
import { Video, Part, Durl, DownloadStatus, JsonCoerce } from '../model/entity/BaseEntities';
import { VideoRepository } from '../model/repository/VideoRepository';
import { PlayerController, PlayerCoreState, PlayerCallbacks, PlaybackMode } from '../service/player/PlayerController';
import { HistoryService } from '../service/player/HistoryService';
import { AVSessionService, AVSessionCommandHandler, AVSessionOwner } from '../service/player/AVSessionService';
import { StarService } from '../service/StarService';
import { PreferenceStore } from '../data/PreferenceStore';
import { JsonFileStore } from '../data/JsonFileStore';
import { QualityOption, QualityTable, StoreFile, PartSourceType } from '../common/Constants';
import { AppContextHolder } from '../common/GlobalState';
import { ContinuePayload, ContinuationSlot } from '../common/ContinuationState';
import { media } from '@kit.MediaKit';
import { audio } from '@kit.AudioKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0000;
const TAG = 'TucaoVideoDetailVM';

/** 详情/播放共享 VM（跨页单例） */
@ObservedV2
export class VideoDetailVM {
  private static instance: VideoDetailVM | undefined;

  static shared(): VideoDetailVM {
    if (VideoDetailVM.instance === undefined) {
      VideoDetailVM.instance = new VideoDetailVM();
    }
    return VideoDetailVM.instance;
  }

  // ============ 详情加载态 ============
  /** 详情加载中 */
  @Trace loading: boolean = true;
  /** 详情加载错误（非空=错误态） */
  @Trace error: string = '';
  /** 当前视频（含分集/断点/下载合并态） */
  @Trace video: Video | null = null;
  /** 本地收藏状态（星标开关） */
  @Trace starred: boolean = false;
  /** 是否已开始播放（封面态 → 播放态；详情页据此切换封面/播放器） */
  @Trace started: boolean = false;

  // ============ 播放镜像态 ============
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
  /** 应用内音量镜像（0~1，实为系统媒体音量；手势/键盘调节基准） */
  @Trace volume: number = 1.0;
  /** 画面缩放模式（全屏选项：fit/16:9/4:3/fill；退出全屏重置 fit） */
  @Trace scaleMode: string = 'fit';
  /** 当前分集索引 */
  @Trace partIndex: number = 0;
  /** 分集加载中（切集/换源遮罩） */
  @Trace partLoading: boolean = false;
  /** 播放模式（PLAYLIST / SEQUENTIAL 兜底） */
  @Trace playbackMode: PlaybackMode = PlaybackMode.PLAYLIST;
  /** 播放错误（控制层错误条，空=无） */
  @Trace playbackError: string = '';

  // ============ 清晰度 ============
  /** 可选清晰度（仅 PLAYURL 分集非空） */
  @Trace qualities: QualityOption[] = [];
  /** 当前清晰度 src（空=站点默认） */
  @Trace currentQualitySrc: string = '';

  // ============ 记忆续播提示 ============
  /** 提示条可见 */
  @Trace resumeTipVisible: boolean = false;
  /** 续播分集索引 */
  @Trace resumePartIndex: number = 0;
  /** 续播位置 ms */
  @Trace resumePositionMs: number = 0;
  /** 续播位置文案（xx:xx） */
  @Trace resumeTipText: string = '';

  private readonly controller: PlayerController = PlayerController.getInstance();
  private readonly history: HistoryService = HistoryService.getInstance();
  private readonly session: AVSessionService = AVSessionService.getInstance();
  private readonly star: StarService = StarService.getInstance();
  private readonly repo: VideoRepository = VideoRepository.getInstance();
  /** 最近一次请求的 hid（错误重试时 video 可能为空） */
  private lastHid: string = '';
  /** 断点节流：上次写入时间戳 */
  private lastBreakpointAt: number = 0;
  /** 断点节流间隔 ms */
  private static readonly BREAKPOINT_INTERVAL: number = 5000;
  /** 待播分集（封面态点击播放时使用；autoResume 关时含续播点） */
  private pendingStartIndex: number = 0;
  private pendingStartMs: number = 0;
  /** 起播分集直链预取（详情加载成功即后台解析，封面态点 ▶ 前压掉等待） */
  private prefetchPromise: Promise<Durl[]> | null = null;
  private prefetchedDurls: Durl[] | null = null;
  private prefetchKey: string = '';

  private constructor() {
    this.controller.setCallbacks(this.buildCallbacks());
    this.session.setCommandHandler(AVSessionOwner.ONLINE, this.buildCommandHandler());
  }

  // ============ 详情加载 ============

  /** 加载详情（路由进入时调用；重复调用幂等重载） */
  async loadDetail(hid: string): Promise<void> {
    this.lastHid = hid;
    this.loading = true;
    this.error = '';
    this.resumeTipVisible = false;
    // 换视频清残留：上个视频的播放镜像态不得泄漏进新视频（partIndex 残留会令
    // 分集面板高亮停留在上个视频切到的分集，与实际待播分集不符——误导性选中）
    this.partIndex = 0;
    this.partLoading = false;
    this.playbackError = '';
    this.clearPrefetch();
    try {
      const video: Video = await this.repo.fetchVideoDetail(hid);
      this.mergeDownloadCatalog(video);
      this.mergeHistory(video);
      this.starred = this.star.contains(hid);
      video.isStarred = this.starred;
      this.video = video;

      // ===== 多端接续恢复：接续槽命中本 hid 时优先于本地历史 =====
      const cont: ContinuePayload | null = ContinuationSlot.shared().takeIfMatch(hid);
      let contAutoIndex: number = -1;
      let contAutoPos: number = 0;
      if (cont !== null) {
        const partCount: number = video.parts.length;
        const contIndex: number = partCount > 0
          ? Math.min(Math.max(0, cont.partIndex), partCount - 1) : 0;
        const contPos: number = Math.max(0, cont.positionMs);
        // 接续点先落本地断点（与 HistoryService 断点语义同构）——下方既有历史逻辑、
        // startPlay/resumeFromTip/续播条全链路自动对齐聚接续点（含 ≥5s 续播价值判定
        // 与 autoResume 配置语义，目标端片源分集数差异由上方钳制兜底）；详情拉取
        // 失败不至此，接续点保留槽内，重试成功后仍可续播
        this.history.saveBreakpoint(video, contIndex, contPos);
        if (cont.playing) {
          // 源端在播：详情就绪即自动续播（无需用户点播）
          contAutoIndex = contIndex;
          contAutoPos = contPos;
        }
        hilog.info(DOMAIN, TAG,
          '[Continuation] 详情消费接续点: hid=%{public}s part=%{public}d pos=%{public}d autoPlay=%{public}s',
          hid, contIndex, contPos, `${cont.playing}`);
      }
      // 封面态进入：不自动播放（点封面的播放按钮/续播条才起播）。
      // 记录待播分集：历史 lastplay 优先，否则第一集
      const historyRecord: Video | undefined = this.history.findHistory(hid);
      let startIndex: number = 0;
      if (historyRecord !== undefined && historyRecord.parts.length > 0) {
        startIndex = Math.min(Math.max(0, historyRecord.lastplay), historyRecord.parts.length - 1);
      }
      this.pendingStartIndex = startIndex;
      this.pendingStartMs = 0;
      // 续播：autoResume 开 → 点击播放时直接从断点播（不弹提示条）；
      // 关 → 从头播 + 提示条供手动跳转（"自动跳转可配置"）
      const config = PreferenceStore.playerConfig();
      if (!config.autoResume) {
        const point = this.history.resumePointOf(video);
        if (point !== null) {
          this.pendingStartIndex = point.partIndex;
          this.pendingStartMs = point.positionMs;
          this.showResumeTip(point.partIndex, point.positionMs);
        }
      }
      // 分集选中态 = 实际将播放的分集（新视频进入重置残留：封面态高亮待播分集，
      // 起播/续播/接续经 playPart 再自然推进）
      this.partIndex = this.pendingStartIndex;
      // 起播分集直链预取（pendingStartIndex 定稿后发起）
      this.prefetchDurls(this.pendingStartIndex);
      // 接续且源端在播：自动续播——复用 playPart 断点续播语义（pendingSeekMs 精确
      // 起播，跨段换段+段内 seek 由 PlayerController 既有兜底；预取命中零额外等待）
      if (contAutoIndex >= 0) {
        await this.playPart(contAutoIndex, contAutoPos);
      }
    } catch (err) {
      this.error = '详情加载失败，请稍后重试';
    }
    this.loading = false;
  }

  /** 重试加载详情 */
  async retryLoadDetail(): Promise<void> {
    const video: Video | null = this.video;
    if (video !== null && video.hid.length > 0) {
      await this.loadDetail(video.hid);
    } else if (this.lastHid.length > 0) {
      await this.loadDetail(this.lastHid);
    }
  }

  // ============ 播放控制（页面直调） ============

  /** 播放指定分集（记录 lastplay + AVSession 激活） */
  async playPart(index: number, startMs: number): Promise<void> {
    const video: Video | null = this.video;
    if (video === null || index < 0 || index >= video.parts.length) {
      return;
    }
    this.started = true;
    this.partIndex = index;
    this.partLoading = true;
    this.playbackError = '';
    this.resumeTipVisible = false;
    const config = PreferenceStore.playerConfig();
    this.speed = config.speed;
    const part: Part = video.parts[index];
    // 清晰度集合：仅标准 playurl 分集可选
    this.qualities = part.sourceType === PartSourceType.PLAYURL ? QualityTable.ALL : [];
    this.currentQualitySrc = '';
    // 历史立记（lastplay 指向当前分集）
    this.history.saveBreakpoint(video, index, startMs);
    // 预取命中：跳过仓库直供分段（未命中/在途失效走常规解析，重试链路不受影响）
    const prefetched: Durl[] | null = await this.takePrefetchedDurls(index);
    if (prefetched !== null) {
      await this.controller.loadSegments(video, index, prefetched, startMs);
    } else {
      await this.controller.load(video, index, startMs);
    }
    this.activateSession(video, part);
  }

  /** 播放/暂停切换 */
  async togglePlay(): Promise<void> {
    await this.controller.togglePlay();
  }

  /** 暂停（页面失焦/退出全屏时调用） */
  async pause(): Promise<void> {
    this.saveBreakpointNow();
    await this.controller.pause();
  }

  /** 总时位 seek（滑杆） */
  async seekTo(totalMs: number): Promise<void> {
    await this.controller.seekTotal(totalMs);
    this.syncSessionPosition();
  }

  /** 快进/快退 ±ms（±10s / +90s 按钮） */
  async skipBy(deltaMs: number): Promise<void> {
    await this.controller.skipBy(deltaMs);
    this.syncSessionPosition();
  }

  /** 倍速（持久化到 PlayerConfig） */
  async setSpeed(rate: number): Promise<void> {
    this.speed = rate;
    PreferenceStore.playerConfig().speed = rate;
    await this.controller.setSpeed(rate);
    // 倍速变化即新锚点：播控中心按新倍速推算，防按旧倍速回弹
    this.session.updatePlaybackState(AVSessionOwner.ONLINE,
      this.coreState === PlayerCoreState.PLAYING, this.controller.currentMs, rate);
  }

  /** seek/快进快退后播控进度锚点补报（系统按锚点自推算，防进度回弹） */
  private syncSessionPosition(): void {
    this.session.updatePlaybackState(AVSessionOwner.ONLINE,
      this.coreState === PlayerCoreState.PLAYING, this.controller.currentMs, this.speed);
  }

  /** 音量（0~1 映射系统媒体音量；跨应用一致，初始值真实避免手势"锁 100%"） */
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

  /** 读取系统媒体音量同步到镜像（播放页/详情页 onShown 时调用） */
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

  /** 画面缩放：fit=保持比例留黑边；16:9/4:3=内容拉伸变形至该比例；fill=保持比例裁剪撑满 */
  async setScaleMode(mode: string): Promise<void> {
    this.scaleMode = mode;
    let type: media.VideoScaleType = media.VideoScaleType.VIDEO_SCALE_TYPE_SCALED_ASPECT;
    if (mode === 'fill') {
      type = media.VideoScaleType.VIDEO_SCALE_TYPE_FIT_CROP;
    } else if (mode === '16:9' || mode === '4:3') {
      // 拉伸填满窗口：窗口尺寸已按该比例排布，内容随窗口变形
      type = media.VideoScaleType.VIDEO_SCALE_TYPE_FIT;
    }
    await this.controller.setScale(type);
  }

  /** 切换分集（选集列表/上一集/下一集） */
  async switchPart(index: number): Promise<void> {
    if (this.video === null) {
      return;
    }
    if (index < 0 || index >= this.video.parts.length) {
      return;
    }
    await this.playPart(index, 0);
  }

  /** 上一集 */
  async playPreviousPart(): Promise<void> {
    await this.switchPart(this.partIndex - 1);
  }

  /** 下一集 */
  async playNextPart(): Promise<void> {
    await this.switchPart(this.partIndex + 1);
  }

  /**
   * 切换清晰度（PLAYURL 分集）：重拉 playurl(src) 原位换源，保持进度
   */
  async setQuality(src: string): Promise<void> {
    const video: Video | null = this.video;
    if (video === null) {
      return;
    }
    const part: Part | undefined = video.parts[this.partIndex];
    if (part === undefined || part.sourceType !== PartSourceType.PLAYURL) {
      return;
    }
    const positionMs: number = this.currentMs;
    try {
      const durls: Durl[] = await this.repo.fetchPlayUrls(part.type, part.vid, src);
      if (durls.length === 0) {
        return;
      }
      this.currentQualitySrc = src;
      this.partLoading = true;
      this.playbackError = '';
      await this.controller.loadSegments(video, this.partIndex, durls, positionMs);
    } catch (err) {
      this.playbackError = '清晰度切换失败';
    }
  }

  /** 播放错误重试（错误条按钮：原位重新解析地址并续播） */
  async retryPlayback(): Promise<void> {
    this.playbackError = '';
    await this.playPart(this.partIndex, this.currentMs);
  }

  /** 封面态开始播放（点封面的播放按钮；按续播配置选起播分集/位置） */
  async startPlay(): Promise<void> {
    const video: Video | null = this.video;
    if (video === null) {
      return;
    }
    const config = PreferenceStore.playerConfig();
    if (config.autoResume) {
      const point = this.history.resumePointOf(video);
      if (point !== null) {
        await this.playPart(point.partIndex, point.positionMs);
        return;
      }
    }
    await this.playPart(this.pendingStartIndex, this.pendingStartMs);
  }

  /** 续播提示条：立即跳转 */
  async resumeFromTip(): Promise<void> {
    await this.playPart(this.resumePartIndex, this.resumePositionMs);
  }

  /** 收藏切换（本地 star.json + 事件联动） */
  toggleStar(): void {
    const video: Video | null = this.video;
    if (video === null) {
      return;
    }
    this.starred = this.star.toggle(video);
  }

  /** 断点立即落盘（暂停/退出页面时） */
  saveBreakpointNow(): void {
    const video: Video | null = this.video;
    if (video === null || this.coreState === PlayerCoreState.IDLE) {
      return;
    }
    if (this.coreState !== PlayerCoreState.PLAYING && this.coreState !== PlayerCoreState.PAUSED) {
      return;
    }
    this.lastBreakpointAt = Date.now();
    this.history.saveBreakpoint(video, this.partIndex, this.currentMs);
  }

  /** 页面销毁（最后一个页面退出时释放内核与会话） */
  async shutdown(): Promise<void> {
    this.saveBreakpointNow();
    this.clearPrefetch();
    await this.controller.release();
    await this.session.destroy();
    this.coreState = PlayerCoreState.IDLE;
    this.partLoading = false;
    this.started = false;
  }

  /** surface 绑定（两页 XComponent onLoad 都调用，运行中换窗不断流） */
  attachSurface(surfaceId: string): void {
    this.controller.setSurfaceId(surfaceId);
  }

  // ============ 起播分集预取 ============

  /** 预取指定分集直链（key = hid:index:vid 防换视频/换集串写；本地分集零耗时跳过） */
  private prefetchDurls(index: number): void {
    const video: Video | null = this.video;
    if (video === null || index < 0 || index >= video.parts.length) {
      return;
    }
    const part: Part = video.parts[index];
    if (part.flag === DownloadStatus.COMPLETED) {
      return;
    }
    const key: string = `${video.hid}:${index}:${part.vid}`;
    this.prefetchKey = key;
    this.prefetchedDurls = null;
    this.prefetchPromise = this.resolvePrefetch(key, part);
  }

  /** 预取执行体（结果按 key 落存，被新请求取代则丢弃） */
  private async resolvePrefetch(key: string, part: Part): Promise<Durl[]> {
    try {
      const durls: Durl[] = await this.repo.resolvePartDurls(part);
      if (this.prefetchKey === key) {
        this.prefetchedDurls = durls;
      }
      return durls;
    } catch (_err) {
      return [];
    }
  }

  /** 取走预取结果（命中即清；在途则等待同一请求完成，不重复发起；失效返回 null） */
  private async takePrefetchedDurls(index: number): Promise<Durl[] | null> {
    const video: Video | null = this.video;
    if (video === null || this.prefetchKey.length === 0) {
      return null;
    }
    const part: Part | undefined = video.parts[index];
    if (part === undefined || this.prefetchKey !== `${video.hid}:${index}:${part.vid}`) {
      this.clearPrefetch();
      return null;
    }
    const key: string = this.prefetchKey;
    const promise: Promise<Durl[]> | null = this.prefetchPromise;
    if (promise !== null) {
      await promise;
    }
    const durls: Durl[] | null = this.prefetchedDurls;
    const stillValid: boolean = this.prefetchKey === key;
    this.clearPrefetch();
    if (stillValid && durls !== null && durls.length > 0) {
      return durls;
    }
    return null;
  }

  private clearPrefetch(): void {
    this.prefetchPromise = null;
    this.prefetchedDurls = null;
    this.prefetchKey = '';
  }

  // ============ 内部：合并/回调/会话 ============

  /** ：合并 download_catalog.json（已下载分集 durls/cachePath/flag → 走本地播放） */
  private mergeDownloadCatalog(video: Video): void {
    const raw: Object[] = JsonFileStore.loadArray(StoreFile.DOWNLOAD_CATALOG);
    for (let i = 0; i < raw.length; i++) {
      const record: Record<string, Object> | undefined = JsonCoerce.asRecord(raw[i]);
      if (record === undefined || record['hid'] !== video.hid) {
        continue;
      }
      const catalog: Video = Video.fromLocalJson(record);
      let hasCompleted: boolean = false;
      for (let p = 0; p < video.parts.length; p++) {
        const freshPart: Part = video.parts[p];
        const catalogPart: Part | undefined = catalog.parts.find((c: Part): boolean => c.vid === freshPart.vid);
        if (catalogPart !== undefined && catalogPart.flag === DownloadStatus.COMPLETED
          && catalogPart.durls.length > 0) {
          freshPart.durls = catalogPart.durls;
          freshPart.flag = DownloadStatus.COMPLETED;
          hasCompleted = true;
        }
      }
      video.downloadState = hasCompleted ? DownloadStatus.COMPLETED : video.downloadState;
      return;
    }
  }

  /** 合并播放历史（lastplay/断点/已看标记） */
  private mergeHistory(video: Video): void {
    const historyRecord: Video | undefined = this.history.findHistory(video.hid);
    if (historyRecord === undefined) {
      return;
    }
    video.lastplay = historyRecord.lastplay;
    for (let i = 0; i < video.parts.length; i++) {
      const part: Part = video.parts[i];
      const old: Part | undefined = historyRecord.parts.find((p: Part): boolean => p.vid === part.vid);
      if (old !== undefined) {
        part.hadPlay = old.hadPlay;
        part.lastPlayPosition = old.lastPlayPosition;
      }
    }
  }

  /** 续播提示条数据 */
  private showResumeTip(partIndex: number, positionMs: number): void {
    this.resumePartIndex = partIndex;
    this.resumePositionMs = positionMs;
    this.resumeTipText = VideoDetailVM.formatClock(positionMs);
    this.resumeTipVisible = true;
  }

  /** ms → mm:ss / h:mm:ss */
  static formatClock(ms: number): string {
    const totalSeconds: number = Math.max(0, Math.floor(ms / 1000));
    const hours: number = Math.floor(totalSeconds / 3600);
    const minutes: number = Math.floor((totalSeconds % 3600) / 60);
    const seconds: number = totalSeconds % 60;
    const mm: string = minutes < 10 ? `0${minutes}` : `${minutes}`;
    const ss: string = seconds < 10 ? `0${seconds}` : `${seconds}`;
    if (hours > 0) {
      return `${hours}:${mm}:${ss}`;
    }
    return `${mm}:${ss}`;
  }

  /** controller 回调 → @Trace 镜像 */
  private buildCallbacks(): PlayerCallbacks {
    const callbacks: PlayerCallbacks = new PlayerCallbacks();
    const vm: VideoDetailVM = this;
    callbacks.onStateChange = (state: PlayerCoreState): void => {
      vm.coreState = state;
      vm.playbackMode = vm.controller.getPlaybackMode();
      if (state === PlayerCoreState.READY || state === PlayerCoreState.ERROR) {
        vm.partLoading = false;
      }
      if (state === PlayerCoreState.PLAYING) {
        vm.playbackError = '';
      }
      vm.syncSessionState();
    };
    callbacks.onProgress = (currentMs: number, totalMs: number): void => {
      vm.currentMs = currentMs;
      vm.totalMs = totalMs;
      // 断点节流写（5s）
      const now: number = Date.now();
      if (vm.coreState === PlayerCoreState.PLAYING
        && now - vm.lastBreakpointAt > VideoDetailVM.BREAKPOINT_INTERVAL) {
        vm.lastBreakpointAt = now;
        const video: Video | null = vm.video;
        if (video !== null) {
          vm.history.saveBreakpoint(video, vm.partIndex, currentMs);
        }
      }
    };
    callbacks.onSegmentChanged = (index: number, offsetMs: number): void => {
      //  扩展点：弹幕时间轴 = 段偏移 offsetMs + 段内时间；此处仅保断点位置语义一致
    };
    callbacks.onError = (message: string, retryable: boolean): void => {
      vm.partLoading = false;
      vm.playbackError = message;
      vm.syncSessionState(true);
    };
    callbacks.onPrepared = (): void => {
      vm.totalMs = vm.controller.totalMs;
      vm.speed = vm.controller.getSpeed();
      vm.volume = vm.controller.getVolume();
      // 起播时 activate 先行、时长未回（duration=0 → 播控进度条不可用样式）：
      // prepared 后补报真实总时长（此时 durationUpdate 已回）
      vm.session.updateDuration(AVSessionOwner.ONLINE, vm.controller.totalMs);
    };
    callbacks.onCompletion = (): void => {
      const video: Video | null = vm.video;
      if (video === null) {
        return;
      }
      // 已看标记 + lastplay 推进（对齐安卓 lastplay++ 语义）
      vm.history.markPartCompleted(video, vm.partIndex);
      // 自动连播（PlayerConfig.autoNext）
      const config = PreferenceStore.playerConfig();
      if (config.autoNext) {
        const next: number = vm.partIndex + 1;
        if (next < video.parts.length) {
          vm.playPart(next, 0);
        }
      }
    };
    callbacks.onBuffering = (busy: boolean): void => {
      vm.isBuffering = busy;
      // 缓冲态上报：播控中心显示"播放中但进度不走"，恢复时回设原态
      vm.syncSessionState();
    };
    return callbacks;
  }

  /** AVSession 命令 → controller/VM */
  private buildCommandHandler(): AVSessionCommandHandler {
    const handler: AVSessionCommandHandler = new AVSessionCommandHandler();
    const vm: VideoDetailVM = this;
    handler.onPlay = (): void => {
      vm.controller.play();
    };
    handler.onPause = (): void => {
      vm.controller.pause();
    };
    handler.onStop = (): void => {
      vm.controller.pause();
    };
    handler.onPlayNext = (): void => {
      vm.playNextPart();
    };
    handler.onPlayPrevious = (): void => {
      vm.playPreviousPart();
    };
    handler.onSeek = (timeMs: number): void => {
      // 走 VM.seekTo：seek 后回设状态（FAQ faqs-avsession-18），播控按钮/进度即时更新
      vm.seekTo(timeMs);
    };
    handler.onFastForward = (): void => {
      // 播控快进（步长由 metadata.skipIntervals=10s 决定）
      vm.skipBy(10000);
    };
    handler.onRewind = (): void => {
      vm.skipBy(-10000);
    };
    return handler;
  }

  /** 激活/复用媒体会话（持有者=在线播放页） */
  private async activateSession(video: Video, part: Part): Promise<void> {
    const context = AppContextHolder.get();
    if (context === null) {
      return;
    }
    await this.session.activate(context, video, this.partIndex, part.title, this.totalMs,
      AVSessionOwner.ONLINE);
  }

  /**
   * 会话状态同步（状态切换/缓冲事件点上报，无需轮询）
   * 会话被离线页退出/投播接管销毁后本地仍恢复播放时，PLAYING 态自愈重建
   */
  private async syncSessionState(error: boolean = false): Promise<void> {
    const playing: boolean = this.coreState === PlayerCoreState.PLAYING;
    const completed: boolean = this.coreState === PlayerCoreState.COMPLETED;
    if (playing && !error && !this.session.isActive()) {
      const video: Video | null = this.video;
      const part: Part | undefined = video !== null ? video.parts[this.partIndex] : undefined;
      if (video !== null && part !== undefined) {
        await this.activateSession(video, part);
      }
    }
    await this.session.updatePlaybackState(AVSessionOwner.ONLINE, playing, this.currentMs,
      this.speed, completed, error, this.isBuffering);
  }
}
