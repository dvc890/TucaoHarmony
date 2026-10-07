/**
 * 播放历史服务（history.json）
 * - 存储：files/history.json（JsonFileStore 串行原子写），对齐安卓 SP 键 play_history
 * - 合并规则（对齐安卓 HistoryHelpers）：
 *   · 以 hid 去重，新记录插到队首
 *   · 分集按 vid 合并：当前 parts 在前，历史中多余的 vid 追加其后
 * - 断点：part.lastPlayPosition（ms）+ video.lastplay（记忆分集）
 * - 已看：part.hadPlay；播完 lastplay 推进到下一集（安卓 lastplay++ 语义）
 * - 续播：resumePointOf 返回未播完且有断点(>5s)的分集
 */
import { Video, Part, JsonCoerce } from '../../model/entity/BaseEntities';
import { StoreFile } from '../../common/Constants';
import { JsonFileStore } from '../../data/JsonFileStore';

/** 续播点 */
export class ResumePoint {
  partIndex: number = 0;
  positionMs: number = 0;
}

/** 播放历史单例 */
export class HistoryService {
  private static instance: HistoryService | undefined;

  static getInstance(): HistoryService {
    if (HistoryService.instance === undefined) {
      HistoryService.instance = new HistoryService();
    }
    return HistoryService.instance;
  }

  /** 内存缓存（读一次，写穿透） */
  private records: Video[] | null = null;

  private constructor() {
  }

  /** 读取全部播放历史（新的在前） */
  loadPlayHistory(): Video[] {
    if (this.records !== null) {
      return this.records;
    }
    const raw: Object[] = JsonFileStore.loadArray(StoreFile.HISTORY);
    const result: Video[] = [];
    for (let i = 0; i < raw.length; i++) {
      const obj: Record<string, Object> | undefined = JsonCoerce.asRecord(raw[i]);
      if (obj !== undefined) {
        result.push(Video.fromLocalJson(obj));
      }
    }
    this.records = result;
    return result;
  }

  /** 按 hid 查找历史记录 */
  findHistory(hid: string): Video | undefined {
    const list: Video[] = this.loadPlayHistory();
    for (let i = 0; i < list.length; i++) {
      if (list[i].hid === hid) {
        return list[i];
      }
    }
    return undefined;
  }

  /**
   * 保存/合并播放历史（hid 去重、插队首、分集 vid 合并）
   * 对齐安卓 savePlayHistory：video.parts = video.parts + exist.parts distinctBy vid
   */
  savePlayHistory(video: Video): void {
    const list: Video[] = this.loadPlayHistory();
    let merged: Video = video;
    const rest: Video[] = [];
    for (let i = 0; i < list.length; i++) {
      const item: Video = list[i];
      if (item.hid === video.hid) {
        merged = HistoryService.mergeVideo(video, item);
      } else {
        rest.push(item);
      }
    }
    this.records = [merged, ...rest];
    this.persist();
  }

  /** 从历史移除（清单页用，扩展） */
  removeHistory(hid: string): void {
    const list: Video[] = this.loadPlayHistory();
    this.records = list.filter((v: Video): boolean => v.hid !== hid);
    this.persist();
  }

  /** 清空历史 */
  clearHistory(): void {
    this.records = [];
    JsonFileStore.remove(StoreFile.HISTORY);
  }

  /**
   * 记录断点（播放心跳/暂停/退出时调用）
   * @param video       视频
   * @param partIndex   分集索引
   * @param positionMs  总时位
   */
  saveBreakpoint(video: Video, partIndex: number, positionMs: number): void {
    const part: Part | undefined = video.parts[partIndex];
    if (part === undefined) {
      return;
    }
    part.lastPlayPosition = positionMs;
    part.hadPlay = false;
    video.lastplay = partIndex;
    this.savePlayHistory(video);
  }

  /**
   * 标记分集已看完（断点清零，lastplay 推进下一集）
   * 对齐安卓：播完 lastplay++（越界钳制在最后一级）
   */
  markPartCompleted(video: Video, partIndex: number): void {
    const part: Part | undefined = video.parts[partIndex];
    if (part !== undefined) {
      part.hadPlay = true;
      part.lastPlayPosition = 0;
    }
    const next: number = Math.min(partIndex + 1, video.parts.length - 1);
    video.lastplay = next;
    this.savePlayHistory(video);
  }

  /**
   * 续播点（PlayerConfig.autoResume 时详情页提示条使用）
   * 规则：取 lastplay 指向的分集；若该集已播完(hadPlay)则从 0 播
   * @return null 表示无可续播断点
   */
  resumePointOf(video: Video): ResumePoint | null {
    const history: Video | undefined = this.findHistory(video.hid);
    if (history === undefined) {
      return null;
    }
    const index: number = Math.min(Math.max(0, history.lastplay), history.parts.length - 1);
    if (history.parts.length === 0) {
      return null;
    }
    const part: Part | undefined = history.parts[index];
    if (part === undefined) {
      return null;
    }
    const point: ResumePoint = new ResumePoint();
    point.partIndex = index;
    point.positionMs = part.hadPlay ? 0 : part.lastPlayPosition;
    if (point.positionMs < 5000) {
      return null; // 断点太短无续播价值
    }
    return point;
  }

  /** 持久化（队列串行写） */
  private persist(): void {
    const list: Video[] = this.records !== null ? this.records : [];
    const items: Object[] = [];
    for (let i = 0; i < list.length; i++) {
      items.push(list[i].toLocalRecord());
    }
    JsonFileStore.saveArray(StoreFile.HISTORY, items);
  }

  /** 合并：当前 parts 在前 + 历史多余 vid 追加（对齐安卓 distinctBy） */
  private static mergeVideo(fresh: Video, exist: Video): Video {
    const seenVids: Set<string> = new Set<string>();
    const mergedParts: Part[] = [];
    for (let i = 0; i < fresh.parts.length; i++) {
      const p: Part = fresh.parts[i];
      if (!seenVids.has(p.vid)) {
        seenVids.add(p.vid);
        mergedParts.push(p);
      }
    }
    for (let i = 0; i < exist.parts.length; i++) {
      const p: Part = exist.parts[i];
      if (!seenVids.has(p.vid)) {
        seenVids.add(p.vid);
        mergedParts.push(p);
      }
    }
    fresh.parts = mergedParts;
    if (fresh.part === 0) {
      fresh.part = mergedParts.length;
    }
    return fresh;
  }
}
