/**
 * 播放历史 VM
 * - 数据源：HistoryService（history.json，新记录在前、hid 去重、分集断点合并）
 * - 行文案：记忆分集 + 断点时间（"看到第x集 12:34"）；无断点仅显示 UP 主
 * - 点击续播：路由进详情页，VideoDetailVM.loadDetail 依 PlayerConfig.autoResume
 *   自动从断点播或弹提示条（本 VM 不重复实现续播逻辑）
 * - 删除/清空：HistoryService.removeHistory / clearHistory
 */
import { Video, Part } from '../model/entity/BaseEntities';
import { HistoryService, ResumePoint } from '../service/player/HistoryService';
import { VideoDetailVM } from './VideoDetailVM';

@ObservedV2
export class HistoryVM {
  /** 历史列表快照（新的在前） */
  @Trace histories: Video[] = [];
  /** 条目计数文案 */
  @Trace summaryText: string = '';

  private readonly history: HistoryService = HistoryService.getInstance();

  /** 页面出现：加载快照 */
  bind(): void {
    this.refresh();
  }

  /** 页面消失（当前无订阅，占位保持生命周期对称） */
  unbind(): void {
  }

  /** 刷新列表快照 */
  refresh(): void {
    this.histories = this.history.loadPlayHistory().slice();
    this.summaryText = this.histories.length > 0 ? `共 ${this.histories.length} 条记录` : '';
  }

  /** 删除单条（左滑/右键菜单） */
  remove(hid: string): void {
    this.history.removeHistory(hid);
    this.refresh();
  }

  /** 清空全部 */
  clearAll(): void {
    this.history.clearHistory();
    this.refresh();
  }

  /** 是否空列表 */
  isEmpty(): boolean {
    return this.histories.length === 0;
  }

  /**
   * 行续播文案：记忆分集 + 断点位置
   * 规则对齐 HistoryService.resumePointOf（断点 >5s 才有续播价值），
   * 无断点时回落"看过·第x集"或"UP主：xx"
   */
  resumeTextOf(video: Video): string {
    if (video.parts.length === 0) {
      return `UP主：${video.user}`;
    }
    const point: ResumePoint | null = this.history.resumePointOf(video);
    if (point !== null) {
      const part: Part | undefined = video.parts[point.partIndex];
      const partTitle: string = part !== undefined ? part.title : '';
      return `看到 ${partTitle} ${VideoDetailVM.formatClock(point.positionMs)}`;
    }
    const lastPart: Part | undefined = video.parts[Math.min(Math.max(0, video.lastplay),
      video.parts.length - 1)];
    if (lastPart !== undefined && lastPart.hadPlay) {
      return `看完 ${lastPart.title}`;
    }
    return `UP主：${video.user}`;
  }
}
