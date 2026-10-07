/**
 * 下载引擎（下载管理）
 * 自研 rcp 单任务 Range 下载器（okdownload 2.0.2 不可用证据见最终报告）：
 * - 串行队列：一次只跑一个分集任务，单集失败不阻塞后续（finally pump）
 * - 执行链：解析真实地址（resolvePartDurls，段数变化清目录重来）→ 弹幕先行（失败不阻断）
 *   → 逐段断点续传（Range: bytes=N-，磁盘探测为准，200 响应截断重写）→ 段完成填 cachePath
 * - 持久化：download_catalog.json（内存 catalog 懒加载 + 2s 防抖写 + 即时写）
 * - 通知：节流 800ms（EventBus.DOWNLOAD_CHANGED）+ 前台通知进度（service.taskProgress）
 * - 重启恢复：启动扫描活动态 → PAUSED；文件丢失 → 复位；已缓存大小不符 → PAUSED
 * - 入队即标 OBTAIN_URL（排队语义）：排队未启动的任务重启后也能以暂停态恢复展示
 * - 目录约定：{下载目录}/{hid}/p{order}/，分段文件名 = durl 数组下标，弹幕 danmu.xml
 *   （order 为 0 基，对齐安卓 checkInit 硬约定；弹幕 playerID = PlayerId.generate(hid, order)）
 * - 更新弹幕：updateDanmu 重拉指定分集 danmu.xml，全部成功才返回 true
 * - 通知动作回传：DownloadForegroundService.onPauseAll/onCancelActive 钩子由本引擎接线
 */
import { rcp } from '@kit.RemoteCommunicationKit';
import { fileIo, fileUri, fileShare } from '@kit.CoreFileKit';
import { Video, Part, Durl, DownloadStatus, JsonCoerce } from '../../model/entity/BaseEntities';
import { VideoRepository } from '../../model/repository/VideoRepository';
import { TucaoApiClient } from '../../service/api/TucaoApiClient';
import { DownloadTask, DownloadDirSetting, DownloadDirStore } from '../../model/entity/DownloadEntities';
import { DownloadForegroundService } from './DownloadForegroundService';
import { JsonFileStore } from '../../data/JsonFileStore';
import { EventBus } from '../../common/EventBus';
import { AppContextHolder } from '../../common/GlobalState';
import { DownloadPath, HttpConst, PlayerId, StoreFile, XmlApi } from '../../common/Constants';

/** 活动下载上下文（任务 + 会话 + 取消标记；令牌防串台） */
class ActiveDownload {
  readonly task: DownloadTask;
  readonly token: number;
  session: rcp.Session | null = null;
  canceled: boolean = false;

  constructor(task: DownloadTask, token: number) {
    this.task = task;
    this.token = token;
  }

  /** 取消（幂等）：标记 + 中断在途请求 */
  cancel(): void {
    this.canceled = true;
    const session: rcp.Session | null = this.session;
    if (session !== null) {
      try {
        session.cancel();
      } catch (err) {
        // 会话已失效等情况忽略
      }
    }
  }
}

/**
 * 分段文件写入器（断点续传核心，实现 rcp.WriteFile）
 * - APPEND 续写：构造时打开目标文件，写入定位到末尾（resumeBase = 打开时文件大小）
 * - 服务器忽略 Range 返回 200：markServerIgnoredRange 关闭重开（TRUNC），基线归零
 * - absoluteDownloaded = resumeBase + 本次写入字节数（进度与完成校验统一以此为准）
 */
class SegmentFileWriter implements rcp.WriteFile {
  private readonly path: string;
  private fd: number = -1;
  private baseBytes: number = 0;
  private wrote: number = 0;
  private rangeIgnored: boolean = false;

