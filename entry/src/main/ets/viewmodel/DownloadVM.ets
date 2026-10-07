/**
 * 下载管理 VM（单例）
 * - 列表派生：engine.getCatalog() → downloadingList（有未完成分集）/ downloadedList（有已完成分集）
 * - 事件驱动：EventBus.onDownloadChanged → refresh（引擎节流 800ms + 尾随，UI 同步轻量）
 * - 操作代理：暂停/继续/重试/删除分集、全部暂停、多选批量删除（透传 DownloadEngine）
 * - 多选态：selectMode + selectedHids（数组整体替换）
 * 文案：解析中/下载中 n%/排队中/已暂停/下载失败/已缓存
 */
import { Video, Part, DownloadStatus } from '../model/entity/BaseEntities';
import { DownloadEngine } from '../service/download/DownloadEngine';
import { FileSizeText } from '../model/entity/DownloadEntities';
import { EventBus, DownloadChangedEvent } from '../common/EventBus';

/** 分集状态文案 */
export class DownloadPartStatus {
  /** 状态文本 */
  static textOf(video: Video, index: number, engine: DownloadEngine): string {
    const part: Part | undefined = video.parts[index];
    if (part === undefined) {
      return '';
    }
    if (part.flag === DownloadStatus.COMPLETED) {
      return '已缓存';
    }
    if (engine.isPending(video.hid, index)) {
      if (engine.isTaskActive(video.hid, index)) {
        return part.flag === DownloadStatus.OBTAIN_URL ? '解析中' : `下载中 ${DownloadPartStatus.percentOf(video, index)}%`;
      }
      return '排队中';
    }
    if (part.flag === DownloadStatus.PAUSED) {
      return '已暂停';
    }
    if (part.flag === DownloadStatus.FAILED) {
      return '下载失败';
    }
    return '未缓存';
  }

  /** 分集进度（COMPLETED=100；无总长=0；进行中封顶 99） */
  static percentOf(video: Video, index: number): number {
    const part: Part | undefined = video.parts[index];
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
}

/** 下载管理页 VM */
@ObservedV2
export class DownloadVM {
  private static instance: DownloadVM | undefined;

  static shared(): DownloadVM {
    if (DownloadVM.instance === undefined) {
      DownloadVM.instance = new DownloadVM();
    }
    return DownloadVM.instance;
  }

  /** 下载中列表（存在未完成分集的合集） */
  @Trace downloadingList: Video[] = [];
  /** 已下载列表（存在已完成分集的合集） */
  @Trace downloadedList: Video[] = [];
  /** 多选模式 */
  @Trace selectMode: boolean = false;
  /** 已勾选 hid 集合（整体替换） */
  @Trace selectedHids: string[] = [];

  private readonly engine: DownloadEngine = DownloadEngine.getInstance();
  /** EventBus 退订句柄 */
  private unsubscribe: (() => void) | null = null;

  private constructor() {
    this.refresh();
    this.unsubscribe = EventBus.onDownloadChanged((event: DownloadChangedEvent): void => {
      this.refresh();
    });
  }

  // ==================== 列表派生 ====================

  /** 从引擎目录重建两列表 */
  refresh(): void {
    const catalog: Video[] = this.engine.getCatalog();
    const downloading: Video[] = [];
    const downloaded: Video[] = [];
    for (let i = 0; i < catalog.length; i++) {
      const video: Video = catalog[i];
      if (DownloadVM.hasCompleted(video)) {
        downloaded.push(video);
      }
      if (DownloadVM.hasUnfinished(video)) {
        downloading.push(video);
      }
    }
    this.downloadingList = downloading;
    this.downloadedList = downloaded;
    // 多选勾选中已不存在的条目清理
    if (this.selectMode) {
      const alive: string[] = [];
      for (let i = 0; i < this.selectedHids.length; i++) {
        const hid: string = this.selectedHids[i];
        if (this.engine.findVideo(hid) !== undefined) {
          alive.push(hid);
        }
      }
      this.selectedHids = alive;
    }
  }

  /** 合集存在已完成分集 */
  static hasCompleted(video: Video): boolean {
    for (let i = 0; i < video.parts.length; i++) {
      if (video.parts[i].flag === DownloadStatus.COMPLETED) {
        return true;
      }
    }
    return false;
  }

  /** 合集存在未完成分集（活动/排队/暂停/失败） */
  static hasUnfinished(video: Video): boolean {
    const engine: DownloadEngine = DownloadEngine.getInstance();
    for (let i = 0; i < video.parts.length; i++) {
      const flag: DownloadStatus = video.parts[i].flag;
      if (flag !== DownloadStatus.READY && flag !== DownloadStatus.COMPLETED) {
        return true;
      }
      if (engine.isPending(video.hid, i)) {
        return true;
      }
    }
    return false;
  }

  /**
   * 合集整体进度（已完成分集按满算；未知总长按已下载计；全部完成=100）
   */
  percentOfVideo(video: Video): number {
    if (DownloadVM.hasCompleted(video) && !DownloadVM.hasUnfinished(video)) {
      return 100;
    }
    let done: number = 0;
    let total: number = 0;
    for (let i = 0; i < video.parts.length; i++) {
      const part: Part = video.parts[i];
      const size: number = Math.max(part.totalSize, part.downloadSize);
      if (part.flag === DownloadStatus.COMPLETED) {
        done += size;
        total += size;
      } else if (size > 0) {
        done += part.downloadSize;
        total += size;
      }
    }
    if (total <= 0) {
      return 0;
    }
    return Math.min(99, Math.max(0, Math.floor(done / total * 100)));
  }

  /** 合集状态摘要（下载中列表行用） */
  summaryTextOf(video: Video): string {
    const engine: DownloadEngine = this.engine;
    let paused: number = 0;
    let failed: number = 0;
    for (let i = 0; i < video.parts.length; i++) {
      const part: Part = video.parts[i];
      if (engine.isTaskActive(video.hid, i)) {
        return DownloadPartStatus.textOf(video, i, engine);
      }
      if (engine.isPending(video.hid, i)) {
        return '排队中';
      }
      if (part.flag === DownloadStatus.PAUSED) {
        paused++;
      } else if (part.flag === DownloadStatus.FAILED) {
        failed++;
      }
    }
    if (failed > 0) {
      return failed === 1 ? '下载失败' : `${failed} 集下载失败`;
    }
    if (paused > 0) {
      return paused === 1 ? '已暂停' : `${paused} 集已暂停`;
    }
    return '缓存中';
  }

  // ==================== 操作代理 ====================

  /** 暂停分集 */
  pausePart(hid: string, index: number): void {
    this.engine.pausePart(hid, index);
  }

  /** 继续/重试分集（PAUSED/FAILED 均可） */
  resumePart(hid: string, index: number): void {
    this.engine.resumePart(hid, index);
  }

  /** 删除分集（含缓存文件） */
  removePart(hid: string, index: number): void {
    this.engine.removePart(hid, index);
    this.refresh();
  }

  /** 删除单个合集（含全部缓存文件） */
  removeVideo(hid: string): void {
    this.engine.removeVideos([hid]);
    this.refresh();
  }

  /** 已完成分集的缓存体积合计文本（空=空串） */
  completedSizeText(video: Video): string {
    let bytes: number = 0;
    for (let i = 0; i < video.parts.length; i++) {
      const part: Part = video.parts[i];
      if (part.flag !== DownloadStatus.COMPLETED) {
        continue;
      }
      let partBytes: number = 0;
      for (let d = 0; d < part.durls.length; d++) {
        partBytes += part.durls[d].totalSize;
      }
      bytes += partBytes > 0 ? partBytes : part.downloadSize;
    }
    return bytes > 0 ? FileSizeText.format(bytes) : '';
  }

  /** 已完成分集数 */
  completedCountOf(video: Video): number {
    let count: number = 0;
    for (let i = 0; i < video.parts.length; i++) {
      if (video.parts[i].flag === DownloadStatus.COMPLETED) {
        count++;
      }
    }
    return count;
  }

  /** 全部暂停 */
  pauseAll(): void {
    this.engine.pauseAll();
  }

  /** 批量删除勾选合集 */
  removeSelected(): void {
    if (this.selectedHids.length === 0) {
      return;
    }
    this.engine.removeVideos(this.selectedHids.slice());
    this.selectedHids = [];
    this.selectMode = false;
    this.refresh();
  }

  // ==================== 多选 ====================

  enterSelect(hid: string): void {
    this.selectMode = true;
    this.selectedHids = [hid];
  }

  exitSelect(): void {
    this.selectMode = false;
    this.selectedHids = [];
  }

  toggleSelect(hid: string): void {
    const next: string[] = this.selectedHids.slice();
    const at: number = next.indexOf(hid);
    if (at >= 0) {
      next.splice(at, 1);
    } else {
      next.push(hid);
    }
    this.selectedHids = next;
  }

  isSelected(hid: string): boolean {
    return this.selectedHids.indexOf(hid) >= 0;
  }

  /** 页面销毁（单例常驻，仅复位多选态） */
  resetOnLeave(): void {
    this.exitSelect();
  }
}