  constructor(path: string, append: boolean) {
    this.path = path;
    try {
      if (append && fileIo.accessSync(path)) {
        const file: fileIo.File = fileIo.openSync(path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.APPEND);
        this.fd = file.fd;
        this.baseBytes = fileIo.statSync(path).size;
      } else {
        const file: fileIo.File =
          fileIo.openSync(path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
        this.fd = file.fd;
        this.baseBytes = 0;
      }
    } catch (err) {
      this.fd = -1;
    }
  }

  /** 文件是否可写（构造失败时为 false，任务将失败） */
  isOpen(): boolean {
    return this.fd >= 0;
  }

  /** 续传基线（构造时已有字节数；200 重写后为 0） */
  resumeBase(): number {
    return this.baseBytes;
  }

  /** 服务器是否忽略了 Range（响应 200） */
  isRangeIgnored(): boolean {
    return this.rangeIgnored;
  }

  /** 绝对已下载字节数 = 基线 + 本次写入 */
  absoluteDownloaded(): number {
    return this.baseBytes + this.wrote;
  }

  /** 服务器返回 200（忽略 Range）：截断重写，基线归零 */
  markServerIgnoredRange(): void {
    this.rangeIgnored = true;
    this.baseBytes = 0;
    this.wrote = 0;
    this.closeQuietly();
    try {
      const file: fileIo.File =
        fileIo.openSync(this.path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      this.fd = file.fd;
    } catch (err) {
      this.fd = -1;
    }
  }

  /** rcp 回调：数据落盘 */
  write(buffer: ArrayBuffer): Promise<void | number> {
    if (this.fd < 0) {
      return Promise.reject(new Error('分段文件未打开'));
    }
    try {
      const written: number = fileIo.writeSync(this.fd, buffer);
      this.wrote += written;
      return Promise.resolve(written);
    } catch (err) {
      return Promise.reject(err);
    }
  }

  /** 关闭文件（幂等） */
  closeQuietly(): void {
    if (this.fd >= 0) {
      try {
        fileIo.closeSync(this.fd);
      } catch (err) {
        // fd 已失效等情况忽略
      }
      this.fd = -1;
    }
  }
}

/** 下载引擎单例 */
export class DownloadEngine {
  private static instance: DownloadEngine | undefined;

  static getInstance(): DownloadEngine {
    if (DownloadEngine.instance === undefined) {
      DownloadEngine.instance = new DownloadEngine();
    }
    return DownloadEngine.instance;
  }

  /** 内存 catalog（懒加载，读一次写穿透） */
  private catalog: Video[] | null = null;
  /** 待执行队列（串行） */
  private queue: DownloadTask[] = [];
  /** 当前活动任务 */
  private active: ActiveDownload | null = null;
  /** 令牌序列（活动任务身份） */
  private tokenSeq: number = 0;
  /** 持久化防抖定时器 */
  private persistTimer: number = -1;
  /** 通知节流定时器 */
  private notifyTimer: number = -1;
  /** 待通知 hid 集合（节流窗口内合并） */
  private pendingHids: Set<string> = new Set<string>();
  /** 启动初始化完成标记 */
  private started: boolean = false;

  private constructor() {
  }

  // ==================== 对外查询 ====================

  /** 全量 catalog（启动扫描后返回） */
  getCatalog(): Video[] {
    this.ensureStarted();
    return this.catalog ?? [];
  }

  /** 按 hid 查找下载条目 */
  findVideo(hid: string): Video | undefined {
    const list: Video[] = this.getCatalog();
    for (let i = 0; i < list.length; i++) {
      if (list[i].hid === hid) {
        return list[i];
      }
    }
    return undefined;
  }

  /** 分集是否在队列或执行中（缓存面板禁选/列表归属用） */
  isPending(hid: string, partIndex: number): boolean {
    for (let i = 0; i < this.queue.length; i++) {
      const t: DownloadTask = this.queue[i];
      if (t.video.hid === hid && t.partIndex === partIndex) {
        return true;
      }
    }
    const ctx: ActiveDownload | null = this.active;
    return ctx !== null && ctx.task.video.hid === hid && ctx.task.partIndex === partIndex;
  }

  /** 分集是否正在执行（区分「排队中」/「解析中」文案用） */
  isTaskActive(hid: string, partIndex: number): boolean {
    const ctx: ActiveDownload | null = this.active;
    return ctx !== null && ctx.task.video.hid === hid && ctx.task.partIndex === partIndex;
  }

  // ==================== 对外操作 ====================

  /**
   * 批量入队（缓存面板发起）
   * @return 实际新增任务数（已缓存/已在队列的跳过）
   */
  enqueueDownload(video: Video, partIndexes: number[]): number {
    this.ensureStarted();
    if (partIndexes.length === 0) {
      return 0;
    }
    const target: Video = this.mergeVideoMetadata(video);
    let added: number = 0;
    for (let i = 0; i < partIndexes.length; i++) {
      const index: number = partIndexes[i];
      const part: Part | undefined = target.parts[index];
      if (part === undefined || part.flag === DownloadStatus.COMPLETED) {
        continue;
      }
      if (this.isPending(target.hid, index)) {
        continue;
      }
      // 入队即标 OBTAIN_URL（排队语义）：重启扫描可恢复展示
      part.flag = DownloadStatus.OBTAIN_URL;
      this.queue.push(new DownloadTask(target, index));
      added++;
    }
    if (added > 0) {
      this.refreshVideoState(target);
      this.persistNow();
      this.notifyChangedNow(target.hid);
      this.pump();
    }
    return added;
  }

  /** 暂停单个分集（活动任务中断续传保留；排队任务出队） */
  pausePart(hid: string, partIndex: number): void {
    this.ensureStarted();
    const ctx: ActiveDownload | null = this.active;
    if (ctx !== null && ctx.task.video.hid === hid && ctx.task.partIndex === partIndex) {
      this.markPaused(hid, partIndex);
      ctx.cancel();
      return;
    }
    const index: number = this.queue.findIndex((t: DownloadTask): boolean =>
      t.video.hid === hid && t.partIndex === partIndex);
    if (index >= 0) {
      this.queue.splice(index, 1);
      this.markPaused(hid, partIndex);
      this.persistNow();
      this.notifyChangedNow(hid);
    }
  }

  /** 暂停全部（通知「暂停」动作：队列清空 + 活动取消，全部落 PAUSED） */
  pauseAll(): void {
    this.ensureStarted();
    const affected: string[] = [];
    while (this.queue.length > 0) {
      const task: DownloadTask | undefined = this.queue.shift();
      if (task === undefined) {
        break;
      }
      this.markPaused(task.video.hid, task.partIndex);
      affected.push(task.video.hid);
    }
    const ctx: ActiveDownload | null = this.active;
    if (ctx !== null) {
      this.markPaused(ctx.task.video.hid, ctx.task.partIndex);
      affected.push(ctx.task.video.hid);
      ctx.cancel();
    }
    this.persistNow();
    this.notifyAll(affected);
  }

  /** 继续/重试单个分集（PAUSED/FAILED → 重新排队；段级进度由磁盘探测恢复） */
  resumePart(hid: string, partIndex: number): void {
    this.ensureStarted();
    const video: Video | undefined = this.findVideo(hid);
    if (video === undefined) {
      return;
    }
    const part: Part | undefined = video.parts[partIndex];
    if (part === undefined) {
      return;
    }
    if (part.flag !== DownloadStatus.PAUSED && part.flag !== DownloadStatus.FAILED) {
      return;
    }
    if (this.isPending(hid, partIndex)) {
      return;
    }
    part.flag = DownloadStatus.READY;
    this.queue.push(new DownloadTask(video, partIndex));
    this.refreshVideoState(video);
    this.persistNow();
    this.notifyChangedNow(hid);
    this.pump();
  }

  /** 删除单集缓存（分片/弹幕/分集目录彻底清理，记录复位） */
  removePart(hid: string, partIndex: number): void {
    this.ensureStarted();
    const video: Video | undefined = this.findVideo(hid);
    if (video === undefined) {
      return;
    }
    // 活动匹配：先取消（catch 分支因 canceled 跳过状态回写）
    const ctx: ActiveDownload | null = this.active;
    if (ctx !== null && ctx.task.video.hid === hid && ctx.task.partIndex === partIndex) {
      ctx.cancel();
    }
    const index: number = this.queue.findIndex((t: DownloadTask): boolean =>
      t.video.hid === hid && t.partIndex === partIndex);
    if (index >= 0) {
      this.queue.splice(index, 1);
    }
    const part: Part | undefined = video.parts[partIndex];
    if (part !== undefined) {
      DownloadEngine.deleteDirQuietly(this.partDir(hid, part.order));
      part.flag = DownloadStatus.READY;
      part.durls = [];
      part.downloadSize = 0;
      part.totalSize = 0;
    }
    this.refreshVideoState(video);
    this.pruneEntryIfPristine(video);
    this.persistNow();
    this.notifyChangedNow(hid);
  }

  /** 删除整部缓存（含 {dir}/{hid} 父目录与条目） */
  removeVideo(hid: string): void {
    this.removeVideos([hid]);
  }

  /** 批量删除（多选） */
  removeVideos(hids: string[]): void {
    this.ensureStarted();
    if (hids.length === 0) {
      return;
    }
    const hidSet: Set<string> = new Set<string>(hids);
    // 取消匹配的活动任务
    const ctx: ActiveDownload | null = this.active;
    if (ctx !== null && hidSet.has(ctx.task.video.hid)) {
      ctx.cancel();
    }
    // 队列过滤
    this.queue = this.queue.filter((t: DownloadTask): boolean => !hidSet.has(t.video.hid));
    // 删目录 + 删条目
    const baseDir: string = this.resolveBaseDir();
    const kept: Video[] = [];
    const list: Video[] = this.catalog ?? [];
    for (let i = 0; i < list.length; i++) {
      const video: Video = list[i];
      if (hidSet.has(video.hid)) {
        DownloadEngine.deleteDirQuietly(`${baseDir}/${DownloadEngine.sanitizeHid(video.hid)}`);
      } else {
        kept.push(video);
      }
    }
    this.catalog = kept;
    this.persistNow();
    this.notifyAll(hids);
  }

  /**
   * 更新弹幕：重拉指定分集 danmu.xml
   * @return 全部成功才 true（调用方给成功/失败提示）
   */
  async updateDanmu(hid: string, orders: number[]): Promise<boolean> {
    this.ensureStarted();
    if (this.findVideo(hid) === undefined || orders.length === 0) {
      return false;
    }
    const safeHid: string = DownloadEngine.sanitizeHid(hid);
    let allOk: boolean = true;
    for (let i = 0; i < orders.length; i++) {
      const order: number = orders[i];
      const partDir: string = `${this.resolveBaseDir()}/${safeHid}/${DownloadPath.partDirName(order)}`;
      if (!DownloadEngine.ensureDir(partDir)) {
        allOk = false;
        continue;
      }
      const ok: boolean = await this.downloadDanmuInto(safeHid, order, partDir);
      if (!ok) {
        allOk = false;
      }
    }
    return allOk;
  }

  // ==================== 执行链 ====================

  /** 驱动队列（无活动任务时取下一条；队列空 → 通知服务收尾） */
  private pump(): void {
    if (this.active !== null) {
      return;
    }
    const next: DownloadTask | undefined = this.queue.shift();
    if (next === undefined) {
      DownloadForegroundService.getInstance().queueIdle();
      return;
    }
    this.execute(next);
  }

  /** 执行单个分集任务（地址解析 → 弹幕先行 → 逐段下载 → 完成；异常 → 单集失败不阻塞） */
  private async execute(task: DownloadTask): Promise<void> {
    const token: number = ++this.tokenSeq;
    const ctx: ActiveDownload = new ActiveDownload(task, token);
    this.active = ctx;
    const video: Video = task.video;
    const hid: string = video.hid;
    const service: DownloadForegroundService = DownloadForegroundService.getInstance();
    service.taskStarted(video.title, task.displayName, 0);
    try {
      const part: Part | undefined = video.parts[task.partIndex];
      if (part === undefined) {
        throw new Error('分集不存在');
      }
      // 1. 解析真实地址（clicli/直链/playurl；已缓存分支不会命中，flag 非 COMPLETED）
      part.flag = DownloadStatus.OBTAIN_URL;
      this.notifyChangedThrottled(hid);
      const freshDurls: Durl[] = await VideoRepository.getInstance().resolvePartDurls(part);
      if (!this.isCurrent(ctx)) {
        return;
      }
      if (freshDurls.length === 0) {
        throw new Error('无可用下载地址');
      }
      // 段数变化：旧分片按下标命名已失效，清目录重来
      if (part.durls.length > 0 && part.durls.length !== freshDurls.length) {
        DownloadEngine.deleteDirQuietly(this.partDir(hid, part.order));
        part.durls = [];
        part.downloadSize = 0;
        part.totalSize = 0;
      }
      // 2. 组装 durls（按下标继承旧进度；同下标地址变化则作废旧段）
      const merged: Durl[] = [];
      for (let i = 0; i < freshDurls.length; i++) {
        const fresh: Durl = freshDurls[i];
        const old: Durl | undefined = part.durls[i];
        const d: Durl = new Durl();
        d.order = i;
        d.length = fresh.length;
        d.url = fresh.url;
        d.flag = DownloadStatus.READY;
        if (old !== undefined) {
          d.cachePath = old.cachePath;
          d.downloadedSize = old.downloadedSize;
          d.totalSize = old.totalSize;
          d.flag = old.flag;
          if (old.url !== fresh.url) {
            DownloadEngine.deleteFileQuietly(old.cachePath);
            d.cachePath = '';
            d.downloadedSize = 0;
            d.totalSize = -1;
            d.flag = DownloadStatus.READY;
          }
        }
        merged.push(d);
      }
      part.durls = merged;
      this.persistSoon();
      this.notifyChangedThrottled(hid);
      // 3. 分集目录（{dir}/{hid}/p{order}）
      const partDir: string = this.partDir(hid, part.order);
      if (!DownloadEngine.ensureDir(partDir)) {
        throw new Error('下载目录不可用');
      }
      // 4. 弹幕先行（失败不阻断视频下载）
      await this.downloadDanmuInto(DownloadEngine.sanitizeHid(hid), part.order, partDir);
      if (!this.isCurrent(ctx)) {
        return;
      }
      // 5. 逐段下载（COMPLETED 且磁盘匹配的跳过）
      for (let i = 0; i < part.durls.length; i++) {
        if (!this.isCurrent(ctx)) {
          return;
        }
        const durl: Durl = part.durls[i];
        await this.downloadSegment(ctx, part, durl, i, partDir);
      }
      if (!this.isCurrent(ctx)) {
        return;
      }
      // 6. 分集完成（软校验：promise 成功即完成，totalSize 以落盘为准修正）
      part.refreshDownloadState();
      this.refreshVideoState(video);
      this.persistNow();
      this.notifyChangedNow(hid);
      service.taskProgress(100);
    } catch (err) {
      // 暂停/删除引发的取消由发起方负责状态，此处只处理真实失败
      if (this.isCurrent(ctx)) {
        this.markPartFailed(video, task.partIndex);
        this.refreshVideoState(video);
        this.persistNow();
        this.notifyChangedNow(hid);
      }
    } finally {
      this.finishActive(ctx);
    }
  }

  /** 单段下载（Range 续传 + 200 截断重写 + 进度回写） */
  private async downloadSegment(ctx: ActiveDownload, part: Part, durl: Durl, index: number,
    partDir: string): Promise<void> {
    const hid: string = ctx.task.video.hid;
    const service: DownloadForegroundService = DownloadForegroundService.getInstance();
    // 分段文件路径：{partDir}/{数组下标}（首下载时锁定到 cachePath，重启可探测续传）
    if (durl.cachePath.length === 0) {
      durl.cachePath = `${partDir}/${index}`;
    }
    // 磁盘探测为准（文件可能被外部删除/残留）
    const diskSize: number = DownloadEngine.probeFileSize(durl.cachePath);
    durl.downloadedSize = diskSize;
    // 已完成且磁盘匹配 → 跳过
    if (durl.flag === DownloadStatus.COMPLETED && durl.totalSize > 0 && diskSize === durl.totalSize) {
      return;
    }
    if (diskSize === 0 && durl.flag === DownloadStatus.COMPLETED) {
      durl.totalSize = -1;
    }
    durl.flag = DownloadStatus.CONNECTING;
    part.refreshDownloadState();
    this.notifyChangedThrottled(hid);

    const writer: SegmentFileWriter = new SegmentFileWriter(durl.cachePath, diskSize > 0);
    if (!writer.isOpen()) {
      throw new Error('分段文件创建失败');
    }
    const headers: rcp.RequestHeaders = {
      'user-agent': HttpConst.CHROME_UA,
      'referer': 'https://www.tucao.my/'
    };
    if (writer.resumeBase() > 0) {
      headers['range'] = `bytes=${writer.resumeBase()}-`;
    }
    const handler: rcp.HttpEventsHandler = {
      // 服务器忽略 Range 返回 200：截断重写，进度归零
      onStatusCodeReceive: (statusCode: number): void => {
        if (!this.isCurrent(ctx)) {
          return;
        }
        if (statusCode === 200 && writer.resumeBase() > 0) {
          writer.markServerIgnoredRange();
          durl.downloadedSize = 0;
          durl.totalSize = -1;
          durl.flag = DownloadStatus.DOWNLOADING;
          part.refreshDownloadState();
          this.notifyChangedThrottled(hid);
        }
      },
      // 进度回写：绝对值 = writer 基线 + 传输量；totalSize 启发式（206 → 基线+响应长）
      onDownloadProgress: (totalSize: number, transferredSize: number): void => {
        if (!this.isCurrent(ctx)) {
          return;
        }
        durl.downloadedSize = writer.absoluteDownloaded();
        const computed: number = writer.isRangeIgnored() ? totalSize : writer.resumeBase() + totalSize;
        if (computed > 0) {
          durl.totalSize = computed;
        }
        if (durl.flag !== DownloadStatus.DOWNLOADING) {
          durl.flag = DownloadStatus.DOWNLOADING;
        }
        part.refreshDownloadState();
        this.notifyChangedThrottled(hid);
        service.taskProgress(this.partPercentOf(ctx.task.video, ctx.task.partIndex));
      }
    };
    const tracing: rcp.TracingConfiguration = { httpEventsHandler: handler };
    const requestConfig: rcp.Configuration = { tracing: tracing };
    const sessionConfig: rcp.SessionConfiguration = { requestConfiguration: requestConfig, headers: headers };
    const session: rcp.Session = rcp.createSession(sessionConfig);
    ctx.session = session;
    try {
      const target: rcp.DownloadToFile = { kind: 'file', file: writer };
      // /：http 明文地址运行期回退 https 同主机；失败进入 FAILED（可见可重试，不静默）
      let requestUrl: string = durl.url;
      if (requestUrl.startsWith('http://')) {
        requestUrl = `https://${requestUrl.substring('http://'.length)}`;
      }
      await session.downloadToFile(requestUrl, target);
      writer.closeQuietly();
      if (!this.isCurrent(ctx)) {
        return; // 暂停/删除：状态由发起方标记
      }
      // 完成校验（软兜底：206 启发式可能高估，以落盘为准）
      durl.downloadedSize = writer.absoluteDownloaded();
      if (durl.totalSize <= 0 || durl.totalSize !== durl.downloadedSize) {
        durl.totalSize = durl.downloadedSize;
      }
      durl.flag = DownloadStatus.COMPLETED;
      part.refreshDownloadState();
      this.persistSoon();
      this.notifyChangedThrottled(hid);
    } finally {
      writer.closeQuietly();
      try {
        session.close();
      } catch (err) {
        // 忽略关闭失败
      }
      ctx.session = null;
    }
  }

  /** 弹幕拉取并写入 danmu.xml（playerID 为 0 基 order，对齐安卓 generatePlayerId） */
  private async downloadDanmuInto(safeHid: string, order: number, partDir: string): Promise<boolean> {
    try {
      const params: Record<string, string> = {
        'playerID': PlayerId.generate(safeHid, order),
        'r': `${Math.floor(Date.now() / 1000)}`
      };
      const xml: string = await TucaoApiClient.getInstance().getXmlText(XmlApi.DANMU_INIT, params);
      if (xml.length === 0) {
        return false;
      }
      const path: string = `${partDir}/${DownloadPath.DANMU_FILE}`;
      const file: fileIo.File =
        fileIo.openSync(path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(file.fd, xml);
      } finally {
        fileIo.closeSync(file);
      }
      return true;
    } catch (err) {
      return false;
    }
  }

  /** 活动收尾（会话关闭；仍持有活动槽 → 释放并泵下一条） */
  private finishActive(ctx: ActiveDownload): void {
    const session: rcp.Session | null = ctx.session;
    if (session !== null) {
      try {
        session.close();
      } catch (err) {
        // 忽略
      }
      ctx.session = null;
    }
    if (this.active === ctx) {
      this.active = null;
      this.pump();
    }
  }

  /** 令牌校验（活动槽未被取代且未被取消） */
  private isCurrent(ctx: ActiveDownload): boolean {
    return this.active === ctx && !ctx.canceled;
  }

  // ==================== 状态标记 ====================

  /** 标记失败（活动段 → FAILED；解析阶段无活动段 → part 直置 FAILED） */
  private markPartFailed(video: Video, partIndex: number): void {
    const part: Part | undefined = video.parts[partIndex];
    if (part === undefined) {
      return;
    }
    let touched: boolean = false;
    for (let i = 0; i < part.durls.length; i++) {
      const d: Durl = part.durls[i];
      if (d.flag === DownloadStatus.OBTAIN_URL || d.flag === DownloadStatus.CONNECTING
        || d.flag === DownloadStatus.DOWNLOADING) {
        d.flag = DownloadStatus.FAILED;
        touched = true;
      }
    }
    if (touched) {
      part.refreshDownloadState();
    } else if (part.flag !== DownloadStatus.COMPLETED) {
      part.flag = DownloadStatus.FAILED;
    }
    this.refreshVideoState(video);
  }

  /** 标记暂停（活动段 → PAUSED；无段的排队任务 → part 直置 PAUSED；FAILED/COMPLETED 保留） */
  private markPaused(hid: string, partIndex: number): void {
    const video: Video | undefined = this.findVideo(hid);
    if (video === undefined) {
      return;
    }
    const part: Part | undefined = video.parts[partIndex];
    if (part === undefined) {
      return;
    }
    let touched: boolean = false;
    for (let i = 0; i < part.durls.length; i++) {
      const d: Durl = part.durls[i];
      if (d.flag === DownloadStatus.OBTAIN_URL || d.flag === DownloadStatus.CONNECTING
        || d.flag === DownloadStatus.DOWNLOADING) {
        d.flag = DownloadStatus.PAUSED;
        touched = true;
      }
    }
    if (touched) {
      part.refreshDownloadState();
    } else if (part.flag === DownloadStatus.READY || part.flag === DownloadStatus.OBTAIN_URL
      || part.flag === DownloadStatus.CONNECTING || part.flag === DownloadStatus.DOWNLOADING) {
      part.flag = DownloadStatus.PAUSED;
    }
    this.refreshVideoState(video);
  }

  /** 合集级聚合（任一 COMPLETED → COMPLETED；否则任一非 READY → DOWNLOADING；否则 READY） */
  private refreshVideoState(video: Video): void {
    let hasCompleted: boolean = false;
    let hasActive: boolean = false;
    for (let i = 0; i < video.parts.length; i++) {
      const flag: DownloadStatus = video.parts[i].flag;
      if (flag === DownloadStatus.COMPLETED) {
        hasCompleted = true;
      } else if (flag !== DownloadStatus.READY) {
        hasActive = true;
      }
    }
    if (hasCompleted) {
      video.downloadState = DownloadStatus.COMPLETED;
    } else if (hasActive) {
      video.downloadState = DownloadStatus.DOWNLOADING;
    } else {
      video.downloadState = DownloadStatus.READY;
    }
  }

  /** 条目瘦身：无任何下载足迹且无排队任务 → 移除条目（避免浏览污染 catalog） */
  private pruneEntryIfPristine(video: Video): void {
    for (let i = 0; i < this.queue.length; i++) {
      if (this.queue[i].video === video) {
        return;
      }
    }
    const ctx: ActiveDownload | null = this.active;
    if (ctx !== null && ctx.task.video === video) {
      return;
    }
    for (let i = 0; i < video.parts.length; i++) {
      const part: Part = video.parts[i];
      if (part.flag !== DownloadStatus.READY || part.durls.length > 0 || part.downloadSize > 0) {
        return;
      }
    }
    const list: Video[] = this.catalog ?? [];
    this.catalog = list.filter((v: Video): boolean => v !== video);
  }

  // ==================== 目录与持久化 ====================

  /** 分集目录（order 为 0 基 part.order） */
  private partDir(hid: string, order: number): string {
    return `${this.resolveBaseDir()}/${DownloadEngine.sanitizeHid(hid)}/${DownloadPath.partDirName(order)}`;
  }

  /** 分集弹幕文件绝对路径（离线播放缺失检测 /  DanmakuView 接线用） */
  danmuPathOf(hid: string, order: number): string {
    return `${this.partDir(hid, order)}/${DownloadPath.DANMU_FILE}`;
  }

  /** 下载根目录：自选目录（授权激活后可写）→ 沙箱 files/download */
  private resolveBaseDir(): string {
    const setting: DownloadDirSetting = DownloadDirStore.get();
    if (setting.isCustom()) {
      try {
        const uri: fileUri.FileUri = new fileUri.FileUri(setting.uri);
        if (uri.path.length > 0) {
          return uri.path;
        }
      } catch (err) {
        // 解析失败回落沙箱
      }
    }
    const context = AppContextHolder.get();
    if (context !== null) {
      return `${context.filesDir}/download`;
    }
    return '';
  }

  /** catalog 懒加载 */
  private loadCatalog(): void {
    const raw: Object[] = JsonFileStore.loadArray(StoreFile.DOWNLOAD_CATALOG);
    const result: Video[] = [];
    for (let i = 0; i < raw.length; i++) {
      const record: Record<string, Object> | undefined = JsonCoerce.asRecord(raw[i]);
      if (record !== undefined) {
        result.push(Video.fromLocalJson(record));
      }
    }
    this.catalog = result;
  }

  /** 持久化（2s 防抖，进度高频回写时降 IO） */
  private persistSoon(): void {
    if (this.persistTimer >= 0) {
      return;
    }
    this.persistTimer = setTimeout((): void => {
      this.persistTimer = -1;
      this.persistNow();
    }, 2000);
  }

  /** 立即持久化 catalog → download_catalog.json（JsonFileStore 串行原子写） */
  private persistNow(): void {
    const list: Video[] = this.catalog ?? [];
    const items: Object[] = [];
    for (let i = 0; i < list.length; i++) {
      items.push(list[i].toLocalRecord());
    }
    JsonFileStore.saveArray(StoreFile.DOWNLOAD_CATALOG, items).catch((): void => {
      // 写失败保留内存态，下次再试
    });
  }

  /** 通知（800ms 节流 + 尾随合并；hid 级事件） */
  private notifyChangedThrottled(hid: string): void {
    this.pendingHids.add(hid);
    if (this.notifyTimer >= 0) {
      return;
    }
    this.notifyTimer = setTimeout((): void => {
      this.notifyTimer = -1;
      const hids: string[] = Array.from(this.pendingHids);
      this.pendingHids.clear();
      for (let i = 0; i < hids.length; i++) {
        EventBus.postDownloadChanged(hids[i]);
      }
    }, 800);
  }

  /** 立即通知（完成/失败/删除等关键节点） */
  private notifyChangedNow(hid: string): void {
    this.pendingHids.delete(hid);
    EventBus.postDownloadChanged(hid);
  }

  /** 多 hid 立即通知（暂停全部/批量删除） */
  private notifyAll(hids: string[]): void {
    for (let i = 0; i < hids.length; i++) {
      this.notifyChangedNow(hids[i]);
    }
  }

  // ==================== 启动初始化 ====================

  /** 首次访问初始化：加载 catalog → 重启扫描 → 激活目录授权 → 接线通知动作 */
  private ensureStarted(): void {
    if (this.started) {
      return;
    }
    this.started = true;
    this.loadCatalog();
    this.sweepInFlight();
    this.activateSavedDir();
    const service: DownloadForegroundService = DownloadForegroundService.getInstance();
    service.onPauseAll = (): void => {
      this.pauseAll();
    };
    service.onCancelActive = (): void => {
      this.cancelActive();
    };
  }

  /**
   * 重启扫描：活动态 → PAUSED；文件丢失 → 复位 READY；
   * COMPLETED 但磁盘大小不符 → PAUSED（续传校验）；READY 兄弟分集不误伤
   */
  private sweepInFlight(): void {
    const list: Video[] = this.catalog ?? [];
    for (let v = 0; v < list.length; v++) {
      const video: Video = list[v];
      let touched: boolean = false;
      for (let p = 0; p < video.parts.length; p++) {
        const part: Part = video.parts[p];
        for (let d = 0; d < part.durls.length; d++) {
          const durl: Durl = part.durls[d];
          if (durl.flag === DownloadStatus.OBTAIN_URL || durl.flag === DownloadStatus.CONNECTING
            || durl.flag === DownloadStatus.DOWNLOADING) {
            durl.flag = DownloadStatus.PAUSED;
            touched = true;
          }
          if (durl.flag === DownloadStatus.COMPLETED || durl.flag === DownloadStatus.PAUSED) {
            if (durl.cachePath.length === 0) {
              durl.downloadedSize = 0;
              if (durl.flag === DownloadStatus.COMPLETED) {
                durl.flag = DownloadStatus.READY;
                touched = true;
              }
            } else {
              const size: number = DownloadEngine.probeFileSize(durl.cachePath);
              if (size === 0) {
                // 文件丢失：路径与进度作废（FAILED 分支不进入此处，天然保留）
                durl.cachePath = '';
                durl.downloadedSize = 0;
                durl.flag = DownloadStatus.READY;
                touched = true;
              } else {
                durl.downloadedSize = size;
                if (durl.flag === DownloadStatus.COMPLETED && durl.totalSize > 0 && size !== durl.totalSize) {
                  durl.flag = DownloadStatus.PAUSED;
                  touched = true;
                }
              }
            }
          }
        }
        if (part.durls.length > 0) {
          part.refreshDownloadState();
        } else if (part.flag === DownloadStatus.OBTAIN_URL || part.flag === DownloadStatus.CONNECTING
          || part.flag === DownloadStatus.DOWNLOADING) {
          // 排队未启动（入队即标 OBTAIN_URL）→ 暂停态恢复展示
          part.flag = DownloadStatus.PAUSED;
          touched = true;
        }
      }
      this.refreshVideoState(video);
      if (touched) {
        this.persistSoon();
      }
    }
  }

  /** 激活自选目录持久授权（失败回落沙箱：清空失效 uri 防后续任务全部落盘失败） */
  private activateSavedDir(): void {
    const setting: DownloadDirSetting = DownloadDirStore.get();
    if (!setting.isCustom()) {
      return;
    }
    const policy: fileShare.PolicyInfo = {
      uri: setting.uri,
      operationMode: fileShare.OperationMode.READ_MODE | fileShare.OperationMode.WRITE_MODE
    };
    fileShare.activatePermission([policy]).catch((): void => {
      setting.uri = '';
      setting.label = '';
      DownloadDirStore.save();
    });
  }

  /** 通知「取消」动作：删除当前活动任务（文件 + 记录），队列继续 */
  private cancelActive(): void {
    const ctx: ActiveDownload | null = this.active;
    if (ctx === null) {
      return;
    }
    this.removePart(ctx.task.video.hid, ctx.task.partIndex);
  }

  /** 分集进度（0~99，完成时由 execute 上报 100） */
  private partPercentOf(video: Video, partIndex: number): number {
    const part: Part | undefined = video.parts[partIndex];
    if (part === undefined) {
      return 0;
    }
    if (part.flag === DownloadStatus.COMPLETED) {
      return 100;
    }
    if (part.totalSize <= 0) {
      return 0;
    }
    const percent: number = Math.floor(part.downloadSize / part.totalSize * 100);
    return Math.min(99, Math.max(0, percent));
  }

  // ==================== 合并与工具 ====================

  /**
   * 页面 Video → catalog 条目合并（入队前置）：
   * - 无条目：整体深拷贝插入队首
   * - 有条目：同步元数据；分集按 vid 合并，旧分集保留全部下载态（order 有下载足迹时不动，
   *   保证 {hid}/p{order} 目录与既有文件对齐），新分集深拷贝追加
   * - 绝不引用页面传入实例（页面刷新会替换 parts，引用悬空）
   */
  private mergeVideoMetadata(video: Video): Video {
    const list: Video[] = this.catalog ?? [];
    let entry: Video | undefined = undefined;
    for (let i = 0; i < list.length; i++) {
      if (list[i].hid === video.hid) {
        entry = list[i];
        break;
      }
    }
    if (entry === undefined) {
      const cloned: Video = Video.fromLocalJson(video.toLocalRecord());
      (this.catalog ?? []).unshift(cloned);
      return cloned;
    }
    // 元数据同步
    entry.title = video.title;
    entry.thumb = video.thumb;
    entry.bg = video.bg;
    entry.typename = video.typename;
    entry.typeid = video.typeid;
    entry.description = video.description;
    entry.userid = video.userid;
    entry.user = video.user;
    entry.keywords = video.keywords;
    entry.create = video.create;
    entry.play = video.play;
    entry.mukio = video.mukio;
    if (video.part > 0) {
      entry.part = video.part;
    }
    // 分集合并（按 vid）
    for (let i = 0; i < video.parts.length; i++) {
      const fresh: Part = video.parts[i];
      const old: Part | undefined = entry.parts.find((p: Part): boolean => p.vid === fresh.vid);
      if (old === undefined) {
        entry.parts.push(DownloadEngine.clonePart(fresh));
        continue;
      }
      old.title = fresh.title.length > 0 ? fresh.title : old.title;
      old.type = fresh.type;
      old.sourceType = fresh.sourceType;
      old.file = fresh.file;
      // order 仅在无下载足迹时跟随站点（目录命名稳定性优先）
      if (old.flag === DownloadStatus.READY && old.durls.length === 0 && old.downloadSize === 0) {
        old.order = fresh.order;
      }
    }
    if (entry.part === 0 && entry.parts.length > 0) {
      entry.part = entry.parts.length;
    }
    return entry;
  }

  /** 分集深拷贝（含 durls，字段级复制） */
  private static clonePart(src: Part): Part {
    const p: Part = new Part();
    p.title = src.title;
    p.order = src.order;
    p.vid = src.vid;
    p.type = src.type;
    p.sourceType = src.sourceType;
    p.file = src.file;
    p.flag = src.flag;
    p.downloadSize = src.downloadSize;
    p.totalSize = src.totalSize;
    p.hadPlay = src.hadPlay;
    p.lastPlayPosition = src.lastPlayPosition;
    for (let i = 0; i < src.durls.length; i++) {
      const s: Durl = src.durls[i];
      const d: Durl = new Durl();
      d.order = s.order;
      d.length = s.length;
      d.url = s.url;
      d.cachePath = s.cachePath;
      d.downloadedSize = s.downloadedSize;
      d.totalSize = s.totalSize;
      d.flag = s.flag;
      p.durls.push(d);
    }
    return p;
  }

  /** 文件大小探测（不存在/不可读返回 0） */
  private static probeFileSize(path: string): number {
    try {
      if (path.length === 0 || !fileIo.accessSync(path)) {
        return 0;
      }
      const stat: fileIo.Stat = fileIo.statSync(path);
      return stat.size > 0 ? stat.size : 0;
    } catch (err) {
      return 0;
    }
  }

  /** 递归删除目录（不存在忽略；rmdirSync 含子内容） */
  private static deleteDirQuietly(path: string): void {
    try {
      if (path.length > 0 && fileIo.accessSync(path)) {
        fileIo.rmdirSync(path);
      }
    } catch (err) {
      // 忽略删除失败（残留由下次清理兜底）
    }
  }

  /** 删除单文件（不存在忽略） */
  private static deleteFileQuietly(path: string): void {
    try {
      if (path.length > 0 && fileIo.accessSync(path)) {
        fileIo.unlinkSync(path);
      }
    } catch (err) {
      // 忽略
    }
  }

  /** 目录确保存在（递归创建） */
  private static ensureDir(path: string): boolean {
    if (path.length === 0) {
      return false;
    }
    try {
      if (!fileIo.accessSync(path)) {
        fileIo.mkdirSync(path, true);
      }
      return true;
    } catch (err) {
      return false;
    }
  }

  /** hid 清洗（防路径穿越/非法字符） */
  private static sanitizeHid(hid: string): string {
    const cleaned: string = hid.replace(/[^0-9a-zA-Z_-]/g, '');
    return cleaned.length > 0 ? cleaned : 'unknown';
  }
}
